-- =============================================================================
-- 04 · API (the ONLY way the app talks to the database)
--
-- Called through PostgREST as POST /rest/v1/rpc/<name> with the user's JWT.
-- Every function:
--   * resolves company + role live from tenant_members (never from input),
--   * enforces role permissions,
--   * is rate-limited per user,
--   * validates its input and records security-relevant actions in audit_log.
--
-- App (authenticated):
--   push_mutations, pull_changes
-- Owner/Admin:
--   publish_price_book_version, set_active_price_book_version,
--   invite_member, revoke_invitation, remove_member, get_team,
--   erase_client_data
-- Owner only:
--   change_member_role, transfer_ownership, export_company_data
-- Operator only (service_role / SQL editor):
--   admin_create_company, admin_record_avv, admin_set_company_active
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------------

-- Fixed-window rate limit per user and bucket. Raises HTTP 429 via PostgREST.
create function app.enforce_rate_limit(p_bucket text, p_max integer, p_window interval) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_hits integer;
begin
    insert into public.rate_limits as r (user_id, bucket, window_start, hits)
    values (auth.uid(), p_bucket, now(), 1)
    on conflict (user_id, bucket) do update set
        hits         = case when r.window_start < now() - p_window then 1 else r.hits + 1 end,
        window_start = case when r.window_start < now() - p_window then now() else r.window_start end
    returning hits into v_hits;

    if v_hits > p_max then
        raise exception 'rate limit exceeded, try again later' using errcode = 'PT429';
    end if;
end $$;

-- Current membership or HTTP 403.
create function app.require_member(out tenant_id uuid, out role public.member_role)
language plpgsql stable security definer set search_path = '' as $$
begin
    select m.tenant_id, m.role into tenant_id, role from app.current_membership() m;
    if tenant_id is null or auth.uid() is null then
        raise exception 'no active company membership' using errcode = '42501';
    end if;
end $$;

-- Client timestamps are trusted for last-writer-wins, but never beyond "now + 5 min",
-- so a device with a wrong clock cannot lock a record forever.
create function app.client_ts(p_value text) returns timestamptz
language sql stable set search_path = '' as $$
    select least(coalesce(p_value::timestamptz, now()), now() + interval '5 minutes')
$$;

