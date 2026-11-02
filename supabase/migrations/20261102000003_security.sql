-- =============================================================================
-- 03 · Security hardening
--
-- The app's API key (publishable / anon) is PUBLIC by design – it ships inside
-- the app and can be extracted. Security therefore never depends on hiding it:
--
--   1. anon (no login)  → can do nothing at all in the database.
--   2. authenticated    → no direct table access; only whitelisted RPC
--                          functions, which check membership + role and are
--                          rate-limited.
--   3. RLS is enabled on every table as defence in depth (deny by default).
--   4. Future tables/functions are closed by default.
--   5. The GraphQL endpoint (unused) is removed.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- RLS everywhere (no policies = no rows for API roles)
-- -----------------------------------------------------------------------------

alter table public.tenants             enable row level security;
alter table public.tenant_members      enable row level security;
alter table public.tenant_invitations  enable row level security;
alter table public.price_books         enable row level security;
alter table public.price_book_versions enable row level security;
alter table public.jobs                enable row level security;
alter table public.surveys             enable row level security;
alter table public.quotes              enable row level security;
alter table public.quote_counters      enable row level security;
alter table public.processed_mutations enable row level security;
alter table public.audit_log           enable row level security;
alter table public.rate_limits         enable row level security;

-- -----------------------------------------------------------------------------
-- No direct table, sequence or function access for API roles
-- -----------------------------------------------------------------------------

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app    from public, anon, authenticated;

-- Objects created later are closed by default as well.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app    revoke execute on functions from public, anon, authenticated;

-- Helpers used inside storage policies must be callable by logged-in users.
grant usage on schema app to authenticated;
grant execute on function app.tenant_id() to authenticated;
grant execute on function app.user_role() to authenticated;
grant execute on function app.current_membership() to authenticated;

-- Hooks stay executable by Supabase Auth only (re-grant after the blanket revoke).
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- -----------------------------------------------------------------------------
-- Remove unused API surface
-- -----------------------------------------------------------------------------

-- The app does not use GraphQL; dropping the extension disables /graphql/v1.
-- If the project does not allow this from SQL, disable it in
-- Dashboard → Database → Extensions → pg_graphql instead.
do $$
begin
    drop extension if exists pg_graphql;
exception when insufficient_privilege or dependent_objects_still_exist then
    raise notice 'Could not drop pg_graphql here – disable it in Dashboard → Database → Extensions.';
end $$;
