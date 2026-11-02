-- =============================================================================
-- 01 · Schema: types, tables, indexes, integrity triggers
--
-- LiDAR Quote App · Supabase project in eu-central-1 (Frankfurt)
--
-- Ground rules
--   * Multi-tenant: every business row carries tenant_id. The tenant is always
--     resolved on the server from tenant_members (never from client input).
--   * Clients have NO direct table access. Everything goes through the RPC
--     functions in 04_rpc.sql. RLS is enabled as defence in depth.
--   * Issued quotes are append-only (only their status may change).
--   * Published price-book versions are immutable (only is_active may change).
--   * Every synced row carries row_seq (global change sequence) and changed_at,
--     which drive the incremental pull_changes() cursor.
-- =============================================================================

create schema if not exists app;
revoke all on schema app from public;

create type public.member_role  as enum ('owner', 'admin', 'estimator');
create type public.quote_kind   as enum ('preliminary', 'final');
create type public.quote_status as enum ('issued', 'sent', 'accepted', 'rejected', 'superseded');

-- Global change sequence = sync cursor.
create sequence public.sync_seq;

-- -----------------------------------------------------------------------------
-- Tenancy
-- -----------------------------------------------------------------------------

create table public.tenants (
    id                        uuid primary key default gen_random_uuid(),
    name                      text not null check (length(name) between 1 and 200),
    address                   text check (length(address) <= 1000),
    quote_prefix              text not null default 'ANG' check (quote_prefix ~ '^[A-Z0-9]{1,8}$'),
    -- Per-firm switch: keep USDZ models and photos on the devices only.
    media_device_only         boolean not null default true,
    -- Months after the last change before job media may be purged (CT-5 default 24).
    media_retention_months    integer not null default 24 check (media_retention_months between 1 and 120),
    -- Whether estimators (not only owner/admin) may issue FINAL quotes.
    estimator_can_issue_final boolean not null default true,
    -- Tenant-editable end-client privacy notice (Art. 13 GDPR).
    privacy_notice            text check (length(privacy_notice) <= 10000),
    -- Data-processing agreement (AVV, Art. 28 GDPR). No client data is accepted before it is signed.
    avv_signed_at             timestamptz,
    avv_version               text,
    -- Suspended tenants lose all access immediately.
    is_active                 boolean not null default true,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),
    row_seq                   bigint not null default nextval('public.sync_seq'),
    changed_at                timestamptz not null default clock_timestamp()
);

-- One company per user (MVP).
create table public.tenant_members (
    user_id      uuid primary key references auth.users (id) on delete cascade,
    tenant_id    uuid not null references public.tenants (id) on delete cascade,
    role         public.member_role not null default 'estimator',
    email        text not null,
    display_name text check (length(display_name) <= 200),
    created_at   timestamptz not null default now(),
    row_seq      bigint not null default nextval('public.sync_seq'),
    changed_at   timestamptz not null default clock_timestamp()
);
create index tenant_members_tenant_idx on public.tenant_members (tenant_id);
-- Exactly one owner per company.
create unique index tenant_members_one_owner on public.tenant_members (tenant_id) where role = 'owner';

-- Invitations: only invited e-mail addresses can create an account (see 02_auth.sql).
create table public.tenant_invitations (
    id          uuid primary key default gen_random_uuid(),
    tenant_id   uuid not null references public.tenants (id) on delete cascade,
    email       text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    role        public.member_role not null default 'estimator',
    invited_by  uuid references auth.users (id) on delete set null,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default now() + interval '72 hours',
    accepted_at timestamptz,
    accepted_by uuid references auth.users (id) on delete set null
);
create unique index tenant_invitations_open_email on public.tenant_invitations (email) where accepted_at is null;
create index tenant_invitations_tenant_idx on public.tenant_invitations (tenant_id);

-- -----------------------------------------------------------------------------
-- Price books (cloud-owned, versioned, immutable once published)
-- -----------------------------------------------------------------------------

create table public.price_books (
    id         uuid primary key default gen_random_uuid(),
    tenant_id  uuid not null references public.tenants (id) on delete cascade,
    name       text not null check (length(name) between 1 and 200),
    created_at timestamptz not null default now()
);
create index price_books_tenant_idx on public.price_books (tenant_id);

