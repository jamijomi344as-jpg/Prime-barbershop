# Phase 2 — secure professional admin panel

This phase adds a Vite/React admin application on top of the Phase 1 Supabase foundation. It does not recreate tables, replace Supabase Auth, use another database, expose a service-role key, or weaken RLS.

## Run order

1. Apply all three Phase 1 migrations documented in [`PHASE_1_SUPABASE_ARCHITECTURE.md`](./PHASE_1_SUPABASE_ARCHITECTURE.md).
2. Apply [`../supabase/migrations/20260828000400_admin_panel_operations.sql`](../supabase/migrations/20260828000400_admin_panel_operations.sql).
3. Copy `.env.example` to `.env` and add only the browser-safe Supabase URL and publishable/anon key.
4. Run `npm install` and `npm run dev`.
5. Visit `/admin`.

## Why the Phase 2 migration is required

The Phase 1 schema intentionally permitted customer booking only through `create_my_booking()` and did not have global operating hours or a configurable status-transition map. The dashboard needs a secure way for authorized staff to create a phone booking and change appointment lifecycle data without bypassing the booking engine.

The migration adds only the following capabilities:

| Addition/change | Why it is required | Security effect |
|---|---|---|
| `business_hours` | Stores global Monday–Sunday operating hours for Settings. | Empty by default, so existing barber schedules continue to work. Once configured, hours further limit availability. RLS gives public read only of active hours and settings managers write access. |
| `booking_status_transitions` | Defines valid lifecycle changes as data. | `admin_update_booking()` rejects a transition not in this map. |
| `booking_statuses.manual_creation_allowed` | Controls which existing/future statuses are valid when an authorized staff member creates a manual booking. | Prevents arbitrary initial lifecycle states. |
| `promotions.archived_at` | Supports non-destructive promotion archive. | Existing booking promotion snapshots remain unchanged. |
| `reviews.is_featured` | Supports the requested review feature action. | Still requires review moderation authorization. |
| `barber_is_available_excluding()` | Reuses the Phase 1 availability model when changing an existing booking, excluding that booking from its own conflict check. | Still checks schedules, breaks, time off, business closures, buffer, and active bookings. |
| `admin_available_slots()` | Produces bounded server-validated candidate slots for manual booking. | Requires `bookings.manage`; final creation is always revalidated. |
| `create_admin_booking()` | Creates a phone/manual booking for an existing customer. | Requires `bookings.manage`, uses the same snapshot/availability/promotion/exclusion logic as customer booking. |
| `admin_update_booking()` | Performs status changes, barber changes, and reschedules. | Requires `bookings.manage`, validates transitions and rescheduling availability. Phase 1's direct booking update policy is removed, tightening the write path. |
| `admin_customer_summary()` / `admin_analytics()` | Returns bounded server-side aggregates. | Prevents downloading entire booking/item history to calculate totals and charts. |
| Booking/review notification triggers | Inserts recipient-protected notifications for new bookings/reviews and customer status changes. | Notifications inherit existing RLS and Realtime configuration. |

## SQL migration

The full paste-ready SQL is in:

```text
supabase/migrations/20260828000400_admin_panel_operations.sql
```

### How to run

1. Open **Supabase Dashboard**.
2. Select the project that already has Phase 1 installed.
3. Go to **SQL Editor**.
4. Click **New query**.
5. Paste the entire contents of `20260828000400_admin_panel_operations.sql`.
6. Click **Run**.
7. Do not rerun the Phase 1 migration files after this migration.

### Verification SQL

Run this in a separate SQL Editor query after success:

```sql
select to_regclass('public.business_hours') as business_hours_table,
       to_regclass('public.booking_status_transitions') as transitions_table;

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'create_admin_booking',
    'admin_update_booking',
    'admin_available_slots',
    'admin_customer_summary',
    'admin_analytics'
  )
order by routine_name;

select policyname, tablename
from pg_policies
where schemaname = 'public'
  and tablename in ('business_hours', 'bookings', 'booking_status_transitions')
order by tablename, policyname;

select tgname, tgrelid::regclass as table_name
from pg_trigger
where tgname in (
  'notify_admins_new_booking_after_items',
  'notify_customer_booking_status_change',
  'notify_admins_new_review'
);
```

You should see both tables, all five RPCs, the `business_hours` policies, no `bookings_staff_update` policy, and the three notification triggers.

## Application capabilities

The `/admin` application includes:

- Supabase Auth email/password sign-in; no registration screen.
- Session checking and database `is_admin()` verification before protected routes render.
- Explicit unauthenticated redirect to `/admin/login` and an unauthorized state for signed-in non-admins.
- Responsive desktop sidebar and mobile drawer navigation.
- Live dashboard metrics, recent/upcoming bookings, reviews, and server-side rankings.
- Realtime booking/notification subscription with the required `Новая запись` toast and a click-through to booking details.
- Paginated booking/customer/activity-log pages and debounced server-side customer search.
- Booking details, valid lifecycle actions, rescheduling, barber reassignment, and conflict-safe manual booking.
- Category, service, barber, service-assignment, schedule, break, time-off, review, gallery, promotion, notification, settings, business-hours, and dynamic site-section management.
- Storage uploads to the existing `business-assets` policy-protected bucket.
- Server-side analytics and charts; no placeholder metrics.

## First admin

Use the Phase 1 project-owner-only bootstrap process in [`PHASE_1_SUPABASE_ARCHITECTURE.md`](./PHASE_1_SUPABASE_ARCHITECTURE.md#i-first-admin-setup-instructions). The app has intentionally no admin creation page.

## Local test plan

```bash
cp .env.example .env
# Add the real project URL and publishable/anon key; never add service_role.
npm install
npm run build
npm run dev
```

Then test with separate accounts:

1. Visit `/admin` while signed out: it must redirect to `/admin/login`.
2. Sign in as a customer: it must show the unauthorized state, not dashboard data.
3. Sign in as a project-bootstrap admin: dashboard data should load according to RLS.
4. Configure real business settings, categories, services, a barber-service assignment, recurring barber hours, and optionally global hours before enabling booking.
5. Add a manual booking. Select only a server-returned slot and confirm it is created.
6. Submit two overlapping booking attempts; exactly one must commit and the other must return a friendly slot-conflict message.
7. Change a service price after creating an appointment and confirm historical line items are unchanged.
8. Create a customer booking from a separate customer account and verify the admin receives `Новая запись` without refreshing.
9. Test every CRUD form with an admin and repeat protected REST calls as a non-admin/customer to confirm RLS denies them.
10. Test the responsive layout at desktop, tablet, and mobile widths.

## Important limitations

- The app was build-tested with `npm run build`. It cannot execute live Supabase Auth/RLS/Realtime flows until a real Supabase project URL, publishable key, installed migrations, and test accounts are supplied.
- The current admin panel is deliberately restricted to the `admin` role at the route level, matching the requirement that non-admin users must not see the dashboard. The database permission architecture remains available for future barber/staff portals.
- Manual booking selects existing customers. Staff can create the customer record first from Customers, then create the phone booking. This prevents an unverified arbitrary customer ID from entering the booking RPC.
- Calendar uses a bounded 31-day maximum view and click-through to booking details. Dedicated drag-and-drop scheduling is intentionally deferred; rescheduling already uses the validated appointment editor.
- Deleting a Storage object is intentionally separated from deleting its gallery database row, so an operator cannot accidentally remove a shared file.
