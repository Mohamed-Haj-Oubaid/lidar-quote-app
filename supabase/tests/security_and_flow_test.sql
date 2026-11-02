-- =============================================================================
-- End-to-end security & flow test.
--
-- Runs everything inside ONE transaction and rolls back at the end, so it
-- leaves no data behind. Safe to run in the Supabase SQL editor of a fresh
-- project after the migrations (takes ~20 s because of the 15 s sync settle
-- window). Every check raises an error on failure; success ends with
-- "ALL CHECKS PASSED".
-- =============================================================================

begin;

create schema test_ctx;
create table test_ctx.kv (k text primary key, v text);
grant usage on schema test_ctx to authenticated, anon;
grant all on test_ctx.kv to authenticated, anon;

create function test_ctx.login(p_uid uuid) returns void language sql as $$
    select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create function test_ctx.get(p_key text) returns text language sql stable as $$
    select v from test_ctx.kv where k = p_key
$$;

create function test_ctx.expect_error(p_sql text, p_fragment text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'EXPECTED ERROR "%" BUT SUCCEEDED: %', p_fragment, p_sql;
exception when others then
    if sqlerrm like 'EXPECTED ERROR%' then
        raise;
    end if;
    if position(lower(p_fragment) in lower(sqlerrm)) = 0 then
        raise exception 'EXPECTED ERROR "%" BUT GOT: % (statement: %)', p_fragment, sqlerrm, p_sql;
    end if;
end $$;

create function test_ctx.items() returns jsonb language sql immutable as $$
    select '[{"id":"6f1c2a52-8d1e-4b7a-9f0e-0c1d2e3f4a5b","code":"MAL-01","name":"Wall painting","basis":"wallArea",
              "unitPriceCents":1250,"defaultWastePercent":0,
              "openingRule":{"mode":"aboveThreshold","thresholdM2":2.5,"addReveals":true,"revealDepthM":0.15}}]'::jsonb
$$;

create function test_ctx.mutation(p_key text, p_kind text, p_payload jsonb) returns jsonb language sql immutable as $$
    select jsonb_build_object('idempotency_key', p_key, 'kind', p_kind, 'payload', p_payload)
$$;

-- -----------------------------------------------------------------------------
-- 1. Operator creates two companies; only invited people can join
-- -----------------------------------------------------------------------------
do $$
declare
    a uuid;
    b uuid;
begin
    a := public.admin_create_company('Malerbetrieb A', 'mala', 'Owner@A.de', 'AVV-2026-1');
    b := public.admin_create_company('Firma B', 'FB', 'owner@b.de');
    insert into test_ctx.kv values ('tenant_a', a), ('tenant_b', b);

    assert public.hook_before_user_created('{"user":{"email":"OWNER@a.de"}}') = '{}'::jsonb, 'invited owner allowed';
    assert public.hook_before_user_created('{"user":{"email":"stranger@x.de"}}') ? 'error', 'stranger blocked';

    insert into auth.users (id, email) values
        ('11111111-1111-1111-1111-111111111111', 'owner@a.de'),
        ('22222222-2222-2222-2222-222222222222', 'owner@b.de'),
        ('33333333-3333-3333-3333-333333333333', 'stranger@x.de');

    assert (select count(*) from public.tenant_members) = 2, 'only invited users became members';
    assert (select role from public.tenant_members where user_id = '11111111-1111-1111-1111-111111111111') = 'owner', 'owner role';
    assert (select quote_prefix from public.tenants where id = a) = 'MALA', 'prefix upper-cased';
    assert (public.custom_access_token_hook(jsonb_build_object('user_id', '11111111-1111-1111-1111-111111111111', 'claims', '{}'::jsonb))
            -> 'claims' ->> 'tenant_id') = a::text, 'token hook adds tenant claim';
    raise notice 'ok 1: companies, invitation-only sign-up, token hook';
end $$;

-- -----------------------------------------------------------------------------
-- 2. Owner A: price book, invitation, sync push, numbering, idempotency
-- -----------------------------------------------------------------------------
do $$
declare
    v_pbv  uuid;
    r      jsonb;
    v_year text := extract(year from (now() at time zone 'Europe/Berlin'))::text;
    v_calc jsonb := '{"netTotalCents":1000,"grossTotalCents":1190,"lines":[]}';
