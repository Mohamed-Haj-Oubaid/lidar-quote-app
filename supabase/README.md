# Supabase setup – LiDAR Quote App

Everything the app needs on the server. Do the steps **in order**. Dashboard labels
are in English because the Supabase dashboard is English.

## 1. Create the project

1. supabase.com → **New project**
2. **Region: Central EU (Frankfurt)** – required for GDPR/DSGVO.
3. Choose a strong database password and keep it in a password manager.
   Never put it in the app and never send it to anyone.

## 2. Enable extensions

**Integrations → Cron → Enable** (pg_cron, needed by migration 06).

## 3. Run the migrations

**SQL Editor → New query**, paste each file and press **Run**, one after another:

| # | File | What it does |
|---|---|---|
| 1 | `migrations/20261102000001_schema.sql` | Tables, types, integrity rules |
| 2 | `migrations/20261102000002_auth.sql` | Invitation-only sign-up, roles, token claims |
| 3 | `migrations/20261102000003_security.sql` | Locks the database down (RLS, no direct access) |
| 4 | `migrations/20261102000004_rpc.sql` | The API the app uses |
| 5 | `migrations/20261102000005_storage.sql` | Private bucket for 3D models |
| 6 | `migrations/20261102000006_maintenance.sql` | Automatic clean-up jobs |

Each file runs **once**. (With the Supabase CLI instead: `supabase link` + `supabase db push`.)

## 4. Verify

Run `tests/security_and_flow_test.sql` in the SQL Editor. It takes about 20 seconds,
changes nothing (everything is rolled back) and must finish **without an error**.
It proves that anonymous users, strangers and other companies cannot read or change data.

Do **not** run `tests/local_supabase_stub.sql` on Supabase – it is only for local testing.

## 5. Authentication settings

**Authentication → Hooks**
- **Before User Created** → Postgres → `public.hook_before_user_created`
- **Customize Access Token (JWT) Claims** → Postgres → `public.custom_access_token_hook`

**Authentication → Sign In / Providers**
- Email: **enabled**. "Allow new users to sign up": **on** (the hook only lets invited addresses in).
- Disable every other provider and **anonymous sign-ins**.

**Authentication → Email Templates** – "Confirm signup" and "Magic Link" must contain
the code, e.g. `Your code: {{ .Token }}` (the app asks for the code, not a link).

**Authentication → SMTP Settings** – use an EU-based e-mail provider for production
(the built-in sender is only for testing and heavily rate-limited).

**Authentication → Sessions / JWT** – access token expiry **900 s** (15 min),
refresh-token rotation **on**.

**Authentication → Rate Limits** – keep OTP e-mails low (e.g. 30 per hour).

## 6. API & network

- **Project Settings → API Keys**: the app uses the **Publishable key** (`sb_publishable_…`).
  The **Secret key / service_role key** must never be in the app, in Git or in a chat.
  Once the app uses the publishable key, disable the legacy anon/service_role keys.
- **Project Settings → Data API**: exposed schemas = `public` only.
- **Database → Settings → SSL**: enforce SSL. **Network restrictions**: allow direct
  database connections only from your own IP addresses.
- **Advisors → Security Advisor**: should show no errors. "RLS enabled, no policy" on
  tables is intentional – the app has no direct table access.
- Enable **MFA on your supabase.com account**.

## 7. Create the first company

In the SQL Editor (only you as operator can do this):

```sql
select public.admin_create_company('Malerbetrieb Muster GmbH', 'MUS', 'owner@firma.de', 'AVV-2026-1');
```

- The 4th value is the version of the **signed AVV** (data-processing agreement). Leave it
  out (`null`) until the AVV is signed – the server then refuses client data.
  Later: `select public.admin_record_avv('<company id>', 'AVV-2026-1');`
- The owner opens the app → Settings → Sign In with exactly this e-mail → enters the code.
- The owner (or an admin) invites workers in the app: **Settings → Company administration →
  Team → Invite** (`invite_member`). The worker signs in the same way.

## 7a. What owners and admins do in the app

All of these need an internet connection (except quote status) and are checked by the
server on every call:

