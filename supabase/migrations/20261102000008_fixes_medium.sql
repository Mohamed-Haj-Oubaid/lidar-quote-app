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
