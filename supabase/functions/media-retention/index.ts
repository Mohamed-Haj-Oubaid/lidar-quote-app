// Supabase Edge Function: daily media retention clean-up.
//
// Deletes the Storage objects (survey-media bucket) of jobs whose client data was
// erased or that have not changed for longer than the company's
// media_retention_months, then marks the job as purged. Storage objects are only
// ever deleted through the Storage API – a SQL delete would leave the files behind.
//
// Deploy:   supabase functions deploy media-retention --no-verify-jwt
// Secrets:  SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//           CRON_SECRET must be set (supabase secrets set CRON_SECRET=...) and sent
//           by the scheduler in the "x-cron-secret" header.
import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "survey-media";

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: jobs, error } = await admin.rpc("admin_media_retention_candidates", { p_limit: 500 });
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const results: Array<{ job_id: string; files: number; error?: string }> = [];
  for (const job of jobs ?? []) {
    try {
      let files = 0;
      // Folders hold at most a handful of files; page anyway to be safe.
      for (;;) {
        const { data: objects, error: listError } = await admin.storage
          .from(BUCKET).list(job.folder, { limit: 100 });
        if (listError) throw listError;
        if (!objects || objects.length === 0) break;
        const paths = objects.map((o) => `${job.folder}/${o.name}`);
        const { error: removeError } = await admin.storage.from(BUCKET).remove(paths);
        if (removeError) throw removeError;
        files += paths.length;
        if (objects.length < 100) break;
      }
      const { error: markError } = await admin.rpc("admin_mark_media_purged", { p_job_id: job.job_id, p_files: files });
      if (markError) throw markError;
      results.push({ job_id: job.job_id, files });
    } catch (e) {
      // One failing folder never stops the others; it is retried on the next run.
      results.push({ job_id: job.job_id, files: 0, error: String(e) });
    }
  }
  return Response.json({ processed: results.length, results });
});
