-- =============================================================================
-- 06 · Retention & housekeeping (pg_cron)
--
-- Requires the pg_cron extension. On Supabase: Dashboard → Integrations →
-- Cron → Enable (or Database → Extensions → pg_cron) before running this file.
-- =============================================================================

create extension if not exists pg_cron;

-- Idempotency keys only need to outlive the longest offline period of a device.
select cron.schedule('purge-processed-mutations', '15 3 * * *',
    $$delete from public.processed_mutations where processed_at < now() - interval '180 days'$$);

-- Audit trail is kept 12 months (blueprint CT-6).
select cron.schedule('purge-audit-log', '30 3 * * *',
    $$delete from public.audit_log where created_at < now() - interval '12 months'$$);

-- Stale rate-limit windows and expired invitations.
select cron.schedule('purge-rate-limits', '45 3 * * *',
    $$delete from public.rate_limits where window_start < now() - interval '1 day'$$);
select cron.schedule('purge-expired-invitations', '50 3 * * *',
    $$delete from public.tenant_invitations where accepted_at is null and expires_at < now() - interval '30 days'$$);
