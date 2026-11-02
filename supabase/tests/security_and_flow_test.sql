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

-- A calculation that adds up against test_ctx.items() at 19 % VAT (10 m² × 12.50 €),
-- in the engine-1.0.0 shape (lines matched by item code).
create function test_ctx.calc() returns jsonb language sql immutable as $$
    select '{"netTotalCents":12500,"vatRateBasisPoints":1900,"vatCents":2375,"grossTotalCents":14875,
             "lines":[{"roomName":"Bad","itemCode":"MAL-01","billedQuantityHundredths":1000,
                       "unitPriceCents":1250,"totalCents":12500}]}'::jsonb
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
    v_calc jsonb := test_ctx.calc();
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
            'calculation', v_calc, 'snapshot_sha256', repeat('a', 64), 'net_total_cents', 12500, 'gross_total_cents', 14875)),
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
            'net_total_cents', 12500, 'gross_total_cents', 14875))));
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

-- =============================================================================
-- Review fixes (migration 07+). Company C (owner 5555…) is fresh, so these
-- checks are independent of the suspended company A and the rate-limited B.
-- =============================================================================
do $$
declare
    c uuid;
begin
    c := public.admin_create_company('Firma C', 'FC', 'owner@c.de', 'AVV-2026-1');
    insert into test_ctx.kv values ('tenant_c', c);
    insert into auth.users (id, email) values ('55555555-5555-5555-5555-555555555555', 'owner@c.de');
    assert (select role from public.tenant_members where user_id = '55555555-5555-5555-5555-555555555555') = 'owner', 'owner C';
end $$;

-- -----------------------------------------------------------------------------
-- C1. Privacy / signing timestamps are never invented
-- -----------------------------------------------------------------------------
do $$
declare
    r       jsonb;
    v_stamp timestamptz := date_trunc('second', now() - interval '1 hour');
    v_pbv   uuid;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;

    -- 1) insert without the key → NULL (not now()).
    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('c1000000-0000-0000-0000-000000000001', 'upsert_job',
        jsonb_build_object('id', 'c1a00000-0000-0000-0000-000000000001', 'title', 'C job', 'updated_at', now() - interval '3 seconds'))));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    reset role;
    assert (select privacy_notice_confirmed_at from public.jobs where id = 'c1a00000-0000-0000-0000-000000000001') is null,
        'C1: missing key must store NULL';
    assert not exists (select 1 from public.admin_list_suspect_privacy_stamps() where job_id = 'c1a00000-0000-0000-0000-000000000001'),
        'C1: NULL stamp is not suspicious';

    -- 2) update with the key → exactly that timestamp.
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('c1000000-0000-0000-0000-000000000002', 'upsert_job',
        jsonb_build_object('id', 'c1a00000-0000-0000-0000-000000000001', 'title', 'C job',
                           'privacy_notice_confirmed_at', v_stamp, 'updated_at', now() - interval '2 seconds'))));
    assert r -> 0 ->> 'status' = 'applied', r::text;
    reset role;
    assert (select privacy_notice_confirmed_at from public.jobs where id = 'c1a00000-0000-0000-0000-000000000001') = v_stamp,
        'C1: explicit timestamp stored verbatim';

    -- 3) later update without the key → unchanged.
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(test_ctx.mutation('c1000000-0000-0000-0000-000000000003', 'upsert_job',
        jsonb_build_object('id', 'c1a00000-0000-0000-0000-000000000001', 'title', 'C job renamed', 'updated_at', now() - interval '1 second'))));
    assert r -> 0 ->> 'status' = 'applied', r::text;

    -- Accepting a quote without client_signed_at stores NULL.
    v_pbv := public.publish_price_book_version(null, 'Standard C', 1900, test_ctx.items());
    insert into test_ctx.kv values ('pbv_c', v_pbv);
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('c1000000-0000-0000-0000-000000000004', 'issue_quote', jsonb_build_object(
            'id', 'c1b00000-0000-0000-0000-000000000001', 'job_id', 'c1a00000-0000-0000-0000-000000000001',
            'revision', 1, 'provisional_number', 'OFFLINE-TEMP-C-0001', 'issued_at', now(), 'price_book_version_id', v_pbv,
            'engine_version', '1.0.0', 'calculation', test_ctx.calc(),
            'snapshot_sha256', repeat('c', 64), 'net_total_cents', 12500, 'gross_total_cents', 14875)),
        test_ctx.mutation('c1000000-0000-0000-0000-000000000005', 'set_quote_status',
            '{"quote_id":"c1b00000-0000-0000-0000-000000000001","status":"accepted"}'::jsonb)));
    assert r -> 0 ->> 'status' = 'applied' and r -> 1 ->> 'status' = 'applied', r::text;
    reset role;

    assert (select privacy_notice_confirmed_at from public.jobs where id = 'c1a00000-0000-0000-0000-000000000001') = v_stamp,
        'C1: payload without the key never overwrites the stamp';
    assert (select client_signed_at from public.quotes where id = 'c1b00000-0000-0000-0000-000000000001') is null,
        'C1: no invented signing time';
    raise notice 'ok C1: privacy and signing timestamps are only stored when sent';
