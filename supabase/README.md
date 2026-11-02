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
- The owner invites workers from the app (`invite_member`); they sign in the same way.
- Suspend a company: `select public.admin_set_company_active('<company id>', false);`

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
