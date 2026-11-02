-- =============================================================================
-- 02 · Authentication & membership
--
--   * Invitation-only sign-up: the "Before User Created" auth hook rejects any
--     e-mail address without an open invitation, so strangers cannot create
--     accounts even though they can reach the Auth API.
--   * On account creation the invitation is turned into a membership.
--   * Membership/role are ALWAYS read live from tenant_members, so removing a
--     worker takes effect immediately (not only when the JWT expires).
--   * The access-token hook adds tenant_id/user_role claims for UI display only.
-- =============================================================================

-- Current user's active membership (empty if none or company suspended).
create function app.current_membership()
returns table (tenant_id uuid, role public.member_role)
language sql stable security definer set search_path = '' as $$
    select m.tenant_id, m.role
    from public.tenant_members m
    join public.tenants t on t.id = m.tenant_id
    where m.user_id = auth.uid() and t.is_active
$$;

create function app.tenant_id() returns uuid
language sql stable security definer set search_path = '' as $$
    select tenant_id from app.current_membership()
$$;

create function app.user_role() returns public.member_role
language sql stable security definer set search_path = '' as $$
    select role from app.current_membership()
$$;

create function app.audit(p_tenant uuid, p_action text, p_entity uuid, p_details jsonb default null)
returns void
language sql security definer set search_path = '' as $$
    insert into public.audit_log (tenant_id, actor, action, entity_id, details)
    values (p_tenant, auth.uid(), p_action, p_entity, p_details)
$$;

-- -----------------------------------------------------------------------------
-- Auth hook: Before User Created (Dashboard → Authentication → Hooks)
-- -----------------------------------------------------------------------------

create function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
    v_email text := lower(coalesce(event -> 'user' ->> 'email', ''));
begin
    if exists (
        select 1 from public.tenant_invitations i
        join public.tenants t on t.id = i.tenant_id
        where i.email = v_email and i.accepted_at is null and i.expires_at > now() and t.is_active
    ) then
        return '{}'::jsonb;
    end if;
    return jsonb_build_object('error', jsonb_build_object(
        'http_code', 403,
        'message', 'This e-mail address has not been invited.'));
end $$;

-- -----------------------------------------------------------------------------
-- Auth hook: Custom Access Token (Dashboard → Authentication → Hooks)
-- -----------------------------------------------------------------------------

create function public.custom_access_token_hook(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
    claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
    member record;
begin
    select m.tenant_id, m.role into member
    from public.tenant_members m
    join public.tenants t on t.id = m.tenant_id
    where m.user_id = (event ->> 'user_id')::uuid and t.is_active;

    if found then
        claims := jsonb_set(claims, '{tenant_id}', to_jsonb(member.tenant_id));
        claims := jsonb_set(claims, '{user_role}', to_jsonb(member.role));
    else
        claims := claims - 'tenant_id' - 'user_role';
    end if;
    return jsonb_set(event, '{claims}', claims);
end $$;

-- Hooks may only be executed by Supabase Auth itself.
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- -----------------------------------------------------------------------------
-- New account → membership (from the open invitation)
-- -----------------------------------------------------------------------------

create function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
    inv public.tenant_invitations;
begin
    select i.* into inv
    from public.tenant_invitations i
    where i.email = lower(new.email) and i.accepted_at is null and i.expires_at > now()
    order by i.created_at desc
    limit 1;

    if found then
        insert into public.tenant_members (user_id, tenant_id, role, email)
        values (new.id, inv.tenant_id, inv.role, lower(new.email))
        on conflict (user_id) do nothing;

        update public.tenant_invitations
        set accepted_at = now(), accepted_by = new.id
        where id = inv.id;

        insert into public.audit_log (tenant_id, actor, action, entity_id, details)
        values (inv.tenant_id, new.id, 'member.joined', new.id, jsonb_build_object('role', inv.role));
    end if;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function app.handle_new_user();