begin
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;

    v_pbv := public.publish_price_book_version(null, 'Standard', 1900, test_ctx.items());
    insert into test_ctx.kv values ('pbv', v_pbv);
    perform test_ctx.expect_error($q$select public.publish_price_book_version(null, 'Bad', 1900, '[{"id":"x"}]')$q$, 'invalid price items');
    perform test_ctx.expect_error($q$select public.publish_price_book_version(null, 'Bad', 99999, '[]')$q$, 'vat rate');

    perform public.invite_member('Worker@A.de', 'estimator');
    perform test_ctx.expect_error($q$select public.invite_member('x@y.de', 'owner')$q$, 'transfer_ownership');

    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('b0000000-0000-0000-0000-000000000001', 'upsert_job', jsonb_build_object(
            'id', 'a0000000-0000-0000-0000-000000000001', 'title', 'Bad Müller', 'client_name', 'Frau Müller',
            'client_email', 'm@example.de', 'updated_at', now())),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000002', 'upsert_survey', jsonb_build_object(
            'id', 'a0000000-0000-0000-0000-000000000002', 'job_id', 'a0000000-0000-0000-0000-000000000001',
            'room_name', 'Bad', 'measurement', '{"walls":[]}'::jsonb,
            'selections', '[{"itemID":"6f1c2a52-8d1e-4b7a-9f0e-0c1d2e3f4a5b","wastePercent":10}]'::jsonb,
            'captured_at', now(), 'updated_at', now(), 'has_media', false)),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000003', 'issue_quote', jsonb_build_object(
            'id', 'a0000000-0000-0000-0000-000000000003', 'job_id', 'a0000000-0000-0000-0000-000000000001',
            'kind', 'preliminary', 'revision', 1, 'provisional_number', 'OFFLINE-TEMP-ABCD-0001',
            'issued_at', now(), 'price_book_version_id', v_pbv, 'engine_version', '1.0.0',
            'calculation', v_calc, 'snapshot_sha256', repeat('a', 64), 'net_total_cents', 1000, 'gross_total_cents', 1190)),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000004', 'drop_tables', '{}'::jsonb),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000005', 'issue_quote', jsonb_build_object(
            'id', 'a0000000-0000-0000-0000-000000000009', 'job_id', 'a0000000-0000-0000-0000-000000000001',
            'revision', 9, 'provisional_number', 'X', 'issued_at', now(), 'price_book_version_id', v_pbv,
            'engine_version', '1.0.0', 'calculation', v_calc, 'snapshot_sha256', repeat('a', 64),
            'net_total_cents', 1, 'gross_total_cents', 1))
    ));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    assert r -> 1 ->> 'status' = 'applied', r::text;
    assert r -> 2 ->> 'final_number' = 'MALA-' || v_year || '-00001', r::text;
    assert r -> 3 ->> 'status' = 'rejected' and r -> 3 ->> 'error' like 'unknown mutation kind%', r::text;
    assert r -> 4 ->> 'status' = 'rejected' and r -> 4 ->> 'error' like 'totals do not match%', r::text;

    -- Replay after a lost connection returns the same official number.
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('b0000000-0000-0000-0000-000000000003', 'issue_quote', '{}'::jsonb)));
    assert r -> 0 ->> 'status' = 'duplicate' and r -> 0 ->> 'final_number' = 'MALA-' || v_year || '-00001', r::text;

    -- Office issues the final quote superseding the on-site preliminary one (no number gap after the rejected item).
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('b0000000-0000-0000-0000-000000000006', 'issue_quote', jsonb_build_object(
            'id', 'a0000000-0000-0000-0000-000000000004', 'job_id', 'a0000000-0000-0000-0000-000000000001',
            'kind', 'final', 'revision', 2, 'supersedes_quote_id', 'a0000000-0000-0000-0000-000000000003',
            'provisional_number', 'OFFLINE-TEMP-ABCD-0002', 'issued_at', now(), 'price_book_version_id', v_pbv,
            'engine_version', '1.0.0', 'calculation', v_calc, 'snapshot_sha256', repeat('b', 64),
            'net_total_cents', 1000, 'gross_total_cents', 1190))));
    assert r -> 0 ->> 'final_number' = 'MALA-' || v_year || '-00002', r::text;

    -- Lifecycle: the superseded preliminary quote cannot be sent any more.
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('b0000000-0000-0000-0000-000000000007', 'set_quote_status',
            '{"quote_id":"a0000000-0000-0000-0000-000000000004","status":"sent"}'::jsonb),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000008', 'set_quote_status',
            '{"quote_id":"a0000000-0000-0000-0000-000000000003","status":"sent"}'::jsonb)));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    assert r -> 1 ->> 'status' = 'rejected', r::text;

    -- No direct table access through the API.
    perform test_ctx.expect_error('select count(*) from public.jobs', 'permission denied');
    perform test_ctx.expect_error('select count(*) from public.tenant_members', 'permission denied');
    perform test_ctx.expect_error($q$insert into public.quotes (id) values (gen_random_uuid())$q$, 'permission denied');
    perform test_ctx.expect_error($q$select nextval('public.sync_seq')$q$, 'permission denied');
    reset role;

    assert (select status from public.quotes where id = 'a0000000-0000-0000-0000-000000000003') = 'superseded', 'preliminary superseded';
    perform test_ctx.expect_error($q$update public.quotes set net_total_cents = 1 where id = 'a0000000-0000-0000-0000-000000000003'$q$, 'immutable');
    perform test_ctx.expect_error($q$delete from public.quotes where id = 'a0000000-0000-0000-0000-000000000004'$q$, 'cannot be deleted');
    perform test_ctx.expect_error($q$update public.price_book_versions set items = '[]'$q$, 'immutable');
    raise notice 'ok 2: price book, push, official numbering, idempotency, lifecycle, immutability, no table access';
