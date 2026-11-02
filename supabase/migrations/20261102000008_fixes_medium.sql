-- =============================================================================
-- 08 · Medium-priority fixes from the code review (runs on top of 01–07)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- M1 · invite_member must not reveal other companies' members, and nobody is
--      moved into a company without consent
--
-- Every conflict (already a member somewhere, open invitation from another
-- company) now gets the same answer as a successful invitation – a fresh id –
-- and is recorded in audit_log only. An address that already has an account is
-- no longer added directly: it gets a pending invitation that the person
-- accepts in the app (get_my_invitation / accept_invitation). Brand-new
-- accounts still join on sign-up (signing up with the invited address is the
-- consent). get_my_invitation / accept_invitation cannot call require_member():
-- the caller is by definition not a member yet; they are rate-limited and
-- audited like every other function.
-- -----------------------------------------------------------------------------

create or replace function public.invite_member(p_email text, p_role public.member_role default 'estimator') returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_email  text := lower(trim(coalesce(p_email, '')));
    v_id     uuid;
begin
    v_member := app.require_member();
    perform app.enforce_rate_limit('invite', 30, interval '1 hour');

    if p_role = 'owner' then
        raise exception 'use transfer_ownership to change the owner' using errcode = '22023';
    end if;
    if v_member.role = 'estimator' or (v_member.role = 'admin' and p_role <> 'estimator') then
        raise exception 'not allowed to invite this role' using errcode = '42501';
    end if;
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        raise exception 'invalid e-mail address' using errcode = '22023';
    end if;

    -- Conflicts look exactly like success to the caller (no address probing).
    if exists (select 1 from public.tenant_members where email = v_email)
       or exists (select 1 from public.tenant_invitations
                  where email = v_email and accepted_at is null and expires_at > now()
                    and tenant_id <> v_member.tenant_id) then
        v_id := gen_random_uuid();
        perform app.audit(v_member.tenant_id, 'member.invite_conflict', v_id, jsonb_build_object('email', v_email, 'role', p_role));
        return v_id;
    end if;

    -- Replace this company's older invitation and any expired one for the address.
    delete from public.tenant_invitations
    where email = v_email and accepted_at is null and (tenant_id = v_member.tenant_id or expires_at <= now());

    -- Existing accounts get a pending invitation too; they accept it in the app.
    insert into public.tenant_invitations (tenant_id, email, role, invited_by)
    values (v_member.tenant_id, v_email, p_role, auth.uid())
    returning id into v_id;

    perform app.audit(v_member.tenant_id, 'member.invited', v_id, jsonb_build_object('email', v_email, 'role', p_role));
    return v_id;
end $$;

-- The open invitation for the signed-in account (if any), so the app can ask for consent.
create or replace function public.get_my_invitation() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_result jsonb;
begin
    if auth.uid() is null then
        raise exception 'not signed in' using errcode = '42501';
    end if;
    perform app.enforce_rate_limit('read', 120, interval '1 minute');
    select jsonb_build_object('id', i.id, 'company', t.name, 'role', i.role, 'expires_at', i.expires_at)
      into v_result
    from public.tenant_invitations i
    join public.tenants t on t.id = i.tenant_id
    join auth.users u on lower(u.email) = i.email
    where u.id = auth.uid() and i.accepted_at is null and i.expires_at > now() and t.is_active
    order by i.created_at desc
    limit 1;
    return v_result;
end $$;

-- Joins the company of the open invitation – only by the invited person themselves.
create or replace function public.accept_invitation() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    v_user  uuid := auth.uid();
    v_email text;
    inv     public.tenant_invitations;
begin
    if v_user is null then
        raise exception 'not signed in' using errcode = '42501';
    end if;
    perform app.enforce_rate_limit('invite', 30, interval '1 hour');
    if exists (select 1 from public.tenant_members where user_id = v_user) then
        raise exception 'already a member of a company' using errcode = '22023';
    end if;
    select lower(email) into v_email from auth.users where id = v_user;

    select i.* into inv
    from public.tenant_invitations i
    join public.tenants t on t.id = i.tenant_id
    where i.email = v_email and i.accepted_at is null and i.expires_at > now() and t.is_active
    order by i.created_at desc
    limit 1
    for update of i;
    if not found then
        raise exception 'no open invitation for this account' using errcode = '22023';
    end if;

    insert into public.tenant_members (user_id, tenant_id, role, email)
    values (v_user, inv.tenant_id, inv.role, v_email);
    update public.tenant_invitations set accepted_at = now(), accepted_by = v_user where id = inv.id;
    perform app.audit(inv.tenant_id, 'member.joined', v_user, jsonb_build_object('role', inv.role, 'consented', true));
    return inv.tenant_id;