end $$;

-- -----------------------------------------------------------------------------
-- C2. Deleting users and whole companies
-- -----------------------------------------------------------------------------
do $$
declare
    d      uuid;
    r      jsonb;
    v_pbv  uuid;
    v_pref text;
    v_left bigint;
begin
    d := public.admin_create_company('Firma D', 'FD', 'owner@d.de', 'AVV-2026-1');
    insert into test_ctx.kv values ('tenant_d', d);
    insert into auth.users (id, email) values ('66666666-6666-6666-6666-666666666666', 'owner@d.de');

    perform test_ctx.login('66666666-6666-6666-6666-666666666666');
    set local role authenticated;
    v_pbv := public.publish_price_book_version(null, 'Standard D', 1900, test_ctx.items());
    perform public.invite_member('worker@d.de', 'estimator');
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('c2000000-0000-0000-0000-000000000001', 'upsert_job',
            jsonb_build_object('id', 'c2a00000-0000-0000-0000-000000000001', 'title', 'D job', 'updated_at', now())),
        test_ctx.mutation('c2000000-0000-0000-0000-000000000002', 'issue_quote', jsonb_build_object(
            'id', 'c2b00000-0000-0000-0000-000000000001', 'job_id', 'c2a00000-0000-0000-0000-000000000001',
            'revision', 1, 'provisional_number', 'OFFLINE-TEMP-D-0001', 'issued_at', now(), 'price_book_version_id', v_pbv,
            'engine_version', '1.0.0', 'calculation', test_ctx.calc(),
            'snapshot_sha256', repeat('d', 64), 'net_total_cents', 12500, 'gross_total_cents', 14875))));
    assert r -> 1 ->> 'status' = 'applied', r::text;
    reset role;
    insert into auth.users (id, email) values ('77777777-7777-7777-7777-777777777777', 'worker@d.de');

    -- issued_by may only be cleared, never reassigned.
    perform test_ctx.expect_error($q$update public.quotes set issued_by = '77777777-7777-7777-7777-777777777777'
                                     where id = 'c2b00000-0000-0000-0000-000000000001'$q$, 'immutable');
    perform test_ctx.expect_error($q$update public.price_book_versions set published_by = '77777777-7777-7777-7777-777777777777'
                                     where tenant_id = '$q$ || d || $q$'$q$, 'immutable');

    -- Deleting the account that issued the quote and published the price book succeeds.
    delete from auth.users where id = '66666666-6666-6666-6666-666666666666';
    assert (select issued_by from public.quotes where id = 'c2b00000-0000-0000-0000-000000000001') is null, 'C2: issued_by cleared';
    assert (select published_by from public.price_book_versions where id = v_pbv) is null, 'C2: published_by cleared';

    -- Plain deletes are still refused.
    perform test_ctx.expect_error($q$delete from public.quotes where id = 'c2b00000-0000-0000-0000-000000000001'$q$, 'cannot be deleted');
    perform test_ctx.expect_error(format($q$delete from public.price_book_versions where id = '%s'$q$, v_pbv), 'cannot be deleted');

    -- App users cannot reach the operator purge.
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    perform test_ctx.expect_error(format($q$select public.admin_delete_company('%s', 'Firma D')$q$, d), 'permission denied');
    reset role;

    perform test_ctx.expect_error(format($q$select public.admin_delete_company('%s', 'firma d')$q$, d), 'does not match');

    v_pref := public.admin_delete_company(d, 'Firma D');
    assert v_pref = d::text || '/', v_pref;
    select (select count(*) from public.tenants where id = d)
         + (select count(*) from public.tenant_members where tenant_id = d)
         + (select count(*) from public.tenant_invitations where tenant_id = d)
         + (select count(*) from public.price_books where tenant_id = d)
         + (select count(*) from public.price_book_versions where tenant_id = d)
         + (select count(*) from public.jobs where tenant_id = d)
         + (select count(*) from public.surveys where tenant_id = d)
         + (select count(*) from public.quotes where tenant_id = d)
         + (select count(*) from public.quote_counters where tenant_id = d)
         + (select count(*) from public.processed_mutations where tenant_id = d)
         + (select count(*) from public.audit_log where tenant_id = d)
      into v_left;
    assert v_left = 0, 'C2: rows of the purged company remain: ' || v_left;
    assert not exists (select 1 from auth.users where id = '77777777-7777-7777-7777-777777777777'), 'C2: member accounts deleted';
    assert exists (select 1 from public.audit_log where tenant_id is null and action = 'company.deleted'
                   and details ->> 'name' = 'Firma D'), 'C2: tenant-less audit record';
    assert coalesce(current_setting('app.purge_tenant', true), '') = '', 'C2: purge flag reset';
    -- Company C is untouched.
    assert exists (select 1 from public.quotes where id = 'c1b00000-0000-0000-0000-000000000001'), 'C2: other company untouched';
    raise notice 'ok C2: users and companies are deletable; quotes stay immutable otherwise';