-- Validates a price-book item array (shape of the app's PriceItem JSON).
create function app.valid_price_items(p_items jsonb) returns boolean
language sql immutable set search_path = '' as $$
    select jsonb_typeof(p_items) = 'array'
       and jsonb_array_length(p_items) between 1 and 2000
       and not exists (
            select 1 from jsonb_array_elements(p_items) as e(item)
            where not (
                jsonb_typeof(item) = 'object'
                and coalesce(item ->> 'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                and length(coalesce(item ->> 'code', '')) between 1 and 50
                and length(coalesce(item ->> 'name', '')) between 1 and 300
                and coalesce(item ->> 'basis', '') in ('wallArea', 'floorArea', 'ceilingArea', 'skirtingLength',
                                                       'revealLength', 'doorCount', 'windowCount', 'fixedPiece')
                and jsonb_typeof(item -> 'unitPriceCents') = 'number'
                and (item ->> 'unitPriceCents')::numeric between 0 and 100000000
                and (item ->> 'unitPriceCents')::numeric = trunc((item ->> 'unitPriceCents')::numeric)
                and jsonb_typeof(item -> 'defaultWastePercent') = 'number'
                and (item ->> 'defaultWastePercent')::numeric between 0 and 100
                and jsonb_typeof(item -> 'openingRule') = 'object'
                and coalesce(item -> 'openingRule' ->> 'mode', '') in ('none', 'all', 'aboveThreshold')
                and jsonb_typeof(item -> 'openingRule' -> 'thresholdM2') = 'number'
                and jsonb_typeof(item -> 'openingRule' -> 'addReveals') = 'boolean'
                and jsonb_typeof(item -> 'openingRule' -> 'revealDepthM') = 'number'
            )
       )
       and (select count(distinct lower(item ->> 'id')) from jsonb_array_elements(p_items) as e(item))
           = jsonb_array_length(p_items)
$$;

-- -----------------------------------------------------------------------------
-- Mutation handlers (internal; called only by push_mutations)
-- -----------------------------------------------------------------------------

create function app.m_upsert_job(t public.tenants, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_job public.jobs;
    v_id uuid := (p ->> 'id')::uuid;
    v_updated timestamptz := app.client_ts(p ->> 'updated_at');
begin
    if t.avv_signed_at is null then
        raise exception 'AVV (data-processing agreement) not signed for this company';
    end if;

    select * into v_job from public.jobs where id = v_id for update;
    if found and v_job.tenant_id <> t.id then
        raise exception 'id conflict';
    end if;

    if not found then
        insert into public.jobs (id, tenant_id, title, client_name, client_email, client_phone, site_address,
                                 privacy_notice_confirmed_at, created_by, updated_by, updated_at)
        values (v_id, t.id, p ->> 'title', p ->> 'client_name', p ->> 'client_email', p ->> 'client_phone',
                p ->> 'site_address', app.client_ts(p ->> 'privacy_notice_confirmed_at'), v_user, v_user, v_updated);
        return '{}'::jsonb;
    end if;

    if v_job.deleted_at is not null then
        return jsonb_build_object('note', 'job was deleted; change ignored');
    end if;
    if v_updated < v_job.updated_at then
        return jsonb_build_object('note', 'newer version on server; change ignored');
    end if;

    update public.jobs set
        title        = case when client_data_erased_at is null then p ->> 'title' else title end,
        -- Erased client data is never re-imported from a device that still holds it.
        client_name  = case when client_data_erased_at is null then p ->> 'client_name'  else client_name  end,
        client_email = case when client_data_erased_at is null then p ->> 'client_email' else client_email end,
        client_phone = case when client_data_erased_at is null then p ->> 'client_phone' else client_phone end,
        site_address = case when client_data_erased_at is null then p ->> 'site_address' else site_address end,
        privacy_notice_confirmed_at = coalesce(privacy_notice_confirmed_at, app.client_ts(p ->> 'privacy_notice_confirmed_at')),
        updated_at = v_updated,
        updated_by = v_user
    where id = v_id;
    return '{}'::jsonb;
end $$;

create function app.m_delete_job(t public.tenants, v_role public.member_role, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_job public.jobs;
begin
    select * into v_job from public.jobs where id = (p ->> 'id')::uuid and tenant_id = t.id for update;
    if not found then
        raise exception 'unknown job';
    end if;
    if v_role = 'estimator' and v_job.created_by is distinct from v_user then
        raise exception 'estimators can only delete their own jobs';
    end if;
    if v_job.deleted_at is null then
        update public.jobs set deleted_at = now(), updated_at = now(), updated_by = v_user where id = v_job.id;
        update public.surveys set deleted_at = now(), updated_at = now(), updated_by = v_user
        where job_id = v_job.id and deleted_at is null;
        perform app.audit(t.id, 'job.deleted', v_job.id);
    end if;
    return '{}'::jsonb;
end $$;

create function app.m_upsert_survey(t public.tenants, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_survey public.surveys;
    v_id uuid := (p ->> 'id')::uuid;
    v_job_id uuid := (p ->> 'job_id')::uuid;
    v_updated timestamptz := app.client_ts(p ->> 'updated_at');
begin
    if t.avv_signed_at is null then
        raise exception 'AVV (data-processing agreement) not signed for this company';
    end if;
    if not exists (select 1 from public.jobs where id = v_job_id and tenant_id = t.id and deleted_at is null) then
        raise exception 'unknown job';
    end if;
    if jsonb_typeof(p -> 'measurement') is distinct from 'object' then
        raise exception 'measurement must be an object';
    end if;
    if p ? 'selections' and jsonb_typeof(p -> 'selections') <> 'array' then
        raise exception 'selections must be an array';
    end if;

    select * into v_survey from public.surveys where id = v_id for update;
    if found and (v_survey.tenant_id <> t.id or v_survey.job_id <> v_job_id) then
        raise exception 'id conflict';
    end if;

    if not found then
        insert into public.surveys (id, tenant_id, job_id, room_name, measurement, selections,
                                    captured_at, updated_at, has_media, updated_by)
        values (v_id, t.id, v_job_id, p ->> 'room_name', p -> 'measurement', coalesce(p -> 'selections', '[]'::jsonb),
                app.client_ts(p ->> 'captured_at'), v_updated, coalesce((p ->> 'has_media')::boolean, false), v_user);
        return '{}'::jsonb;
    end if;

    if v_survey.deleted_at is not null then
        return jsonb_build_object('note', 'room was deleted; change ignored');
    end if;
    if v_updated < v_survey.updated_at then
        return jsonb_build_object('note', 'newer version on server; change ignored');
    end if;

    update public.surveys set
        room_name   = p ->> 'room_name',
        measurement = p -> 'measurement',
        selections  = coalesce(p -> 'selections', selections),
        has_media   = coalesce((p ->> 'has_media')::boolean, has_media),
        updated_at  = v_updated,
        updated_by  = v_user
    where id = v_id;
    return '{}'::jsonb;
end $$;

create function app.m_delete_survey(t public.tenants, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
    update public.surveys set deleted_at = now(), updated_at = now(), updated_by = v_user
    where id = (p ->> 'id')::uuid and tenant_id = t.id and deleted_at is null;
    return '{}'::jsonb;
end $$;

create function app.m_issue_quote(t public.tenants, v_role public.member_role, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_id        uuid := (p ->> 'id')::uuid;
    v_job_id    uuid := (p ->> 'job_id')::uuid;
    v_kind      public.quote_kind := coalesce((p ->> 'kind')::public.quote_kind, 'final');
    v_supersede uuid := (p ->> 'supersedes_quote_id')::uuid;
    v_year      integer;
    v_seq       integer;
    v_number    text;
begin
    if t.avv_signed_at is null then
        raise exception 'AVV (data-processing agreement) not signed for this company';
    end if;
    if v_kind = 'final' and v_role = 'estimator' and not t.estimator_can_issue_final then
        raise exception 'only Owner or Admin may issue final quotes';
    end if;
    if not exists (select 1 from public.jobs where id = v_job_id and tenant_id = t.id and deleted_at is null) then
        raise exception 'unknown job';
    end if;
    if not exists (select 1 from public.price_book_versions
                   where id = (p ->> 'price_book_version_id')::uuid and tenant_id = t.id) then
        raise exception 'unknown price-book version (quotes from the sample price book cannot be finalized)';
    end if;
    if v_supersede is not null and not exists (
        select 1 from public.quotes where id = v_supersede and job_id = v_job_id and tenant_id = t.id) then
        raise exception 'superseded quote not found for this job';
    end if;
    if exists (select 1 from public.quotes where id = v_id) then
        raise exception 'quote already exists';
    end if;
    if jsonb_typeof(p -> 'calculation') is distinct from 'object'
       or (p -> 'calculation' ->> 'netTotalCents')::bigint   is distinct from (p ->> 'net_total_cents')::bigint
       or (p -> 'calculation' ->> 'grossTotalCents')::bigint is distinct from (p ->> 'gross_total_cents')::bigint then
        raise exception 'totals do not match the calculation';
    end if;

    -- Official number <PREFIX>-<YEAR>-<00001>, gap-free per company and year.
    -- Runs inside the item's subtransaction: a failure rolls the counter back.
    v_year := extract(year from (now() at time zone 'Europe/Berlin'))::integer;
    insert into public.quote_counters as c (tenant_id, year, last_seq)
    values (t.id, v_year, 1)
    on conflict (tenant_id, year) do update set last_seq = c.last_seq + 1
    returning last_seq into v_seq;
    v_number := t.quote_prefix || '-' || v_year || '-' || lpad(v_seq::text, 5, '0');

    insert into public.quotes (id, tenant_id, job_id, kind, revision, supersedes_quote_id, provisional_number,
                               final_number, issued_at, issued_by, price_book_version_id, engine_version,
                               calculation, snapshot_sha256, net_total_cents, gross_total_cents)
    values (v_id, t.id, v_job_id, v_kind, (p ->> 'revision')::integer, v_supersede, p ->> 'provisional_number',
            v_number, app.client_ts(p ->> 'issued_at'), v_user, (p ->> 'price_book_version_id')::uuid,
            p ->> 'engine_version', p -> 'calculation', p ->> 'snapshot_sha256',
            (p ->> 'net_total_cents')::bigint, (p ->> 'gross_total_cents')::bigint);

    if v_supersede is not null then
        update public.quotes
        set status = 'superseded', status_changed_at = now(), status_changed_by = v_user
        where id = v_supersede and status in ('issued', 'sent');
    end if;

    perform app.audit(t.id, 'quote.issued', v_id, jsonb_build_object(
        'final_number', v_number, 'provisional_number', p ->> 'provisional_number', 'kind', v_kind,
        'price_book_version_id', p ->> 'price_book_version_id', 'engine_version', p ->> 'engine_version',
        'snapshot_sha256', p ->> 'snapshot_sha256'));

    return jsonb_build_object('quote_id', v_id, 'final_number', v_number);
end $$;

create function app.m_set_quote_status(t public.tenants, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_quote  public.quotes;
    v_status public.quote_status := (p ->> 'status')::public.quote_status;
begin
    select * into v_quote from public.quotes where id = (p ->> 'quote_id')::uuid and tenant_id = t.id for update;
    if not found then
        raise exception 'unknown quote';
    end if;
    if v_status not in ('sent', 'accepted', 'rejected') then
        raise exception 'status must be sent, accepted or rejected';
    end if;
    if not (v_quote.status = 'issued' or (v_quote.status = 'sent' and v_status in ('accepted', 'rejected'))) then
        raise exception 'cannot change a % quote to %', v_quote.status, v_status;
    end if;

    update public.quotes set
        status = v_status,
        status_changed_at = now(),
        status_changed_by = v_user,
        client_signed_at = case when v_status = 'accepted' then app.client_ts(p ->> 'client_signed_at') else client_signed_at end
    where id = v_quote.id;

    perform app.audit(t.id, 'quote.status_changed', v_quote.id, jsonb_build_object('status', v_status));
    return '{}'::jsonb;
end $$;

create function app.m_update_tenant_settings(t public.tenants, v_role public.member_role, p jsonb) returns jsonb
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
        updated_at                = now()
    where id = t.id;
    perform app.audit(t.id, 'company.settings_changed', t.id, p);
    return '{}'::jsonb;
end $$;

-- -----------------------------------------------------------------------------
-- push_mutations – idempotent, ordered batch of typed mutations
--
-- Item:   { "idempotency_key": uuid, "kind": text, "payload": object }
-- Kinds:  upsert_job, delete_job, upsert_survey, delete_survey, issue_quote,
--         set_quote_status, update_tenant_settings
-- Result: [{ idempotency_key, status: applied|duplicate|rejected,
--            quote_id?, final_number?, note?, error? }]
-- Each item runs in its own subtransaction: one rejected item never blocks others.
-- -----------------------------------------------------------------------------

create function public.push_mutations(p_batch jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_user    uuid := auth.uid();
    v_member  record;
    t         public.tenants;
    v_item    jsonb;
    v_key     uuid;
    v_kind    text;
    p         jsonb;
    v_stored  public.processed_mutations;
    v_result  jsonb;
    v_results jsonb := '[]'::jsonb;
begin
    v_member := app.require_member();
    perform app.enforce_rate_limit('push', 60, interval '1 minute');

    if jsonb_typeof(p_batch) is distinct from 'array' or jsonb_array_length(p_batch) > 100 then
        raise exception 'batch must be an array of at most 100 mutations' using errcode = '22023';
    end if;
    if pg_column_size(p_batch) > 8 * 1024 * 1024 then
        raise exception 'batch too large' using errcode = '22023';
    end if;

    select * into t from public.tenants where id = v_member.tenant_id;

    for v_item in select value from jsonb_array_elements(p_batch) loop
        begin
            v_key  := (v_item ->> 'idempotency_key')::uuid;
            v_kind := v_item ->> 'kind';
            p      := v_item -> 'payload';
            if v_key is null or jsonb_typeof(p) is distinct from 'object' then
                raise exception 'idempotency_key and payload object are required';
            end if;

            -- Replay of an already applied mutation → return the stored result.
            select * into v_stored from public.processed_mutations where idempotency_key = v_key;
            if found then
                if v_stored.tenant_id <> t.id then
                    raise exception 'idempotency key conflict';
                end if;
                v_results := v_results || jsonb_build_array(v_stored.result || jsonb_build_object('status', 'duplicate'));
                continue;
            end if;

            v_result := case v_kind
                when 'upsert_job'             then app.m_upsert_job(t, v_user, p)
                when 'delete_job'             then app.m_delete_job(t, v_member.role, v_user, p)
                when 'upsert_survey'          then app.m_upsert_survey(t, v_user, p)
                when 'delete_survey'          then app.m_delete_survey(t, v_user, p)
                when 'issue_quote'            then app.m_issue_quote(t, v_member.role, v_user, p)
                when 'set_quote_status'       then app.m_set_quote_status(t, v_user, p)
                when 'update_tenant_settings' then app.m_update_tenant_settings(t, v_member.role, p)
            end;
            if v_result is null then
                raise exception 'unknown mutation kind %', coalesce(v_kind, 'null');
            end if;

            v_result := jsonb_build_object('idempotency_key', v_key, 'status', 'applied') || v_result;
            insert into public.processed_mutations (idempotency_key, tenant_id, user_id, kind, result)
            values (v_key, t.id, v_user, v_kind, v_result);

            -- Settings may have changed within this batch.
            if v_kind = 'update_tenant_settings' then
                select * into t from public.tenants where id = t.id;
            end if;
        exception when others then
            v_result := jsonb_build_object('idempotency_key', v_item ->> 'idempotency_key',
                                           'status', 'rejected', 'error', sqlerrm);
        end;
        v_results := v_results || jsonb_build_array(v_result);
    end loop;

    return v_results;
end $$;

-- -----------------------------------------------------------------------------
-- pull_changes – everything of the user's company that changed after p_since
--
-- Returns rows ordered by the global change sequence, at most p_limit changes
-- per call ("has_more" = call again with the returned cursor). Changes from the
-- last 15 s are held back so that rows of still-running transactions (lower
-- sequence numbers, not yet visible) can never be skipped.
-- -----------------------------------------------------------------------------

create function public.pull_changes(p_since bigint default 0, p_limit integer default 500) returns jsonb
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
                'avv_signed', avv_signed_at is not null)
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

-- -----------------------------------------------------------------------------
-- Price books (Owner/Admin)
-- -----------------------------------------------------------------------------

-- Publishes a new immutable version and makes it the active one of its book.
-- Pass p_price_book_id = null to create a new price book.
create function public.publish_price_book_version(
    p_price_book_id uuid, p_name text, p_vat_rate_bp integer, p_items jsonb
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    v_member  record;
    v_book_id uuid := p_price_book_id;
    v_version integer;
    v_id      uuid;
begin
    v_member := app.require_member();
    if v_member.role not in ('owner', 'admin') then
        raise exception 'only Owner or Admin may publish price books' using errcode = '42501';
    end if;
    perform app.enforce_rate_limit('admin', 60, interval '1 hour');

    if length(coalesce(p_name, '')) not between 1 and 200 then
        raise exception 'name is required' using errcode = '22023';
    end if;
    if p_vat_rate_bp is null or p_vat_rate_bp not between 0 and 10000 then
        raise exception 'vat rate must be 0..10000 basis points' using errcode = '22023';
    end if;
    if not app.valid_price_items(p_items) then
        raise exception 'invalid price items (see PriceItem format)' using errcode = '22023';
    end if;

    if v_book_id is null then
        insert into public.price_books (tenant_id, name) values (v_member.tenant_id, p_name) returning id into v_book_id;
    elsif not exists (select 1 from public.price_books where id = v_book_id and tenant_id = v_member.tenant_id) then
        raise exception 'unknown price book' using errcode = '22023';
    end if;

    -- Serialise concurrent publishes of the same book.
    perform 1 from public.price_books where id = v_book_id for update;
    select coalesce(max(version), 0) + 1 into v_version from public.price_book_versions where price_book_id = v_book_id;

    update public.price_book_versions set is_active = false where price_book_id = v_book_id and is_active;

    insert into public.price_book_versions (tenant_id, price_book_id, name, version, vat_rate_bp, items, is_active, published_by)
    values (v_member.tenant_id, v_book_id, p_name, v_version, p_vat_rate_bp, p_items, true, auth.uid())
    returning id into v_id;

    perform app.audit(v_member.tenant_id, 'price_book.published', v_id, jsonb_build_object('version', v_version));
    return v_id;
end $$;

-- Re-activates an older version (e.g. to roll back a wrong publish).
create function public.set_active_price_book_version(p_version_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_book   uuid;
begin
    v_member := app.require_member();
    if v_member.role not in ('owner', 'admin') then
        raise exception 'only Owner or Admin may change price books' using errcode = '42501';
    end if;
    select price_book_id into v_book from public.price_book_versions
    where id = p_version_id and tenant_id = v_member.tenant_id;
    if v_book is null then
        raise exception 'unknown price-book version' using errcode = '22023';
    end if;
    update public.price_book_versions set is_active = (id = p_version_id)
    where price_book_id = v_book and (is_active or id = p_version_id);
    perform app.audit(v_member.tenant_id, 'price_book.activated', p_version_id);
end $$;

-- -----------------------------------------------------------------------------
-- Team management
-- -----------------------------------------------------------------------------

-- Owner invites admins/estimators; admins invite estimators. The invited person
-- then signs in with their e-mail in the app (one-time code).
create function public.invite_member(p_email text, p_role public.member_role default 'estimator') returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_email  text := lower(trim(coalesce(p_email, '')));
    v_user   uuid;
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
    if exists (select 1 from public.tenant_members where email = v_email) then
        raise exception 'this person is already a member of a company' using errcode = '22023';
    end if;
    if exists (select 1 from public.tenant_invitations
               where email = v_email and accepted_at is null and tenant_id <> v_member.tenant_id and expires_at > now()) then
        raise exception 'this person has a pending invitation from another company' using errcode = '22023';
    end if;

    -- Replace older invitations for the same address.
    delete from public.tenant_invitations where email = v_email and accepted_at is null;

    select id into v_user from auth.users where lower(email) = v_email;
    if v_user is not null then
        -- Account already exists (e.g. left another company): add directly.
        insert into public.tenant_members (user_id, tenant_id, role, email)
        values (v_user, v_member.tenant_id, p_role, v_email);
        insert into public.tenant_invitations (tenant_id, email, role, invited_by, accepted_at, accepted_by)
        values (v_member.tenant_id, v_email, p_role, auth.uid(), now(), v_user)
        returning id into v_id;
    else
        insert into public.tenant_invitations (tenant_id, email, role, invited_by)
        values (v_member.tenant_id, v_email, p_role, auth.uid())
        returning id into v_id;
    end if;

    perform app.audit(v_member.tenant_id, 'member.invited', v_id, jsonb_build_object('email', v_email, 'role', p_role));
    return v_id;
end $$;

create function public.revoke_invitation(p_invitation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
begin
    v_member := app.require_member();
    if v_member.role = 'estimator' then
        raise exception 'only Owner or Admin may manage invitations' using errcode = '42501';
    end if;
    delete from public.tenant_invitations
    where id = p_invitation_id and tenant_id = v_member.tenant_id and accepted_at is null;
    perform app.audit(v_member.tenant_id, 'member.invitation_revoked', p_invitation_id);
end $$;

create function public.remove_member(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_target public.tenant_members;
begin
    v_member := app.require_member();
    select * into v_target from public.tenant_members where user_id = p_user_id and tenant_id = v_member.tenant_id;
    if not found then
        raise exception 'unknown member' using errcode = '22023';
    end if;
    if v_target.role = 'owner' then
        raise exception 'the owner cannot be removed' using errcode = '42501';
    end if;
    if v_member.role = 'estimator' or (v_member.role = 'admin' and v_target.role <> 'estimator') then
        raise exception 'not allowed to remove this member' using errcode = '42501';
    end if;
    -- Access ends immediately: every request checks tenant_members live.
    delete from public.tenant_members where user_id = p_user_id;
    perform app.audit(v_member.tenant_id, 'member.removed', p_user_id);
end $$;

-- Only the owner changes roles (admin ↔ estimator).
create function public.change_member_role(p_user_id uuid, p_role public.member_role) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
begin
    v_member := app.require_member();
    if v_member.role <> 'owner' then
        raise exception 'only the Owner may change roles' using errcode = '42501';
    end if;
    if p_role = 'owner' or p_user_id = auth.uid() then
        raise exception 'use transfer_ownership to change the owner' using errcode = '22023';
    end if;
    update public.tenant_members set role = p_role
    where user_id = p_user_id and tenant_id = v_member.tenant_id;
    if not found then
        raise exception 'unknown member' using errcode = '22023';
    end if;
    perform app.audit(v_member.tenant_id, 'member.role_changed', p_user_id, jsonb_build_object('role', p_role));
end $$;

create function public.transfer_ownership(p_new_owner uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
begin
    v_member := app.require_member();
    if v_member.role <> 'owner' then
        raise exception 'only the Owner may transfer ownership' using errcode = '42501';
    end if;
    if not exists (select 1 from public.tenant_members where user_id = p_new_owner and tenant_id = v_member.tenant_id)
       or p_new_owner = auth.uid() then
        raise exception 'unknown member' using errcode = '22023';
    end if;
    update public.tenant_members set role = 'admin' where user_id = auth.uid();
    update public.tenant_members set role = 'owner' where user_id = p_new_owner;
    perform app.audit(v_member.tenant_id, 'company.ownership_transferred', p_new_owner);
end $$;

create function public.get_team() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
begin
    v_member := app.require_member();
    perform app.enforce_rate_limit('read', 120, interval '1 minute');
    return jsonb_build_object(
        'members', coalesce((
            select jsonb_agg(jsonb_build_object('user_id', user_id, 'email', email, 'display_name', display_name,
                                                'role', role, 'joined_at', created_at) order by created_at)
            from public.tenant_members where tenant_id = v_member.tenant_id), '[]'::jsonb),
        'invitations', case when v_member.role = 'estimator' then '[]'::jsonb else coalesce((
            select jsonb_agg(jsonb_build_object('id', id, 'email', email, 'role', role, 'expires_at', expires_at)
                             order by created_at)
            from public.tenant_invitations
            where tenant_id = v_member.tenant_id and accepted_at is null and expires_at > now()), '[]'::jsonb) end
    );
end $$;

-- -----------------------------------------------------------------------------
-- Data protection (GDPR)
-- -----------------------------------------------------------------------------

-- Art. 17: erases the end client's personal data on a job. Quotes stay (commercial
-- retention) – they contain prices and room geometry, not the client's identity.
-- Returns the storage folder whose media the app must delete.
create function public.erase_client_data(p_job_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
begin
    v_member := app.require_member();
    if v_member.role = 'estimator' then
        raise exception 'only Owner or Admin may erase client data' using errcode = '42501';
    end if;
    update public.jobs set
        title = 'Erased job', client_name = null, client_email = null, client_phone = null, site_address = null,
        client_data_erased_at = now(), updated_at = now(), updated_by = auth.uid()
    where id = p_job_id and tenant_id = v_member.tenant_id;
    if not found then
        raise exception 'unknown job' using errcode = '22023';
    end if;
    update public.surveys set has_media = false, updated_at = now() where job_id = p_job_id;
    perform app.audit(v_member.tenant_id, 'client.erased', p_job_id);
    return jsonb_build_object('media_folder', v_member.tenant_id::text || '/' || p_job_id::text);
end $$;

-- Full company export (Owner) – data portability / switching.
create function public.export_company_data() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_member record;
    v_tenant uuid;
begin
    v_member := app.require_member();
    if v_member.role <> 'owner' then
        raise exception 'only the Owner may export company data' using errcode = '42501';
    end if;
    perform app.enforce_rate_limit('export', 5, interval '1 hour');
    v_tenant := v_member.tenant_id;
    perform app.audit(v_tenant, 'company.exported', v_tenant);

    return jsonb_build_object(
        'exported_at', now(),
        'company', (select to_jsonb(t) - 'row_seq' - 'changed_at' from public.tenants t where id = v_tenant),
        'members', coalesce((select jsonb_agg(to_jsonb(m) - 'row_seq' - 'changed_at') from public.tenant_members m where tenant_id = v_tenant), '[]'::jsonb),
        'price_books', coalesce((select jsonb_agg(to_jsonb(b)) from public.price_books b where tenant_id = v_tenant), '[]'::jsonb),
        'price_book_versions', coalesce((select jsonb_agg(to_jsonb(v) - 'row_seq' - 'changed_at') from public.price_book_versions v where tenant_id = v_tenant), '[]'::jsonb),
        'jobs', coalesce((select jsonb_agg(to_jsonb(j) - 'row_seq' - 'changed_at') from public.jobs j where tenant_id = v_tenant), '[]'::jsonb),
        'surveys', coalesce((select jsonb_agg(to_jsonb(s) - 'row_seq' - 'changed_at') from public.surveys s where tenant_id = v_tenant), '[]'::jsonb),
        'quotes', coalesce((select jsonb_agg(to_jsonb(q) - 'row_seq' - 'changed_at') from public.quotes q where tenant_id = v_tenant), '[]'::jsonb)
    );
end $$;

-- -----------------------------------------------------------------------------
-- Operator functions (service_role / SQL editor only – never callable by the app)
-- -----------------------------------------------------------------------------

-- Creates a company and an owner invitation (valid 7 days). The owner then
-- signs in in the app with this e-mail address.
create function public.admin_create_company(
    p_name text, p_quote_prefix text, p_owner_email text, p_avv_version text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    v_tenant uuid;
    v_email  text := lower(trim(p_owner_email));
begin
    insert into public.tenants (name, quote_prefix, avv_version, avv_signed_at)
    values (p_name, upper(p_quote_prefix), p_avv_version, case when p_avv_version is not null then now() end)
    returning id into v_tenant;

    insert into public.tenant_invitations (tenant_id, email, role, expires_at)
    values (v_tenant, v_email, 'owner', now() + interval '7 days');

    insert into public.audit_log (tenant_id, action, entity_id, details)
    values (v_tenant, 'company.created', v_tenant, jsonb_build_object('owner_email', v_email));
    return v_tenant;
end $$;

-- Records the signed data-processing agreement (unlocks client data).
create function public.admin_record_avv(p_tenant_id uuid, p_avv_version text) returns void
language sql security definer set search_path = '' as $$
    update public.tenants set avv_signed_at = now(), avv_version = p_avv_version, updated_at = now() where id = p_tenant_id;
    insert into public.audit_log (tenant_id, action, entity_id, details)
    values (p_tenant_id, 'company.avv_recorded', p_tenant_id, jsonb_build_object('version', p_avv_version));
$$;

-- Suspends / re-activates a company (e.g. unpaid subscription). Takes effect immediately.
create function public.admin_set_company_active(p_tenant_id uuid, p_active boolean) returns void
language sql security definer set search_path = '' as $$
    update public.tenants set is_active = p_active, updated_at = now() where id = p_tenant_id;
    insert into public.audit_log (tenant_id, action, entity_id, details)
    values (p_tenant_id, 'company.active_changed', p_tenant_id, jsonb_build_object('active', p_active));
$$;

-- -----------------------------------------------------------------------------
-- Permissions: whitelist exactly the API surface
-- -----------------------------------------------------------------------------

revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app    from public, anon, authenticated;

-- App API (logged-in users; each function checks membership and role itself).
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

-- Helpers used by storage policies.
grant execute on function app.tenant_id()          to authenticated;
grant execute on function app.user_role()          to authenticated;
grant execute on function app.current_membership() to authenticated;

-- Operator functions: service_role only.
grant execute on function public.admin_create_company(text, text, text, text) to service_role;
grant execute on function public.admin_record_avv(uuid, text)                 to service_role;
grant execute on function public.admin_set_company_active(uuid, boolean)      to service_role;

-- Auth hooks: Supabase Auth only.
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
