# Phase 3.5 — production audit and Supabase integration verification

Audit date: 2026-08-28. This audit inspected the existing Phase 1–3 migration chain, React source, Supabase client usage, routing, Auth/RLS assumptions, Storage calls, Realtime subscriptions, environment handling, dependency audit, and production build output.

## Scope and evidence boundary

### Verified locally

- All six migration files are present in chronological order.
- Every migration has matching transaction boundaries and an even number of PostgreSQL dollar-quote delimiters.
- `npm run build` passes TypeScript and Vite production build.
- `npm audit --omit=dev` reports zero production dependency vulnerabilities.
- Source inspection found no `service_role`, `SUPABASE_SERVICE_ROLE_KEY`, Telegram token, database password, private API key, or browser-exposed provider secret.
- Customer service and booking-service selectors were changed from a fixed 100-row query to debounced, paginated 12-row server queries.
- Customer barber cards now use 12-row pagination rather than silently stopping after 24 entries.
- Shared modals now lock background scrolling, focus the dialog, and support Escape-to-close.
- Existing production preview accepts the Arena proxied hostname and its `/services` SPA route returns the Vite app shell.

### Requires a live Supabase project

No Supabase project URL, anon key, applied migration history, accounts, data, Storage objects, or Auth provider configuration is connected in this workspace. Therefore no statement below claims live validation of SQL execution, RLS, Auth, Realtime, Storage, or a booking transaction. Those tests are listed in the final manual checklist.

## Audit findings and correction

### Finding: explicit SECURITY DEFINER search path hardening was incomplete

Earlier migrations set `search_path = public` on security-definer functions and later revoked public schema creation. That is a good foundation, but a production audit should explicitly place `pg_catalog` first and `pg_temp` last for **every** current `public` schema security-definer function. The project also needs a durable guard against a later accidental `EXECUTE` privilege granted to `PUBLIC`.

### Fix: new migration `20260828000600_production_fixes.sql`

The migration:

1. Metadata-enumerates every current `public` schema `SECURITY DEFINER` function.
2. Sets each function’s path to `pg_catalog, public, pg_temp`.
3. Revokes accidental `PUBLIC` execute privileges while preserving explicit `anon`/`authenticated` grants required by RLS helpers and browser-safe RPCs.
4. Marks the intentional public projection views as `security_barrier` views.
5. Does **not** alter application data, table RLS policies, or booking logic.

## Migration run instructions

1. Open **Supabase Dashboard**.
2. Select the existing project after confirming migrations `00100` through `00500` have succeeded.
3. Go to **SQL Editor** → **New query**.
4. Paste the complete contents of:

   ```text
   supabase/migrations/20260828000600_production_fixes.sql
   ```

5. Click **Run**.
6. Run this verification SQL in a second query:

```sql
-- All public-schema SECURITY DEFINER functions should have explicit safe path
-- configuration and no PUBLIC execute grant.
select
  p.oid::regprocedure as function_name,
  p.proconfig,
  exists (
    select 1
    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ) as public_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prosecdef
order by 1;

-- Expected: the four views exist and have security_barrier = true.
select c.relname, c.reloptions
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'public_reviews',
    'public_review_summary',
    'public_promotions',
    'public_business_hours'
  )
order by c.relname;

-- Confirm intentionally executable browser RPCs remain granted to authenticated.
select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name in (
    'create_my_booking',
    'get_booking_slots',
    'create_admin_booking',
    'admin_update_booking',
    'admin_available_slots',
    'admin_analytics'
  )
order by routine_name, grantee;
```

Expected results:

- Every displayed security-definer function includes a `search_path=pg_catalog, public, pg_temp` configuration value.
- `public_can_execute` is `false` for every row.
- `security_barrier=true` appears for all four listed views.
- Only intentionally authorized roles have direct RPC execute grants.

## Live RLS/Auth verification checklist