end $$;

-- -----------------------------------------------------------------------------
-- 3. Anonymous callers and non-members get nothing
-- -----------------------------------------------------------------------------
do $$
begin
    perform test_ctx.login('33333333-3333-3333-3333-333333333333');
    set local role authenticated;
    perform test_ctx.expect_error($q$select public.push_mutations('[]')$q$, 'no active company membership');
    perform test_ctx.expect_error($q$select public.pull_changes(0)$q$, 'no active company membership');
    reset role;

    perform set_config('request.jwt.claims', '', true);
    set local role anon;
    perform test_ctx.expect_error($q$select public.push_mutations('[]')$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.pull_changes(0)$q$, 'permission denied');
    perform test_ctx.expect_error($q$select * from public.tenants$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.admin_create_company('x', 'X', 'x@x.de')$q$, 'permission denied');
    reset role;

    -- Logged-in users cannot reach operator functions, hooks or internal handlers.
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;
    perform test_ctx.expect_error($q$select public.admin_create_company('x', 'X', 'x@x.de')$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.admin_record_avv(gen_random_uuid(), 'x')$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.custom_access_token_hook('{}')$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.hook_before_user_created('{}')$q$, 'permission denied');
    perform test_ctx.expect_error($q$select app.m_set_quote_status(null, null, '{}')$q$, 'permission denied');
    reset role;
    raise notice 'ok 3: anon and non-members blocked; operator functions and hooks unreachable';
end $$;

-- -----------------------------------------------------------------------------
-- 4. Company B: AVV gate and tenant isolation
-- -----------------------------------------------------------------------------
do $$
declare
    r jsonb;
begin
    perform test_ctx.login('22222222-2222-2222-2222-222222222222');
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('c0000000-0000-0000-0000-000000000001', 'upsert_job',
        jsonb_build_object('id', 'd0000000-0000-0000-0000-000000000001', 'title', 'B job', 'updated_at', now()))));
    assert r -> 0 ->> 'error' like 'AVV%', r::text;
    reset role;

    perform public.admin_record_avv(test_ctx.get('tenant_b')::uuid, 'AVV-2026-1');

    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('c0000000-0000-0000-0000-000000000002', 'upsert_job',
            jsonb_build_object('id', 'd0000000-0000-0000-0000-000000000001', 'title', 'B job', 'updated_at', now())),
        -- Attacks on company A's data:
        test_ctx.mutation('c0000000-0000-0000-0000-000000000003', 'upsert_job',
            jsonb_build_object('id', 'a0000000-0000-0000-0000-000000000001', 'title', 'hijack', 'updated_at', now() + interval '1 day')),
        test_ctx.mutation('c0000000-0000-0000-0000-000000000004', 'upsert_survey', jsonb_build_object(
            'id', 'd0000000-0000-0000-0000-000000000002', 'job_id', 'a0000000-0000-0000-0000-000000000001',
            'room_name', 'x', 'measurement', '{}'::jsonb, 'captured_at', now(), 'updated_at', now())),
        test_ctx.mutation('c0000000-0000-0000-0000-000000000005', 'set_quote_status',
            '{"quote_id":"a0000000-0000-0000-0000-000000000004","status":"rejected"}'::jsonb),
        test_ctx.mutation('c0000000-0000-0000-0000-000000000006', 'delete_job',
            '{"id":"a0000000-0000-0000-0000-000000000001"}'::jsonb),
        test_ctx.mutation('b0000000-0000-0000-0000-000000000001', 'upsert_job',
            jsonb_build_object('id', 'd0000000-0000-0000-0000-000000000009', 'title', 'reuse A key', 'updated_at', now()))
    ));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    assert r -> 1 ->> 'error' = 'id conflict', r::text;
    assert r -> 2 ->> 'error' = 'unknown job', r::text;
    assert r -> 3 ->> 'error' = 'unknown quote', r::text;
    assert r -> 4 ->> 'error' = 'unknown job', r::text;
    assert r -> 5 ->> 'error' = 'idempotency key conflict', r::text;
    reset role;

    assert (select title from public.jobs where id = 'a0000000-0000-0000-0000-000000000001') = 'Bad Müller', 'A job untouched';
    assert (select status from public.quotes where id = 'a0000000-0000-0000-0000-000000000004') = 'sent', 'A quote untouched';
    raise notice 'ok 4: AVV gate, cross-company writes rejected';
