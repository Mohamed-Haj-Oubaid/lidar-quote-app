-- =============================================================================
-- 07 · Fixes from the code review (runs on top of 01–06; never edit those)
--
-- Every section names the review item it fixes. All objects are created with
-- "create or replace" / "if not exists" so the file can be applied to a live
-- project that already has 01–06.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C1 · Never invent consent / signing timestamps
--
-- app.client_ts() falls back to now() when the client omits a value. That is
-- right for NOT NULL columns (updated_at, captured_at, issued_at) but wrong for
-- facts the client must assert: "privacy notice shown" and "client signed".
-- The app omits the key when the value is nil, so every job used to be stamped
-- as "client informed" (GDPR Art. 13) and every accepted quote got a made-up
-- signing time.
--
-- Existing rows CANNOT be repaired automatically: the server never stored
-- whether the timestamp came from the device or from now(). Operators should
-- review suspicious rows with public.admin_list_suspect_privacy_stamps()
-- (stamp within 1 s of the row's creation) and clear them after checking with
-- the company, e.g.
--   update public.jobs set privacy_notice_confirmed_at = null where id = '<job id>';
-- -----------------------------------------------------------------------------

-- NULL stays NULL; otherwise the client value, capped at "now + 5 min".
create or replace function app.client_ts_nullable(p_value text) returns timestamptz
language sql stable set search_path = '' as $$
    select case when p_value is null then null
                else least(p_value::timestamptz, now() + interval '5 minutes') end
$$;

create or replace function app.m_upsert_job(t public.tenants, v_user uuid, p jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
    v_job public.jobs;
    v_id uuid := (p ->> 'id')::uuid;
    v_updated timestamptz := app.client_ts(p ->> 'updated_at');
    v_privacy timestamptz := app.client_ts_nullable(p ->> 'privacy_notice_confirmed_at');
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
                p ->> 'site_address', v_privacy, v_user, v_user, v_updated);
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
        -- First confirmed value wins; a payload without the key never overwrites or invents it.
        privacy_notice_confirmed_at = coalesce(privacy_notice_confirmed_at, v_privacy),
        updated_at = v_updated,
        updated_by = v_user
    where id = v_id;
    return '{}'::jsonb;
end $$;

create or replace function app.m_set_quote_status(t public.tenants, v_user uuid, p jsonb) returns jsonb
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
        -- Only store a signing time the client actually sent.
        client_signed_at = case when v_status = 'accepted'
                                then app.client_ts_nullable(p ->> 'client_signed_at')
                                else client_signed_at end
    where id = v_quote.id;

    perform app.audit(t.id, 'quote.status_changed', v_quote.id, jsonb_build_object('status', v_status));
    return '{}'::jsonb;
end $$;

-- Operator review list for rows that may carry an invented privacy timestamp.
create or replace function public.admin_list_suspect_privacy_stamps()
returns table (tenant_id uuid, tenant_name text, job_id uuid, title text,
               created_at timestamptz, privacy_notice_confirmed_at timestamptz)
language sql stable security definer set search_path = '' as $$
    select j.tenant_id, t.name, j.id, j.title, j.created_at, j.privacy_notice_confirmed_at
    from public.jobs j
    join public.tenants t on t.id = j.tenant_id
    where j.privacy_notice_confirmed_at is not null
      and abs(extract(epoch from (j.privacy_notice_confirmed_at - j.created_at))) <= 1
    order by j.tenant_id, j.created_at
$$;

-- -----------------------------------------------------------------------------
-- C2 · Users and whole companies must be deletable (GDPR / AVV contract end)
--
-- Deleting an auth.users row makes Postgres run "set issued_by = null" on that
-- user's quotes (FK on delete set null), which the append-only guard rejected.
-- Deleting a tenant cascaded into quotes, which the guard also rejected.
--
--   * issued_by / published_by may change ONLY from a value to NULL.
--   * DELETE is allowed only inside public.admin_delete_company(), which sets
--     the transaction-local flag app.purge_tenant to the tenant being purged.
--     API roles have no DELETE privilege and no RPC deletes quotes, so the
--     flag cannot be abused from the app.
-- -----------------------------------------------------------------------------

create or replace function app.guard_quote() returns trigger
language plpgsql set search_path = '' as $$
declare
    -- status_changed_by stays mutable: set_quote_status records who changed the status.
    mutable constant text[] := array['status', 'status_changed_at', 'status_changed_by', 'client_signed_at',
                                     'row_seq', 'changed_at', 'issued_by'];
begin
    if tg_op = 'DELETE' then
        if current_setting('app.purge_tenant', true) = old.tenant_id::text then
            return old;
        end if;
        raise exception 'issued quotes cannot be deleted';
    end if;
    if (to_jsonb(new) - mutable) is distinct from (to_jsonb(old) - mutable) then
        raise exception 'issued quotes are immutable; issue a new revision';
    end if;
    -- The FK "on delete set null" case is the only allowed change of issued_by.
    if new.issued_by is distinct from old.issued_by and new.issued_by is not null then
        raise exception 'issued quotes are immutable; issued_by can only be cleared';
    end if;
    return new;
end $$;

create or replace function app.guard_price_book_version() returns trigger
language plpgsql set search_path = '' as $$
declare
    mutable constant text[] := array['is_active', 'row_seq', 'changed_at', 'published_by'];
begin
    if tg_op = 'DELETE' then
        if current_setting('app.purge_tenant', true) = old.tenant_id::text then
            return old;
        end if;
        raise exception 'published price-book versions cannot be deleted';
    end if;
    if (to_jsonb(new) - mutable) is distinct from (to_jsonb(old) - mutable) then
        raise exception 'published price-book versions are immutable; publish a new version';
    end if;
    if new.published_by is distinct from old.published_by and new.published_by is not null then
        raise exception 'published price-book versions are immutable; published_by can only be cleared';
    end if;
    return new;
end $$;

drop trigger if exists price_book_versions_immutable on public.price_book_versions;
create trigger price_book_versions_immutable before update or delete on public.price_book_versions
    for each row execute function app.guard_price_book_version();

-- Operator: erase a company completely at contract end (AVV, Art. 28 GDPR).
-- Deletes the members' accounts, all quotes (normally append-only) and the
-- tenant row – everything else cascades. Returns the storage prefix whose
-- objects the operator must then delete through the Storage API / dashboard
-- (storage objects must never be deleted with SQL).
create or replace function public.admin_delete_company(p_tenant_id uuid, p_confirm_name text) returns text
language plpgsql security definer set search_path = '' as $$
declare
    v_name  text;
    v_users integer;
begin
    select name into v_name from public.tenants where id = p_tenant_id for update;
    if v_name is null then
        raise exception 'unknown company' using errcode = '22023';
    end if;
    if p_confirm_name is distinct from v_name then
        raise exception 'confirmation name does not match the company name' using errcode = '22023';
    end if;

    perform set_config('app.purge_tenant', p_tenant_id::text, true);

    -- Accounts of the company's members (memberships cascade; FKs elsewhere set null).
    delete from auth.users where id in (select user_id from public.tenant_members where tenant_id = p_tenant_id);
    get diagnostics v_users = row_count;

    delete from public.quotes where tenant_id = p_tenant_id;
    delete from public.tenants where id = p_tenant_id;

    perform set_config('app.purge_tenant', '', true);

    -- The tenant's own audit rows are gone with it; keep a tenant-less record.
    insert into public.audit_log (tenant_id, action, entity_id, details)
    values (null, 'company.deleted', p_tenant_id,
            jsonb_build_object('deleted_tenant', p_tenant_id, 'name', v_name, 'deleted_users', v_users));

    return p_tenant_id::text || '/';
end $$;

-- -----------------------------------------------------------------------------
-- C5 · Tell the app whether a rejection is permanent
--
-- Business-rule violations in the m_* handlers are raised with RAISE EXCEPTION
-- and therefore carry SQLSTATE P0001 (AVV missing, unknown job, unknown price
-- book, id conflict, totals mismatch …): retrying never helps. Lock / serialisation
-- conflicts and resource limits are transient. Every rejected result now has
--   { "sqlstate": "<code>", "retryable": <bool> }
-- so the app can block permanent failures instead of resending them forever.
-- A short lock_timeout turns lock contention into a retryable 55P03 instead of
-- a hanging request.
-- -----------------------------------------------------------------------------

create or replace function app.is_retryable_sqlstate(p_state text) returns boolean
language sql immutable set search_path = '' as $$
    select p_state in ('40001', '40P01', '55P03', '57014', 'PT429')
        or p_state like '53%'   -- insufficient resources
        or p_state like '08%'   -- connection exceptions
$$;

create or replace function public.push_mutations(p_batch jsonb) returns jsonb
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
    perform set_config('lock_timeout', '5s', true);

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
                                           'status', 'rejected', 'error', sqlerrm,
                                           'sqlstate', sqlstate,
                                           'retryable', app.is_retryable_sqlstate(sqlstate));
        end;
        v_results := v_results || jsonb_build_array(v_result);
    end loop;

    return v_results;
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

-- Auth hooks: Supabase Auth only.
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
