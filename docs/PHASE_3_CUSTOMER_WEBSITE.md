# Phase 3 — premium customer-facing website

The customer site is a responsive public React experience on top of the existing Phase 1 database and Phase 2 admin panel. It does not add business seed data, duplicate the database, expose service keys, or replace the admin application.

## New routes

```text
/
/services
/barbers
/gallery
/reviews
/contact
/booking
/admin
```

The existing `/admin` application remains isolated and protected by Supabase Auth plus `is_admin()`.

## Why a Phase 3 migration is necessary

Phase 1 correctly requires `auth.uid()` for `create_my_booking()` and deliberately keeps internal booking/time-off rows private. A no-signup customer flow therefore needs two safe additions:

1. **Supabase Anonymous Auth** gives a visitor a temporary authenticated identity with no registration form or password. It can call the existing ownership-checked booking RPC without opening anonymous table writes.
2. **`get_booking_slots()`** returns safe, server-calculated available times. The browser cannot read bookings/time-off data or decide availability itself.

The migration also adds deliberately narrow public views:

- `public_reviews`: approved review content, a privacy-preserving customer display name, and `is_featured`.
- `public_review_summary`: database-calculated review count and average rating.
- `public_promotions`: currently active/non-archived promotions only.
- `public_business_hours`: open/closed hours needed by the customer site.

Raw tables and their RLS policies are not made public by this migration.

## SQL migration

The full paste-ready SQL is in:

```text
supabase/migrations/20260828000500_customer_booking_availability_and_public_views.sql
```

### How to run

1. Open **Supabase Dashboard**.
2. Select the project where Phase 1 and Phase 2 migrations have already run.
3. Go to **SQL Editor** → **New query**.
4. Paste the complete contents of `20260828000500_customer_booking_availability_and_public_views.sql`.
5. Click **Run**.
6. Verify it with the following SQL:

```sql
select to_regclass('public.public_review_summary') as review_summary_view,
       to_regclass('public.public_promotions') as promotions_view,
       to_regclass('public.public_business_hours') as business_hours_view;

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name = 'get_booking_slots';

grant select on public.public_reviews, public.public_review_summary,
  public.public_promotions, public.public_business_hours to anon, authenticated;
```

The final `GRANT` is idempotent and confirms anonymous/public-view access is intentionally configured.

## Required Supabase Auth setting for frictionless booking

The website does **not** present a customer signup wall. It starts a Supabase Anonymous Auth session only when a visitor requests availability or submits a booking.

In **Supabase Dashboard → Authentication → Providers**:

1. Enable **Anonymous sign-ins**.
2. Enable CAPTCHA/Turnstile where supported by the selected Supabase Auth configuration.
3. Configure Auth rate limits appropriate to launch traffic.
4. Monitor anonymous-account creation and booking RPC failures.
5. Keep all existing email/password customer and admin flows intact.

Anonymous Auth is not an anonymous database bypass: it supplies the JWT required by the existing `create_my_booking()` RLS/ownership architecture. The browser never receives a service-role key.

## Frontend configuration

```bash
cp .env.example .env
```

Add only browser-safe credentials:

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-publishable-anon-key
```

Then run:

```bash
npm install
npm run build
npm run dev
```

Do not put `service_role`, Telegram credentials, email/SMS provider credentials, or any private secret in a `VITE_*` value.

## Dynamic data sources

| Website area | Source |
|---|---|
| Header, footer, contact, logo, favicon, SEO | `business_settings` |
| Hero and editable website content | `site_sections` + `business_settings` |
| Open/closed status and working hours | `public_business_hours` + configured business timezone |
| Services/categories | Public-RLS `services` and `categories` |
| Barber cards and capabilities | Public-RLS `barbers` and `barber_services` |
| Gallery | Public-RLS `gallery` + Supabase Storage URLs |
| Reviews/rating | `public_reviews`, `public_review_summary` |
| Promotion display | `public_promotions` |
| Available slots | `get_booking_slots()` RPC |
| Booking submission/final price/duration | `create_my_booking()` RPC |

The displayed service-cart total is informational only. The final price, duration, promotion validity, availability, buffer, and conflict protection are recalculated by PostgreSQL during `create_my_booking()`.

## Test plan

After applying the migration and configuring a real project:

1. Configure real business settings, open hours, categories, services, barbers, mappings, and barber schedules in `/admin`.
2. Visit `/` and verify the public title, contact data, media, services, barbers, gallery, reviews, promotions, and hours match database records.
3. Create/edit/deactivate a service in `/admin`, refresh `/services`, and verify it appears/updates/disappears. This exact admin-to-website synchronization test has **not** been run in this workspace because it has no connected Supabase project.
4. Start a booking as a fresh visitor; confirm no signup UI appears and Supabase creates an anonymous session only when slots are requested.
5. Verify returned slots avoid breaks, closures, time off, buffers, and existing bookings.
6. Submit a booking and confirm the confirmation screen shows the booking record returned through customer RLS.
7. Submit an overlapping booking from another browser session; confirm the UI shows: `Это время только что заняли. Пожалуйста, выберите другое время.`
8. Check with an anonymous REST request that raw bookings, customers, promotions, and raw reviews remain inaccessible.
9. Test keyboard navigation, modal close controls, focus styling, screen-reader labels, and desktop/tablet/mobile widths.