end $$;

-- -----------------------------------------------------------------------------
-- M4 · Company details required on a German quote (Angebot)
-- -----------------------------------------------------------------------------

alter table public.tenants
    add column if not exists tax_number          text check (length(tax_number) <= 50),
    add column if not exists vat_id              text check (length(vat_id) <= 50),
    add column if not exists phone               text check (length(phone) <= 100),
    add column if not exists email               text check (length(email) <= 300),
    add column if not exists bank_iban           text check (length(bank_iban) <= 50),
    add column if not exists payment_terms       text check (length(payment_terms) <= 1000),
    add column if not exists quote_validity_days integer not null default 30 check (quote_validity_days between 1 and 365);

create or replace function app.m_update_tenant_settings(t public.tenants, v_role public.member_role, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
    if v_role not in ('owner', 'admin') then
        raise exception 'only Owner or Admin may change company settings';
    end if;
    update public.tenants set
        name                      = coalesce(nullif(p ->> 'name', ''), name),
        address                   = coalesce(p ->> 'address', address),
        quote_prefix              = coalesce(nullif(p ->> 'quote_prefix', ''), quote_prefix),
        media_device_only         = coalesce((p ->> 'media_device_only')::boolean, media_device_only),
        estimator_can_issue_final = coalesce((p ->> 'estimator_can_issue_final')::boolean, estimator_can_issue_final),
        privacy_notice            = coalesce(p ->> 'privacy_notice', privacy_notice),
        tax_number                = coalesce(p ->> 'tax_number', tax_number),
        vat_id                    = coalesce(p ->> 'vat_id', vat_id),
        phone                     = coalesce(p ->> 'phone', phone),
        email                     = coalesce(p ->> 'email', email),
        bank_iban                 = coalesce(p ->> 'bank_iban', bank_iban),
        payment_terms             = coalesce(p ->> 'payment_terms', payment_terms),
        quote_validity_days       = coalesce((p ->> 'quote_validity_days')::integer, quote_validity_days),
        updated_at                = now()
    where id = t.id;
    perform app.audit(t.id, 'company.settings_changed', t.id, p);
    return '{}'::jsonb;
end $$;

-- pull_changes also delivers the new company details (otherwise unchanged from 04).
create or replace function public.pull_changes(p_since bigint default 0, p_limit integer default 500) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_since  bigint := greatest(coalesce(p_since, 0), 0);
    v_limit  integer := least(greatest(coalesce(p_limit, 500), 1), 1000);
    v_settle timestamptz := clock_timestamp() - interval '15 seconds';
    v_upto   bigint;
    v_count  integer;
    v_tenant uuid;
begin
    v_member := app.require_member();
    v_tenant := v_member.tenant_id;
    perform app.enforce_rate_limit('pull', 120, interval '1 minute');

    select max(row_seq), count(*) into v_upto, v_count
    from (
        select row_seq from (
            select row_seq, changed_at from public.tenants             where id = v_tenant        and row_seq > v_since
            union all
            select row_seq, changed_at from public.tenant_members      where tenant_id = v_tenant and row_seq > v_since
            union all
            select row_seq, changed_at from public.price_book_versions where tenant_id = v_tenant and row_seq > v_since
            union all
            select row_seq, changed_at from public.jobs                where tenant_id = v_tenant and row_seq > v_since
            union all
            select row_seq, changed_at from public.surveys             where tenant_id = v_tenant and row_seq > v_since
            union all
            select row_seq, changed_at from public.quotes              where tenant_id = v_tenant and row_seq > v_since
        ) changes
        where changed_at <= v_settle
        order by row_seq
        limit v_limit
    ) page;
    v_upto := coalesce(v_upto, v_since);

    return jsonb_build_object(
        'cursor', v_upto,
        'has_more', v_count = v_limit,
        'tenant', (
            select jsonb_build_object(
                'id', id, 'name', name, 'address', address, 'quote_prefix', quote_prefix,
                'media_device_only', media_device_only, 'privacy_notice', privacy_notice,
                'estimator_can_issue_final', estimator_can_issue_final,
                'avv_signed', avv_signed_at is not null,
                'tax_number', tax_number, 'vat_id', vat_id, 'phone', phone, 'email', email,
                'bank_iban', bank_iban, 'payment_terms', payment_terms,
                'quote_validity_days', quote_validity_days)
            from public.tenants where id = v_tenant and row_seq > v_since and row_seq <= v_upto),
        'members', coalesce((
            select jsonb_agg(jsonb_build_object('user_id', user_id, 'email', email, 'display_name', display_name,
                                                'role', role) order by row_seq)
            from public.tenant_members where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb),
        'price_book_versions', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', id, 'price_book_id', price_book_id, 'name', name, 'version', version,
                'vat_rate_bp', vat_rate_bp, 'published_at', published_at, 'items', items, 'is_active', is_active)
                order by row_seq)
            from public.price_book_versions where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb),
        'jobs', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', id, 'title', title, 'client_name', client_name, 'client_email', client_email,
                'client_phone', client_phone, 'site_address', site_address,
                'privacy_notice_confirmed_at', privacy_notice_confirmed_at,
                'client_data_erased_at', client_data_erased_at, 'created_by', created_by,
                'created_at', created_at, 'updated_at', updated_at, 'deleted_at', deleted_at)
                order by row_seq)
            from public.jobs where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb),
        'surveys', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', id, 'job_id', job_id, 'room_name', room_name, 'measurement', measurement,
                'selections', selections, 'captured_at', captured_at, 'updated_at', updated_at,
                'has_media', has_media, 'deleted_at', deleted_at)
                order by row_seq)
            from public.surveys where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb),
        'quotes', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', id, 'job_id', job_id, 'kind', kind, 'revision', revision,
                'supersedes_quote_id', supersedes_quote_id, 'provisional_number', provisional_number,
                'final_number', final_number, 'issued_at', issued_at, 'issued_by', issued_by,
                'price_book_version_id', price_book_version_id, 'engine_version', engine_version,
                'calculation', calculation, 'snapshot_sha256', snapshot_sha256,
                'net_total_cents', net_total_cents, 'gross_total_cents', gross_total_cents,
                'status', status, 'status_changed_at', status_changed_at, 'client_signed_at', client_signed_at)
                order by row_seq)
            from public.quotes where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb),
        -- Kept for the current app version (maps provisional → official numbers).
        'quote_numbers', coalesce((
            select jsonb_agg(jsonb_build_object('quote_id', id, 'final_number', final_number) order by row_seq)
            from public.quotes where tenant_id = v_tenant and row_seq > v_since and row_seq <= v_upto), '[]'::jsonb)
    );