end $$;

-- -----------------------------------------------------------------------------
-- 5. Worker joins company A; office/field sync via pull_changes
-- -----------------------------------------------------------------------------
do $$
begin
    assert public.hook_before_user_created('{"user":{"email":"worker@a.de"}}') = '{}'::jsonb, 'invited worker allowed';
    insert into auth.users (id, email) values ('44444444-4444-4444-4444-444444444444', 'Worker@A.de');
    assert (select role from public.tenant_members where user_id = '44444444-4444-4444-4444-444444444444') = 'estimator', 'worker is estimator';
    raise notice 'ok 5a: worker joined; waiting 16 s for the sync settle window...';
end $$;

select pg_sleep(16);

do $$
declare
    r  jsonb;
    r2 jsonb;
begin
    perform test_ctx.login('44444444-4444-4444-4444-444444444444');
    set local role authenticated;
    r := public.pull_changes(0);
    assert r -> 'tenant' ->> 'name' = 'Malerbetrieb A', r::text;
    assert jsonb_array_length(r -> 'members') = 2, 'members';
    assert jsonb_array_length(r -> 'price_book_versions') = 1, 'price books';
    assert jsonb_array_length(r -> 'jobs') = 1 and r -> 'jobs' -> 0 ->> 'id' = 'a0000000-0000-0000-0000-000000000001', 'only own company jobs';
    assert jsonb_array_length(r -> 'surveys') = 1 and r -> 'surveys' -> 0 -> 'selections' -> 0 ->> 'wastePercent' = '10', 'surveys incl. selections';
    assert jsonb_array_length(r -> 'quotes') = 2, 'quotes';
    assert jsonb_array_length(r -> 'quote_numbers') = 2, 'quote numbers (app compatibility)';
    assert (r ->> 'has_more')::boolean = false, 'single page';

    r2 := public.pull_changes((r ->> 'cursor')::bigint);
    assert jsonb_array_length(r2 -> 'jobs') = 0 and jsonb_typeof(r2 -> 'tenant') = 'null', 'cursor is incremental';

    r2 := public.pull_changes(0, 2);
    assert (r2 ->> 'has_more')::boolean, 'pagination';

    -- Estimator restrictions.
    perform test_ctx.expect_error($q$select public.invite_member('x@y.de')$q$, 'not allowed');
    perform test_ctx.expect_error($q$select public.publish_price_book_version(null, 'x', 1900, test_ctx.items())$q$, 'only owner or admin');
    perform test_ctx.expect_error($q$select public.export_company_data()$q$, 'only the owner');
    perform test_ctx.expect_error($q$select public.erase_client_data('a0000000-0000-0000-0000-000000000001')$q$, 'only owner or admin');
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('e0000000-0000-0000-0000-000000000001', 'delete_job', '{"id":"a0000000-0000-0000-0000-000000000001"}'::jsonb),
        test_ctx.mutation('e0000000-0000-0000-0000-000000000002', 'update_tenant_settings', '{"media_device_only":false}'::jsonb)));
    assert r -> 0 ->> 'error' like 'estimators can only delete their own jobs%', r::text;
    assert r -> 1 ->> 'error' like 'only Owner or Admin%', r::text;
    reset role;

    perform test_ctx.login('22222222-2222-2222-2222-222222222222');
    set local role authenticated;
    r := public.pull_changes(0);
    assert jsonb_array_length(r -> 'jobs') = 1 and r -> 'jobs' -> 0 ->> 'title' = 'B job', 'company B sees only its own job';
    assert jsonb_array_length(r -> 'quotes') = 0 and jsonb_array_length(r -> 'price_book_versions') = 0, 'company B sees no A data';
    reset role;
    raise notice 'ok 5b: pull_changes (office sync), cursor, pagination, estimator permissions, isolation';
end $$;

