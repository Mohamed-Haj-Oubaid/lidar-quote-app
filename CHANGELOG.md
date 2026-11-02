# Changelog

## 1.1.0 – 2026-11-02 (code-review fixes)

Engine version **1.1.0** (quotes issued with 1.0.0 still decode and render).
New database migrations **07** and **08** – apply them on top of 01–06.

### Critical
- **C1** The server no longer stamps "client informed about privacy" or "client signed" when the app did not send it. Old rows can be reviewed with `admin_list_suspect_privacy_stamps()`.
- **C2** Users who issued quotes can be deleted; whole companies can be erased with `admin_delete_company()` (operator only).
- **C3** Signing out removes the company's data from the device; a different company signing in never receives the previous company's changes; offline jobs need an explicit upload/discard decision.
- **C4** The project builds: correct Info.plist path, Supabase keys from a git-ignored `Config/Secrets.xcconfig`, iOS 17 deployment target.
- **C5** Quotes cannot be issued from the sample price book (watermarked preview instead); permanently rejected changes are blocked and shown with Retry/Discard instead of being resent forever; transient errors back off.

### High
- **H1** Deleting rooms and jobs syncs to the server and other devices.
- **H2** Renaming a room is saved when leaving the field or screen, exactly once.
- **H3** Jobs, rooms and quotes from other devices appear on every device (pending local changes win, otherwise newest wins; deletions and erasures apply).
- **H4** Editing a wall length keeps walls connected and recalculates the floor area; width/depth fields for manual rectangular rooms.
- **H5** The server verifies the quote hash over the exact bytes and recomputes all prices, VAT and totals against the price book.
- **H6** Rooms with the same name no longer break quotes; default room names never repeat.
- **H7** Owners/admins manage team, price book, quote status, client erasure and company export in the app.
- **H8** One failing 3D-model upload no longer fails the whole sync; media is deleted automatically after the retention period (Edge Function `media-retention`).

### Medium / low
- **M1** Inviting an address reveals nothing about other companies; existing accounts join only after accepting.
- **M2** Faster screens: no file writes or repeated JSON decoding during rendering.
- **M3** Clean deduction notes on quote lines.
- **M4** Complete German quote PDF: page numbers, repeated table header, company footer (tax no., VAT ID, IBAN), payment terms, validity date.
- **M5** Longer, unambiguous device codes in provisional quote numbers.
- **M6** Unit-test target `lidarTests` (54 tests) and an extended SQL security & flow test.

### Upgrade notes
1. Run migrations `20261102000007_fixes.sql` and `20261102000008_fixes_medium.sql`.
2. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill in URL and publishable key.
3. Deploy and schedule the `media-retention` Edge Function (see `supabase/README.md` §7b).
4. Review old privacy stamps with `select * from public.admin_list_suspect_privacy_stamps();`.