-- items: array of the app's canonical PriceItem JSON (camelCase). Keep item ids
-- STABLE across versions of the same book so room selections survive.
create table public.price_book_versions (
    id            uuid primary key default gen_random_uuid(),
    tenant_id     uuid not null references public.tenants (id) on delete cascade,
    price_book_id uuid not null references public.price_books (id) on delete cascade,
    name          text not null,
    version       integer not null check (version > 0),
    vat_rate_bp   integer not null default 1900 check (vat_rate_bp between 0 and 10000),
    items         jsonb not null check (jsonb_typeof(items) = 'array'),
    is_active     boolean not null default false,
    published_at  timestamptz not null default now(),
    published_by  uuid references auth.users (id) on delete set null,
    row_seq       bigint not null default nextval('public.sync_seq'),
    changed_at    timestamptz not null default clock_timestamp(),
    unique (price_book_id, version)
);
create index price_book_versions_sync_idx on public.price_book_versions (tenant_id, row_seq);

-- -----------------------------------------------------------------------------
-- Jobs, surveys (Aufmaß), quotes
-- -----------------------------------------------------------------------------

create table public.jobs (
    id                          uuid primary key,
    tenant_id                   uuid not null references public.tenants (id) on delete cascade,
    title                       text not null check (length(title) between 1 and 300),
    client_name                 text check (length(client_name) <= 300),
    client_email                text check (length(client_email) <= 300),
    client_phone                text check (length(client_phone) <= 100),
    site_address                text check (length(site_address) <= 1000),
    privacy_notice_confirmed_at timestamptz,
    -- Set when the client's personal data was erased on request (Art. 17 GDPR).
    client_data_erased_at       timestamptz,
    created_by                  uuid references auth.users (id) on delete set null,
    updated_by                  uuid references auth.users (id) on delete set null,
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null,
    deleted_at                  timestamptz,
    row_seq                     bigint not null default nextval('public.sync_seq'),
    changed_at                  timestamptz not null default clock_timestamp()
);
create index jobs_sync_idx on public.jobs (tenant_id, row_seq);

create table public.surveys (
    id          uuid primary key,
    tenant_id   uuid not null references public.tenants (id) on delete cascade,
    job_id      uuid not null references public.jobs (id) on delete cascade,
    room_name   text not null check (length(room_name) between 1 and 200),
    -- RoomMeasurement JSON (walls, openings, floor polygon) – geometry only, no imagery.
    measurement jsonb not null check (jsonb_typeof(measurement) = 'object'),
    -- Selected price items with wastage: [{ itemID, wastePercent }]
    selections  jsonb not null default '[]'::jsonb check (jsonb_typeof(selections) = 'array'),
    captured_at timestamptz not null,
    updated_at  timestamptz not null,
    has_media   boolean not null default false,
    updated_by  uuid references auth.users (id) on delete set null,
    deleted_at  timestamptz,
    row_seq     bigint not null default nextval('public.sync_seq'),
    changed_at  timestamptz not null default clock_timestamp()
);
create index surveys_sync_idx on public.surveys (tenant_id, row_seq);
create index surveys_job_idx on public.surveys (job_id);

