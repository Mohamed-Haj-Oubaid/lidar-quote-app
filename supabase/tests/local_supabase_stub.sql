-- =============================================================================
-- LOCAL TESTING ONLY – never run this on the real Supabase project.
-- Minimal stand-in for the roles, auth and storage schemas that Supabase
-- provides, so the migrations can be executed on a plain PostgreSQL.
-- =============================================================================

-- Roles are cluster-wide, so they may survive a dropped test database.
do $$
declare
    r text;
begin
    foreach r in array array['anon', 'authenticated', 'service_role', 'supabase_auth_admin'] loop
        if not exists (select 1 from pg_roles where rolname = r) then
            execute format('create role %I nologin', r);
        end if;
    end loop;
    alter role service_role bypassrls;
end $$;

grant usage on schema public to anon, authenticated, service_role;

-- Supabase grants everything in public to the API roles by default;
-- the migrations must revoke this, so we reproduce it here.
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

create schema auth;
grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;

create table auth.users (
    id         uuid primary key default gen_random_uuid(),
    email      text,
    aud        text,
    role       text,
    created_at timestamptz default now()
);

create function auth.jwt() returns jsonb language sql stable as $$
    select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

create function auth.uid() returns uuid language sql stable as $$
    select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create schema storage;
grant usage on schema storage to anon, authenticated, service_role;

create table storage.buckets (
    id                 text primary key,
    name               text not null,
    public             boolean default false,
    file_size_limit    bigint,
    allowed_mime_types text[]
);

create table storage.objects (
    id        uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets (id),
    name      text not null,
    owner     uuid
);
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to authenticated;

create function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare
    parts text[] := string_to_array(name, '/');
begin
    return parts[1 : array_length(parts, 1) - 1];
end $$;