-- -----------------------------------------------------------------------------
-- 6. Storage: device-only switch and folder isolation
-- -----------------------------------------------------------------------------
do $$
declare
    a   text := test_ctx.get('tenant_a');
    b   text := test_ctx.get('tenant_b');
    job text := 'a0000000-0000-0000-0000-000000000001';
    r   jsonb;
begin
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;
    perform test_ctx.expect_error(format($q$insert into storage.objects (bucket_id, name) values ('survey-media', '%s/%s/m.usdz')$q$, a, job), 'row-level security');

    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('b0000000-0000-0000-0000-000000000020',
        'update_tenant_settings', '{"media_device_only":false}'::jsonb)));
    assert r -> 0 ->> 'status' = 'applied', r::text;

    insert into storage.objects (bucket_id, name) values ('survey-media', a || '/' || job || '/m.usdz');
    perform test_ctx.expect_error(format($q$insert into storage.objects (bucket_id, name) values ('survey-media', '%s/%s/x.usdz')$q$, b, job), 'row-level security');
    perform test_ctx.expect_error(format($q$insert into storage.objects (bucket_id, name) values ('survey-media', '%s/%s/x.usdz')$q$, a, gen_random_uuid()), 'row-level security');
    perform test_ctx.expect_error(format($q$insert into storage.objects (bucket_id, name) values ('survey-media', '%s/x.usdz')$q$, a), 'row-level security');
    assert (select count(*) from storage.objects) = 1, 'owner sees own file';
    reset role;

    perform test_ctx.login('22222222-2222-2222-2222-222222222222');
    set local role authenticated;
    assert (select count(*) from storage.objects) = 0, 'company B cannot see A files';
    reset role;
    raise notice 'ok 6: storage device-only switch and folder isolation';
end $$;

-- -----------------------------------------------------------------------------
-- 7. GDPR erasure; stale devices cannot re-upload erased data
-- -----------------------------------------------------------------------------
do $$
declare
    r jsonb;
begin
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;
    r := public.erase_client_data('a0000000-0000-0000-0000-000000000001');
    assert r ->> 'media_folder' like '%/a0000000-0000-0000-0000-000000000001', r::text;
    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('b0000000-0000-0000-0000-000000000030', 'upsert_job',
        jsonb_build_object('id', 'a0000000-0000-0000-0000-000000000001', 'title', 'Bad Müller',
                           'client_name', 'Frau Müller', 'updated_at', now() + interval '1 minute'))));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    r := public.export_company_data();
    assert jsonb_array_length(r -> 'quotes') = 2, 'export contains quotes';
    reset role;
    assert (select client_name from public.jobs where id = 'a0000000-0000-0000-0000-000000000001') is null, 'erased data stays erased';
    raise notice 'ok 7: erasure is permanent; export works';
end $$;

-- -----------------------------------------------------------------------------
-- 8. Removing a member / suspending a company takes effect immediately
-- -----------------------------------------------------------------------------
do $$
begin
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;
    perform public.remove_member('44444444-4444-4444-4444-444444444444');
    reset role;

    perform test_ctx.login('44444444-4444-4444-4444-444444444444');
    set local role authenticated;
    perform test_ctx.expect_error($q$select public.pull_changes(0)$q$, 'no active company membership');
    reset role;

    perform public.admin_set_company_active(test_ctx.get('tenant_a')::uuid, false);
    perform test_ctx.login('11111111-1111-1111-1111-111111111111');
    set local role authenticated;
    perform test_ctx.expect_error($q$select public.pull_changes(0)$q$, 'no active company membership');
    reset role;
    assert (public.custom_access_token_hook(jsonb_build_object('user_id', '11111111-1111-1111-1111-111111111111', 'claims', '{}'::jsonb))
            -> 'claims' ->> 'tenant_id') is null, 'suspended company: no tenant claim';
    raise notice 'ok 8: removal and suspension are immediate';
end $$;

-- -----------------------------------------------------------------------------
-- 9. Rate limiting
-- -----------------------------------------------------------------------------
do $$
declare
    v_err text;
begin
    perform test_ctx.login('22222222-2222-2222-2222-222222222222');
    set local role authenticated;
    for i in 1..70 loop
        begin
            perform public.push_mutations('[]');
        exception when others then
            v_err := sqlerrm;
            exit;
        end;
    end loop;
    reset role;
    assert v_err like 'rate limit exceeded%', coalesce(v_err, 'no error after 70 calls');
    raise notice 'ok 9: rate limit enforced';
end $$;

do $$ begin raise notice 'ALL CHECKS PASSED'; end $$;

rollback;