end $$;

-- -----------------------------------------------------------------------------
-- C5. Rejections say whether a retry can help
-- -----------------------------------------------------------------------------
do $$
declare
    r jsonb;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(
        -- Quote from the device's local sample price book (unknown to the server).
        test_ctx.mutation('c5000000-0000-0000-0000-000000000001', 'issue_quote', jsonb_build_object(
            'id', 'c5b00000-0000-0000-0000-000000000001', 'job_id', 'c1a00000-0000-0000-0000-000000000001',
            'revision', 2, 'provisional_number', 'OFFLINE-TEMP-C-0002', 'issued_at', now(),
            'price_book_version_id', gen_random_uuid(), 'engine_version', '1.0.0',
            'calculation', test_ctx.calc(),
            'snapshot_sha256', repeat('c', 64), 'net_total_cents', 12500, 'gross_total_cents', 14875)),
        test_ctx.mutation('c5000000-0000-0000-0000-000000000002', 'upsert_survey', jsonb_build_object(
            'id', 'c5c00000-0000-0000-0000-000000000001', 'job_id', gen_random_uuid(),
            'room_name', 'x', 'measurement', '{}'::jsonb, 'captured_at', now(), 'updated_at', now())),
        test_ctx.mutation('c5000000-0000-0000-0000-000000000003', 'upsert_job',
            jsonb_build_object('id', 'not-a-uuid', 'title', 'x', 'updated_at', now()))));
    reset role;

    assert r -> 0 ->> 'status' = 'rejected' and r -> 0 ->> 'error' like 'unknown price-book version%', r::text;
    assert r -> 0 ->> 'sqlstate' = 'P0001' and (r -> 0 -> 'retryable') = 'false'::jsonb, r::text;
    assert r -> 1 ->> 'sqlstate' = 'P0001' and (r -> 1 -> 'retryable') = 'false'::jsonb, r::text;
    assert r -> 2 ? 'sqlstate' and (r -> 2 -> 'retryable') = 'false'::jsonb, r::text;
    assert app.is_retryable_sqlstate('40001') and app.is_retryable_sqlstate('55P03')
       and not app.is_retryable_sqlstate('P0001'), 'C5: classification';
    raise notice 'ok C5: rejected results carry sqlstate and retryable';
