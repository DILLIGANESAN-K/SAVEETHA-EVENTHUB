# SAVEETHA ENGINEERING COLLEGE — by EVENTHUB

A polished responsive campus event website built from the supplied SAVEETHA ENGINEERING COLLEGE starter project and the college/event images uploaded in this conversation.

## Visual assets
All supplied images are included locally in `assets/`: official college emblem, college wordmark, campus evening photograph, Hostel Fest, Smart India Hackathon 2026, Celenza, Hackathon, Ramadan, Christmas, Onam, Pongal and Diwali posters. Event posters are shown in a visual campus-moments gallery. They are not treated as confirmed upcoming events; the live event calendar loads only published records from Supabase.

## Run locally
Use VS Code Live Server or run `python -m http.server 5500` from this folder, then visit `http://localhost:5500`. Do not use `file://` for authentication redirects.

## Supabase setup
1. Create a Supabase project.
2. Run `database/schema.sql` in the Supabase SQL Editor.
3. Put the project URL and publishable/anon key in `config.js`.
4. Enable email/password authentication and configure the allowed redirect URLs.
5. Create and verify the administrator Auth account using `ax7editzzz@gmail.com` (or sign in if it already exists).
6. Run `database/admin_setup.sql` in Supabase SQL Editor. It creates the public event-poster Storage bucket and policies, then grants admin access to the account linked to that email.
7. Admin login accepts either `EVENTHUBadmin` or `ax7editzzz@gmail.com`; the password is the password set for that Supabase Auth account. Do not store admin passwords in frontend files.

## Included functionality
- Premium responsive landing page with campus hero, official brand imagery, poster gallery and subtle animations.
- Supabase email/password signup/login for any syntactically valid email address (no Saveetha-only domain restriction).
- Admin login alias `EVENTHUBadmin` mapped to `ax7editzzz@gmail.com`; authorization is still checked by the Supabase `admin_users` table and RLS.
- Supabase-powered published event discovery, search and category filter.
- Student registration flow using atomic `register_for_event` database function.
- Student dashboard showing registration history.
- Admin-only event creation and unpublishing through RLS-protected database access.
- Admin event poster image uploads to the `event-posters` Supabase Storage bucket (PNG/JPEG/WebP, max 5 MB).
- Modal dialogs, mobile navigation, reduced-motion support and print styling.

## Important implementation status
This is an aesthetic integration build and functional foundation, not yet a fully production-ready campus operations system. The existing schema's pass function deliberately does not expose the raw QR token after issuance, so the current UI does not display a working durable QR pass. Staff camera scanning, token issuance/retrieval design, attendance workflows, full student/registration management, CSV exports, analytics charts, notification delivery, Storage buckets and policies, official event-source importer, and end-to-end security testing remain to be completed. Do not use it for real event gate entry until these items are implemented and tested.

No Supabase credentials were supplied, so live Auth/database connectivity cannot be verified in this build. Only use public frontend keys in `config.js`; never place the service-role key in browser code.


## New requested changes
- Institution branding now reads **SAVEETHA ENGINEERING COLLEGE**, with **BY EVENTHUB** as the platform/creator sub-brand.
- Event list now has Upcoming, Ongoing, Past events and All events views, classified from event date/time and event status.
- After a successful confirmed registration, the student receives an on-screen booking-confirmed state and a QR generated from the one-time pass token returned by the database registration RPC.
- Student dashboard includes a View / refresh QR pass action. The database `get_my_event_pass` RPC now issues a fresh opaque token, stores only its SHA-256 hash, and returns the raw token to the authenticated owner for QR display. Refreshing the pass invalidates the prior token.
- Admin dashboard shows total students, events, registrations, confirmed bookings, waitlisted and cancelled counts, event-wise booking counts, participant details and latest registration rows.

## Database update
If you already ran an earlier version of `database/schema.sql`, re-run the updated `get_my_event_pass` function definition from that file in Supabase SQL Editor. For the admin profile label to match the admin access list, bootstrap an administrator with both statements:
```sql
insert into public.admin_users(user_id) values ('YOUR_AUTH_USER_UUID');
update public.profiles set role='admin' where id='YOUR_AUTH_USER_UUID';
```
Do not run the insert twice for the same user; `admin_users.user_id` is unique.

## Known remaining work
The staff-side camera scanner and `verify_and_checkin` user interface, attendance reporting and duplicate-scan screen, secure poster uploads via Supabase Storage, CSV export, full student account management, email/push notification delivery and comprehensive production QA are still outstanding. The QR token and database verification function are present, but the staff scanner workflow is not yet a complete interface. Do not use as a live gate-entry system until these are implemented and tested.


## Admin setup and safety
- The admin username is a frontend login alias only; Supabase authenticates the linked email. Admin access is not granted by knowing the username. The account must be added to `public.admin_users` by running `database/admin_setup.sql` as the project owner.
- The admin password is never included in this ZIP. Set or rotate it in Supabase Auth; the previously shared password should not be reused.
- Signup accepts common email providers and other valid email addresses. Supabase email confirmation settings still apply.
- This is still a functional foundation, not production-certified. Complete RLS review, test with separate student/admin accounts, and verify event registration/pass workflows before real campus use.