Use distinct anonymous, customer A, customer B, barber, staff-without-permissions, staff-with-`bookings.manage`, and admin sessions.

### Anonymous/public session

- Read active public business/content/catalogue/gallery data and safe public views only.
- Verify no rows are returned from `customers`, `customer_notes`, `bookings`, `booking_items`, `notifications`, `activity_logs`, raw `reviews`, raw `promotions`, or `notification_deliveries`.
- Confirm direct `create_admin_booking`, `admin_update_booking`, `admin_available_slots`, `admin_analytics`, and `admin_customer_summary` calls return authorization errors.

### Customer session

- Customer A can only select their own booking/customer/review/notification data.
- Customer A cannot read or modify Customer B data by changing IDs in REST/RPC requests.
- Direct booking table/item writes must fail; `create_my_booking()` is the only booking creation route.
- Confirm customer cancellation and notification-read RPC ownership checks.

### Admin session

- Visit `/admin` logged out and confirm redirect to `/admin/login`.
- Visit `/admin` signed in as a non-admin and confirm the dashboard does not render.
- Confirm a real admin can manage catalogue/settings/content and use protected booking RPCs.
- Ensure a non-admin cannot use query parameters, route URLs, or client-side state to access admin pages/data.

## Live booking test checklist

1. Configure real business settings, global hours, services, active categories, barbers, barber-service mappings, schedules, and an admin account.
2. Enable Supabase Anonymous Auth and configure rate limits. If CAPTCHA enforcement is enabled, integrate a CAPTCHA token into `signInAnonymously` before enabling enforcement; the current implementation intentionally does not claim CAPTCHA-token integration.
3. Open the public booking flow in a fresh browser profile. Confirm no signup UI is shown and an anonymous Auth identity is created only when slots are requested.
4. Verify `get_booking_slots()` omits schedule breaks, barber time off, business closures, buffer overlaps, unavailable services, inactive barbers, past/minimum-notice slots, and dates outside the configured window.
5. Submit a booking through `create_my_booking()` and verify the actual booking/header/item snapshots in the database.
6. Run two simultaneous requests for the same barber/time. Exactly one must commit; the other must fail with PostgreSQL `23P01`. The website must display the friendly Russian conflict message.
7. Change a service price/duration/name and verify existing `booking_items` snapshots and booking totals remain unchanged.
8. Test a fixed/percentage promotion against valid, expired, inactive, ineligible, and exhausted cases. The database, not browser total, is authoritative.

## Admin-to-customer synchronization checklist

This was not runnable locally without a connected Supabase project. Run it after migration deployment:

1. Create category in admin → refresh `/services` → confirm it appears.
2. Create service, price, duration, and barber assignment → refresh `/services` → confirm current values appear.
3. Edit price → refresh site → confirm the new database price appears.
4. Deactivate/archive service → refresh site → confirm it disappears.
5. Add/deactivate barber → refresh `/barbers` → confirm it appears/disappears.
6. Change business phone/hours → refresh site → confirm header/contact/open-state updates.
7. Add gallery item → refresh `/gallery` → confirm it appears.
8. Approve review → refresh `/reviews` → confirm safe public projection appears.
9. Create an active valid promotion → refresh homepage → confirm it appears.

## Remaining operational requirements

- Enable and monitor Supabase Anonymous Auth deliberately; configure rate limits and abuse detection before public launch.
- CAPTCHA should not be enabled in Supabase until the frontend passes a valid CAPTCHA token to `signInAnonymously`; otherwise booking-session creation will fail.
- Add a staging Supabase project and automated Playwright/API RLS tests before production launch.
- Validate the application at 320, 375, 390, 414, 768, 1024, and 1440+ viewport widths in real browsers. CSS has responsive breakpoints and no build-time overflow errors, but visual/device testing still requires a browser and data.
- The simple modal hardening now supplies focus, Escape close, and background scroll lock; a full tab-cycle focus trap can be added in a future accessibility refinement.
