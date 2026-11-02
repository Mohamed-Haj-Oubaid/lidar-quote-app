-- =============================================================================
-- 05 · Storage: private bucket for room models (USDZ) and photos
--
-- Path layout:  <tenant_id>/<job_id>/<file>
--   * Private bucket – no public URLs; downloads need a logged-in member.
--   * A member can only touch files under their own company's folder and an
--     existing, non-deleted job of that company.
--   * Uploads are refused while the company has "device-only media" enabled.
--   * Size (50 MB) and file types are limited by the bucket.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('survey-media', 'survey-media', false, 52428800,
        array['model/vnd.usdz+zip', 'image/jpeg', 'image/heic'])
on conflict (id) do update set
    public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- True when the object path belongs to the caller's company and an active job.
create function app.media_path_allowed(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
    select array_length(storage.foldername(p_name), 1) = 2
       and (storage.foldername(p_name))[1] = app.tenant_id()::text
       and exists (
            select 1 from public.jobs j
            where j.id::text = (storage.foldername(p_name))[2]
              and j.tenant_id = app.tenant_id()
              and j.deleted_at is null)
$$;

create function app.media_upload_allowed() returns boolean
language sql stable security definer set search_path = '' as $$
    select coalesce((select not t.media_device_only from public.tenants t where t.id = app.tenant_id()), false)
$$;

revoke all on function app.media_path_allowed(text) from public, anon;
revoke all on function app.media_upload_allowed() from public, anon;
grant execute on function app.media_path_allowed(text) to authenticated;
grant execute on function app.media_upload_allowed() to authenticated;

create policy "survey media: members read"
    on storage.objects for select to authenticated
    using (bucket_id = 'survey-media' and app.media_path_allowed(name));

create policy "survey media: members upload"
    on storage.objects for insert to authenticated
    with check (bucket_id = 'survey-media' and app.media_path_allowed(name) and app.media_upload_allowed());

create policy "survey media: members overwrite"
    on storage.objects for update to authenticated
    using (bucket_id = 'survey-media' and app.media_path_allowed(name))
    with check (bucket_id = 'survey-media' and app.media_path_allowed(name) and app.media_upload_allowed());

-- Deleting (e.g. after erase_client_data) is limited to Owner/Admin; the folder of an
-- erased job may still be cleaned up even though the job row is kept.
create policy "survey media: owner/admin delete"
    on storage.objects for delete to authenticated
    using (bucket_id = 'survey-media'
           and (storage.foldername(name))[1] = app.tenant_id()::text
           and app.user_role() in ('owner', 'admin'));