end $$;

-- -----------------------------------------------------------------------------
-- H5. Server verifies the hash over the exact bytes and recomputes the totals
-- -----------------------------------------------------------------------------
create function test_ctx.calc_json(p_pbv text, p_unit integer, p_vat_bp integer) returns text language sql immutable as $$
    -- Same shape as the app's canonical JSON (sorted keys, unescaped "/").
    select format('{"engineVersion":"1.1.0","grossTotalCents":%s,"lines":[{"billedQuantityHundredths":1000,'
               || '"itemCode":"MAL-01","itemID":"6F1C2A52-8D1E-4B7A-9F0E-0C1D2E3F4A5B","roomName":"Bad/WC",'
               || '"totalCents":%s,"unitPriceCents":%s}],"netTotalCents":%s,"priceBookVersionID":"%s",'
               || '"vatCents":%s,"vatRateBasisPoints":%s}',
                  10 * p_unit + app.round_div(10 * p_unit * p_vat_bp, 10000), 10 * p_unit, p_unit, 10 * p_unit,
                  upper(p_pbv), app.round_div(10 * p_unit * p_vat_bp, 10000), p_vat_bp)
$$;

create function test_ctx.quote_mutation(p_n integer, p_json text, p_sha text) returns jsonb language sql stable as $$
    select test_ctx.mutation(format('a5000000-0000-0000-0000-%s', lpad(p_n::text, 12, '0')), 'issue_quote', jsonb_build_object(
        'id', format('a5b00000-0000-0000-0000-%s', lpad(p_n::text, 12, '0')),
        'job_id', 'c1a00000-0000-0000-0000-000000000001', 'revision', 10 + p_n,
        'provisional_number', 'OFFLINE-TEMP-H5-' || p_n, 'issued_at', now(),
        'price_book_version_id', test_ctx.get('pbv_c'), 'engine_version', '1.1.0',
        'calculation', p_json::jsonb, 'calculation_json', p_json, 'snapshot_sha256', p_sha,
        'net_total_cents', (p_json::jsonb ->> 'netTotalCents')::bigint,
        'gross_total_cents', (p_json::jsonb ->> 'grossTotalCents')::bigint))
$$;

do $$
declare
    v_pbv      text := test_ctx.get('pbv_c');
    v_good     text := test_ctx.calc_json(v_pbv, 1250, 1900);
    v_tampered text := test_ctx.calc_json(v_pbv, 1000, 1900);
    v_wrongvat text := test_ctx.calc_json(v_pbv, 1250, 700);
    r          jsonb;
    v_raw      text;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(
        test_ctx.quote_mutation(1, v_tampered, encode(extensions.digest(convert_to(v_tampered, 'UTF8'), 'sha256'), 'hex')),
        test_ctx.quote_mutation(2, v_wrongvat, encode(extensions.digest(convert_to(v_wrongvat, 'UTF8'), 'sha256'), 'hex')),
        test_ctx.quote_mutation(3, v_good, repeat('e', 64)),
        test_ctx.quote_mutation(4, v_good, encode(extensions.digest(convert_to(v_good, 'UTF8'), 'sha256'), 'hex'))));
    reset role;

    assert r -> 0 ->> 'status' = 'rejected' and r -> 0 ->> 'error' like '%unit price 1000 does not match%', r::text;
    assert r -> 1 ->> 'status' = 'rejected' and r -> 1 ->> 'error' like 'VAT rate 700 does not match%', r::text;
    assert r -> 2 ->> 'status' = 'rejected' and r -> 2 ->> 'error' like 'snapshot hash does not match%', r::text;
    assert (r -> 0 -> 'retryable') = 'false'::jsonb and r -> 2 ->> 'sqlstate' = 'P0001', r::text;
    assert r -> 3 ->> 'status' = 'applied' and r -> 3 ->> 'final_number' like 'FC-%', r::text;

    select calculation_raw into v_raw from public.quotes where id = 'a5b00000-0000-0000-0000-000000000004';
    assert v_raw = v_good, 'H5: raw bytes stored verbatim';
    assert encode(extensions.digest(convert_to(v_raw, 'UTF8'), 'sha256'), 'hex')
         = (select snapshot_sha256 from public.quotes where id = 'a5b00000-0000-0000-0000-000000000004'), 'H5: stored bytes reproduce the hash';
    assert not exists (select 1 from public.quotes where id in ('a5b00000-0000-0000-0000-000000000001',
        'a5b00000-0000-0000-0000-000000000002', 'a5b00000-0000-0000-0000-000000000003')), 'H5: rejected quotes not stored';
    raise notice 'ok H5: tampered prices, wrong VAT and hash mismatches are rejected; raw calculation stored';