| Where in the app | What | RPC | Who |
|---|---|---|---|
| Settings → Company administration → Team | Invite, revoke invitations, remove members | `invite_member`, `revoke_invitation`, `remove_member`, `get_team` | Owner, Admin (admins: estimators only) |
| … → Team → role menu | Change a member's role | `change_member_role` | Owner |
| … → Price Book | Edit and publish a new version, re-activate an older one | `publish_price_book_version`, `set_active_price_book_version` | Owner, Admin |
| … → Export Company Data | JSON export, shared via the share sheet | `export_company_data` | Owner |
| Job → ⋯ → Erase Client Data | GDPR Art. 17 erasure incl. 3D models in Storage | `erase_client_data` + Storage API | Owner, Admin |
| Quote → Mark as Sent / Accepted / Rejected | Quote lifecycle (works offline, synced later) | `push_mutations` (`set_quote_status`) | everyone |

Transferring ownership (`transfer_ownership`) is still done by the operator in the SQL Editor.
- Suspend a company: `select public.admin_set_company_active('<company id>', false);`

### Delete a company (contract end, AVV / Art. 28 GDPR)

1. Export the data for the customer first if they want it (the owner can do this in the
   app: Settings → Company → Export).
2. In the SQL Editor:
   ```sql
   select public.admin_delete_company('<company id>', '<exact company name>');
   ```
   The name must match exactly (safety check). This deletes the members' accounts, all
   quotes, jobs, rooms, price books and audit rows of that company. A tenant-less audit
   row `company.deleted` is kept. The function returns the storage prefix, e.g.
   `3f2a…/`.
3. **Storage → survey-media**: open the folder with that prefix and delete it
   (or use the Storage API: list the prefix, then delete the objects).
   Storage files must never be deleted with SQL `delete` – that leaves the files behind.

### Review old "privacy notice shown" stamps

Before migration 07 the server stamped *every* job as "client informed". These rows
cannot be repaired automatically. List suspicious ones (stamp = creation time):

```sql
select * from public.admin_list_suspect_privacy_stamps();
```

Check with the company and clear wrong stamps:
`update public.jobs set privacy_notice_confirmed_at = null where id = '<job id>';`

## 7b. Automatic media clean-up (retention)

Each company has `media_retention_months` (default 24). 3D models of jobs that were not
changed for that long – and of jobs whose client data was erased – are deleted daily by
the Edge Function `supabase/functions/media-retention`. It deletes files through the
Storage API and then marks the job (`jobs.media_purged_at`).

1. Install the Supabase CLI, `supabase link --project-ref <ref>`.
2. `supabase secrets set CRON_SECRET=<long random string>`
3. `supabase functions deploy media-retention --no-verify-jwt`
4. Schedule it daily – either **Integrations → Cron → Create job → HTTP request**
   (POST `https://<ref>.supabase.co/functions/v1/media-retention`, header
   `x-cron-secret: <secret>`), or in the SQL Editor with pg_cron + pg_net
   (enable *pg_net* under Database → Extensions first; store the secret in Vault):
   ```sql
   select vault.create_secret('<long random string>', 'media_retention_cron_secret');
   select cron.schedule('media-retention', '0 4 * * *', $$
     select net.http_post(
       url     := 'https://<ref>.supabase.co/functions/v1/media-retention',
       headers := jsonb_build_object('x-cron-secret',
                    (select decrypted_secret from vault.decrypted_secrets where name = 'media_retention_cron_secret')))
   $$);
   ```
5. Check: **Edge Functions → media-retention → Logs** shows `processed: n` after a run.

## 8. Values for the app

Send to the developer **only**:
- **Project URL** – `https://<project-ref>.supabase.co`
- **Publishable key** – `sb_publishable_…`

## Why the key in the app is safe

Every mobile app's API key can be extracted from the app file – this cannot be prevented,
and hiding it is not security. Here the key alone grants **nothing**:

- Without login: no table, no function, no file is reachable (tested).
- Sign-up only for invited e-mail addresses.
- Logged in: no direct table access at all – only the API functions, which check company
  membership and role on **every** request, are rate-limited and write an audit log.
- Removing a worker or suspending a company takes effect **immediately**.
- Every company only ever sees its own data (tested, including storage files).