end $$;

-- =============================================================================
-- Permissions: keep the whitelist model (blanket revoke, explicit grants)
-- =============================================================================

revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app    from public, anon, authenticated;

-- App API (unchanged from 04 – must be re-granted after the blanket revoke).
grant execute on function public.push_mutations(jsonb)                                to authenticated;
grant execute on function public.pull_changes(bigint, integer)                        to authenticated;
grant execute on function public.publish_price_book_version(uuid, text, integer, jsonb) to authenticated;
grant execute on function public.set_active_price_book_version(uuid)                  to authenticated;
grant execute on function public.invite_member(text, public.member_role)              to authenticated;
grant execute on function public.revoke_invitation(uuid)                              to authenticated;
grant execute on function public.remove_member(uuid)                                  to authenticated;
grant execute on function public.change_member_role(uuid, public.member_role)         to authenticated;
grant execute on function public.transfer_ownership(uuid)                             to authenticated;
grant execute on function public.get_team()                                           to authenticated;
grant execute on function public.erase_client_data(uuid)                              to authenticated;
grant execute on function public.export_company_data()                                to authenticated;
grant execute on function public.get_my_invitation()                                  to authenticated;
grant execute on function public.accept_invitation()                                  to authenticated;

-- Helpers used by storage policies.
grant execute on function app.tenant_id()             to authenticated;
grant execute on function app.user_role()             to authenticated;
grant execute on function app.current_membership()    to authenticated;
grant execute on function app.media_path_allowed(text) to authenticated;
grant execute on function app.media_upload_allowed()  to authenticated;

-- Operator functions: service_role only.
grant execute on function public.admin_create_company(text, text, text, text) to service_role;
grant execute on function public.admin_record_avv(uuid, text)                 to service_role;
grant execute on function public.admin_set_company_active(uuid, boolean)      to service_role;
grant execute on function public.admin_list_suspect_privacy_stamps()          to service_role;
grant execute on function public.admin_delete_company(uuid, text)             to service_role;
grant execute on function public.admin_media_retention_candidates(integer)    to service_role;
grant execute on function public.admin_mark_media_purged(uuid, integer)       to service_role;

-- Auth hooks: Supabase Auth only.
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