create table public.quotes (
    id                    uuid primary key,
    tenant_id             uuid not null references public.tenants (id) on delete cascade,
    job_id                uuid not null references public.jobs (id),
    -- preliminary = quick on-site offer, final = reviewed office offer.
    kind                  public.quote_kind not null default 'final',
    revision              integer not null check (revision > 0),
    -- The final quote that replaces an earlier (e.g. preliminary) one.
    supersedes_quote_id   uuid references public.quotes (id),
    provisional_number    text not null,
    final_number          text not null,
    issued_at             timestamptz not null,
    issued_by             uuid references auth.users (id) on delete set null,
    received_at           timestamptz not null default now(),
    price_book_version_id uuid not null references public.price_book_versions (id),
    engine_version        text not null,
    calculation           jsonb not null check (jsonb_typeof(calculation) = 'object'),
    snapshot_sha256       text not null check (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    net_total_cents       bigint not null check (net_total_cents >= 0),
    gross_total_cents     bigint not null check (gross_total_cents >= 0),
    -- Mutable lifecycle (the only columns that may change after issue).
    status                public.quote_status not null default 'issued',
    status_changed_at     timestamptz,
    status_changed_by     uuid references auth.users (id) on delete set null,
    client_signed_at      timestamptz,
    row_seq               bigint not null default nextval('public.sync_seq'),
    changed_at            timestamptz not null default clock_timestamp(),
    unique (tenant_id, final_number)
);
create index quotes_sync_idx on public.quotes (tenant_id, row_seq);
create index quotes_job_idx on public.quotes (job_id);

-- Gap-free official quote numbers per company and year.
create table public.quote_counters (
    tenant_id uuid not null references public.tenants (id) on delete cascade,
    year      integer not null,
    last_seq  integer not null,
    primary key (tenant_id, year)
);

-- -----------------------------------------------------------------------------
-- Sync, audit, abuse protection
-- -----------------------------------------------------------------------------

-- Idempotency store: a replayed mutation returns the stored result.
create table public.processed_mutations (
    idempotency_key uuid primary key,
    tenant_id       uuid not null references public.tenants (id) on delete cascade,
    user_id         uuid,
    kind            text not null,
    result          jsonb not null,
    processed_at    timestamptz not null default now()
);
create index processed_mutations_age_idx on public.processed_mutations (processed_at);

-- Security audit trail (12 months; worker activity for security purposes only).
create table public.audit_log (
    id         bigint generated always as identity primary key,
    tenant_id  uuid references public.tenants (id) on delete cascade,
    actor      uuid,
    action     text not null,
    entity_id  uuid,
    details    jsonb,
    created_at timestamptz not null default now()
);
create index audit_log_tenant_idx on public.audit_log (tenant_id, created_at);

-- Per-user fixed-window rate limiting for the RPC endpoints.
create table public.rate_limits (
    user_id      uuid not null,
    bucket       text not null,
    window_start timestamptz not null,
    hits         integer not null,
    primary key (user_id, bucket)
);

-- -----------------------------------------------------------------------------
-- Integrity triggers
-- -----------------------------------------------------------------------------

-- Every update gets a new row_seq + changed_at so pull_changes() picks it up.
create function app.bump_row_seq() returns trigger
language plpgsql set search_path = '' as $$
begin
    new.row_seq := nextval('public.sync_seq');
    new.changed_at := clock_timestamp();
    return new;
end $$;

create trigger tenants_bump_seq             before update on public.tenants             for each row execute function app.bump_row_seq();
create trigger tenant_members_bump_seq      before update on public.tenant_members      for each row execute function app.bump_row_seq();
create trigger price_book_versions_bump_seq before update on public.price_book_versions for each row execute function app.bump_row_seq();
create trigger jobs_bump_seq                before update on public.jobs                for each row execute function app.bump_row_seq();
create trigger surveys_bump_seq             before update on public.surveys             for each row execute function app.bump_row_seq();
create trigger quotes_bump_seq              before update on public.quotes              for each row execute function app.bump_row_seq();

-- Published price-book versions are immutable except for the active flag.
create function app.guard_price_book_version() returns trigger
language plpgsql set search_path = '' as $$
begin
    if (to_jsonb(new) - array['is_active', 'row_seq', 'changed_at'])
       is distinct from (to_jsonb(old) - array['is_active', 'row_seq', 'changed_at']) then
        raise exception 'published price-book versions are immutable; publish a new version';
    end if;
    return new;
end $$;

create trigger price_book_versions_immutable before update on public.price_book_versions
    for each row execute function app.guard_price_book_version();

-- Issued quotes are append-only: only the lifecycle columns may change, never deleted.
create function app.guard_quote() returns trigger
language plpgsql set search_path = '' as $$
declare
    mutable constant text[] := array['status', 'status_changed_at', 'status_changed_by', 'client_signed_at', 'row_seq', 'changed_at'];
begin
    if tg_op = 'DELETE' then
        raise exception 'issued quotes cannot be deleted';
    end if;
    if (to_jsonb(new) - mutable) is distinct from (to_jsonb(old) - mutable) then
        raise exception 'issued quotes are immutable; issue a new revision';
    end if;
    return new;
end $$;

create trigger quotes_append_only before update or delete on public.quotes
    for each row execute function app.guard_quote();