end $$;

-- -----------------------------------------------------------------------------
-- H1. Deleted rooms and jobs reach other devices through pull_changes
-- -----------------------------------------------------------------------------
do $$
declare
    r jsonb;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    r := public.push_mutations(jsonb_build_array(
        test_ctx.mutation('41000000-0000-0000-0000-000000000001', 'upsert_job',
            jsonb_build_object('id', '41a00000-0000-0000-0000-000000000001', 'title', 'To delete', 'updated_at', now())),
        test_ctx.mutation('41000000-0000-0000-0000-000000000002', 'upsert_survey', jsonb_build_object(
            'id', '41c00000-0000-0000-0000-000000000001', 'job_id', '41a00000-0000-0000-0000-000000000001',
            'room_name', 'Flur', 'measurement', '{"walls":[]}'::jsonb, 'captured_at', now(), 'updated_at', now())),
        test_ctx.mutation('41000000-0000-0000-0000-000000000003', 'upsert_survey', jsonb_build_object(
            'id', '41c00000-0000-0000-0000-000000000002', 'job_id', 'c1a00000-0000-0000-0000-000000000001',
            'room_name', 'Küche', 'measurement', '{"walls":[]}'::jsonb, 'captured_at', now(), 'updated_at', now())),
        -- The app sends job_id along with deletes (ignored by the server).
        test_ctx.mutation('41000000-0000-0000-0000-000000000004', 'delete_survey',
            '{"id":"41c00000-0000-0000-0000-000000000002","job_id":"c1a00000-0000-0000-0000-000000000001"}'::jsonb),
        test_ctx.mutation('41000000-0000-0000-0000-000000000005', 'delete_job',
            '{"id":"41a00000-0000-0000-0000-000000000001","job_id":"41a00000-0000-0000-0000-000000000001"}'::jsonb)));
    assert (select bool_and(e ->> 'status' = 'applied') from jsonb_array_elements(r) e), r::text;
    reset role;
    raise notice 'ok H1a: deletes applied; waiting 16 s for the sync settle window...';
end $$;

select pg_sleep(16);

do $$
declare
    r jsonb;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    r := public.pull_changes(0);
    reset role;
    assert (select e ->> 'deleted_at' from jsonb_array_elements(r -> 'surveys') e
            where e ->> 'id' = '41c00000-0000-0000-0000-000000000002') is not null, 'H1: deleted room has deleted_at';
    assert (select e ->> 'deleted_at' from jsonb_array_elements(r -> 'jobs') e
            where e ->> 'id' = '41a00000-0000-0000-0000-000000000001') is not null, 'H1: deleted job has deleted_at';
    assert (select e ->> 'deleted_at' from jsonb_array_elements(r -> 'surveys') e
            where e ->> 'id' = '41c00000-0000-0000-0000-000000000001') is not null, 'H1: rooms of a deleted job are deleted';
    raise notice 'ok H1b: pull_changes returns deleted rooms and jobs with deleted_at';
end $$;

-- -----------------------------------------------------------------------------
-- H8. Media retention candidates (used by the media-retention Edge Function)
-- -----------------------------------------------------------------------------
do $$
declare
    v_old uuid := 'a8a00000-0000-0000-0000-000000000001';
begin
    -- Company A's job was erased in section 7; add an old untouched job of company C.
    insert into public.jobs (id, tenant_id, title, updated_at)
    values (v_old, test_ctx.get('tenant_c')::uuid, 'Old job', now() - interval '25 months');

    assert exists (select 1 from public.admin_media_retention_candidates()
                   where job_id = 'a0000000-0000-0000-0000-000000000001' and reason = 'erased'), 'H8: erased job is a candidate';
    assert exists (select 1 from public.admin_media_retention_candidates()
                   where job_id = v_old and reason = 'retention'
                     and folder = test_ctx.get('tenant_c') || '/' || v_old), 'H8: job past retention is a candidate';
    assert not exists (select 1 from public.admin_media_retention_candidates()
                       where job_id = 'c1a00000-0000-0000-0000-000000000001'), 'H8: recent job is kept';

    perform public.admin_mark_media_purged(v_old, 3);
    assert not exists (select 1 from public.admin_media_retention_candidates() where job_id = v_old), 'H8: purged job not listed again';
    assert exists (select 1 from public.audit_log where action = 'media.purged' and entity_id = v_old), 'H8: purge audited';

    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    perform test_ctx.expect_error($q$select * from public.admin_media_retention_candidates()$q$, 'permission denied');
    perform test_ctx.expect_error($q$select public.admin_mark_media_purged(gen_random_uuid())$q$, 'permission denied');
    reset role;
    raise notice 'ok H8: retention candidates and purge marking (service_role only)';
end $$;

-- -----------------------------------------------------------------------------
-- M1. No address probing; existing accounts join only with consent
-- -----------------------------------------------------------------------------
do $$
declare
    v_id  uuid;
    v_inv jsonb;
begin
    perform test_ctx.login('55555555-5555-5555-5555-555555555555');
    set local role authenticated;
    -- owner@b.de belongs to company B: same answer as success, nothing created.
    v_id := public.invite_member('owner@b.de', 'estimator');
    assert v_id is not null, 'M1: generic success';
    reset role;
    assert not exists (select 1 from public.tenant_invitations where email = 'owner@b.de'
                       and tenant_id = test_ctx.get('tenant_c')::uuid), 'M1: no invitation for a foreign member';
    assert exists (select 1 from public.audit_log where action = 'member.invite_conflict' and entity_id = v_id), 'M1: conflict audited';
    assert (select tenant_id from public.tenant_members where user_id = '22222222-2222-2222-2222-222222222222')
         = test_ctx.get('tenant_b')::uuid, 'M1: foreign member untouched';

    -- worker@a.de has an account (removed from A in section 8): invitation stays pending.
    set local role authenticated;
    perform public.invite_member('worker@a.de', 'estimator');
    reset role;
    assert not exists (select 1 from public.tenant_members where user_id = '44444444-4444-4444-4444-444444444444'),
        'M1: existing account is not added without consent';

    -- Nobody else can accept it.
    perform test_ctx.login('33333333-3333-3333-3333-333333333333');
    set local role authenticated;
    assert public.get_my_invitation() is null, 'M1: stranger sees no invitation';
    perform test_ctx.expect_error($q$select public.accept_invitation()$q$, 'no open invitation');
    reset role;

    -- The invited person sees the company and accepts.
    perform test_ctx.login('44444444-4444-4444-4444-444444444444');
    set local role authenticated;
    v_inv := public.get_my_invitation();
    assert v_inv ->> 'company' = 'Firma C' and v_inv ->> 'role' = 'estimator', coalesce(v_inv::text, 'null');
    assert public.accept_invitation() = test_ctx.get('tenant_c')::uuid, 'M1: joined company C';
    perform test_ctx.expect_error($q$select public.accept_invitation()$q$, 'already a member');
    reset role;
    assert (select role from public.tenant_members where user_id = '44444444-4444-4444-4444-444444444444') = 'estimator', 'M1: role from invitation';

    perform set_config('request.jwt.claims', '', true);
    set local role anon;
    perform test_ctx.expect_error($q$select public.accept_invitation()$q$, 'permission denied');
    reset role;
    raise notice 'ok M1: invitations reveal nothing; existing accounts join only after accepting';
end $$;

do $$ begin raise notice 'ALL CHECKS PASSED'; end $$;

rollback;
