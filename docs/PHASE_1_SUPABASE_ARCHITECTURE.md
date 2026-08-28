# Phase 1 — Supabase database, Auth, and security architecture

This document is the implementation guide for the Phase 1 database foundation. It intentionally contains **no barbershop-specific data**: no name, contact details, services, categories, prices, staff, schedules, gallery images, reviews, or marketing copy are inserted by the migrations.

The complete runnable SQL is split into the three ordered files in [`../supabase/migrations`](../supabase/migrations):

1. `20260828000100_core_schema.sql`
2. `20260828000200_database_functions_and_triggers.sql`
3. `20260828000300_rls_storage_and_realtime.sql`

## A. Architecture overview

- **One dynamic business configuration** lives in `business_settings`. It has no seed row. Create it in the admin application, set it up, and only then set `booking_enabled = true`.
- **Dynamic site content** lives in `site_sections`. The future Home, Services, Barbers, Gallery, Reviews, Contact, and Booking pages must read this and the public catalogue tables rather than embedding business copy or media in source code.
- **Supabase Auth owns credentials** in `auth.users`; `profiles` is the safe application companion table. An Auth trigger gives every new identity the `customer` role only. It never makes an admin.
- **RBAC is data-driven.** `roles`, `permissions`, `user_roles`, `role_permissions`, and `user_permissions` support admin, barber, staff, and customer users while allowing carefully scoped staff permissions and expiring direct grants.
- **All scheduling uses `timestamptz` internally.** A booking also snapshots its local `booking_date`, `start_time`, `end_time`, and `booking_timezone`, so reporting and historical display survive later settings changes.
- **Booking items are immutable snapshots.** A booking keeps the service name, price, currency, and duration that were applicable when it was created. Editing a service later cannot change historical totals.
- **Booking creation is an authenticated transactional RPC** (`create_my_booking`), not a collection of browser inserts. It validates business configuration, notice/window, active services, barber assignments, schedule/breaks/time off/closures, promotion rules, and customer ownership. A PostgreSQL exclusion constraint is the final authority that prevents a concurrent double booking.
- **Public data is explicitly opt-in.** Active catalogue/content rows are public; personal data, notes, bookings, activity logs, and delivery metadata are not. Approved reviews are exposed through the narrow `public_reviews` view so customer and booking IDs are not public.
- **Analytics are calculated from source-of-truth records.** Group `bookings.booking_date` for daily/weekly/monthly volume; sum `total_amount` where `booking_statuses.counts_toward_revenue`; use immutable `booking_items` for popular services; group bookings by `barber_id`; use `is_cancellation`/`is_no_show` for rates; and use `customers.created_at` plus booking counts for new/returning customers. No fake aggregate data is stored.

## B. Database table explanation

### Identity and authorization

| Table | Why it exists |
|---|---|
| `profiles` | Application profile keyed one-to-one to `auth.users`; contains only safe self-profile fields. |
| `roles` | Extensible role definitions. The platform seeds only `admin`, `barber`, `staff`, and `customer`. |
| `permissions` | Fine-grained capabilities such as `bookings.manage` and `reviews.moderate`. These are application security configuration, not business content. |
| `user_roles` | Many-to-many role assignments. A user can be a barber and a customer, for example. |
| `role_permissions` | Default capabilities for a role. |
| `user_permissions` | Narrow user-specific grants, optionally expiring, needed for configurable staff access. |

### Dynamic business and public content

| Table | Why it exists |
|---|---|
| `business_settings` | Singleton-style primary business configuration: identity, contact/social links, currency/timezone, booking controls, policy, and slot/buffer settings. There is no hardcoded fallback business value. |
| `site_sections` | Dynamic page/section content JSON and optional media path. It supports CMS-style home hero, contact, and other page sections without a frontend content constant. |
| `categories` | Admin-managed service groups with active/archive/reorder support. |
| `services` | Dynamic services, price/currency/duration/image/popularity/consultation state. Live values are never used to rewrite booking history. |
| `barbers` | Dynamic staff presentation data, optional Auth profile link, specialties, ordering, active/archive state. |
| `barber_services` | Many-to-many capability mapping: which active barber can provide which active service. |

### Availability

| Table | Why it exists |
|---|---|
| `barber_schedules` | Recurring weekday shifts; multiple non-overlapping shifts can exist on one day. `day_of_week` uses PostgreSQL `EXTRACT(DOW)` values: `0` Sunday through `6` Saturday. |
| `barber_schedule_breaks` | Normalized zero-to-many breaks inside a particular shift. Trigger checks prevent out-of-shift and overlapping breaks. |
| `barber_time_off` | Barber-specific vacation, holiday, sick day, temporary closure, or other exception intervals. Reasons are never public. |
| `business_closures` | A necessary separate table for location-wide closures, preventing duplicated holiday records for every barber. |

### Customer, bookings, and promotions

| Table | Why it exists |
|---|---|
| `customers` | Minimal customer contact record linked to an Auth profile when the customer self-books. It deliberately omits internal notes. |
| `customer_notes` | Staff-only operational notes, separated to prevent a customer who reads their own profile from seeing internal notes. |
| `booking_statuses` | Data-driven status definitions. It seeds `pending`, `confirmed`, `in_progress`, `completed`, `cancelled`, and `no_show`, but future statuses can be inserted safely with operational flags rather than changing an enum or conflict constraint. |
| `bookings` | Appointment header: customer, barber, canonical instants, local time snapshot, status, booking buffer snapshot, totals, promotion snapshot, notes/cancellation, and the exclusion-protected range. |
| `booking_items` | One-or-more service line items. A deferred booking constraint rejects an empty booking at commit; the insert trigger snapshots name/price/currency/duration and another trigger prevents later mutation/deletion. |
| `promotions` | Promotion code, percent/fixed amount, fixed-currency requirement, validity window, minimum, max usage, and active state. |
| `promotion_services` | Optional service eligibility mappings. |
| `promotion_categories` | Optional category eligibility mappings. A promotion with no mappings applies to all active selected services. |

### Reviews, media, notifications, and audit

| Table / view | Why it exists |
|---|---|
| `reviews` | Customer/booking-bound rating and moderation workflow. A trigger verifies ownership and a status marked review-eligible (initially only completed) before insert/update. |
| `public_reviews` | Narrow public projection of approved reviews only. It excludes internal foreign keys. |
| `gallery` | Dynamic active/featured/reorderable gallery content and storage path. `category` is data, never a frontend enum. |
| `notifications` | In-app notification record for a profile and/or customer, with type/title/message/data/read state. |
| `notification_deliveries` | Independent delivery attempts for in-app, email, SMS, WhatsApp, and Telegram. Provider IDs/errors are operational data; credentials are never stored here. |
| `activity_logs` | Append-only-at-the-application-layer audit events for privileged catalogue, schedule, settings, booking, review, gallery, and promotion changes. It stores changed field names rather than duplicating private customer records. |

## C. Relationship diagram in text

```text
auth.users (Supabase-managed credentials)
  1 ── 1 profiles
            ├──< user_roles >── 1 roles ──< role_permissions >── 1 permissions
            └──< user_permissions >── 1 permissions

profiles 1 ── 0..1 customers
profiles 1 ── 0..1 barbers

categories 1 ──< services
barbers >──< services                 via barber_services
barbers 1 ──< barber_schedules 1 ──< barber_schedule_breaks
barbers 1 ──< barber_time_off
business_closures                     (business-wide availability exception)

customers 1 ──< customer_notes
customers 1 ──< bookings >── 1 barbers
bookings  1 ──< booking_items >── 1 services
bookings  0..1 ── 1 promotions          (snapshotted code/discount remain on booking)
promotions >──< services                via promotion_services
promotions >──< categories              via promotion_categories

customers 1 ──< reviews >── 1 bookings  (one review per booking)
profiles/customers 1 ──< notifications 1 ──< notification_deliveries
profiles 0..1 ──< activity_logs

business_settings                       (one row where is_primary = true)
site_sections, gallery                  (independent dynamic public content)
booking_statuses ──< bookings
```

## D. Security architecture

1. **Credentials and sessions:** Supabase Auth is the only identity provider in this schema. The browser uses the Supabase publishable/anon key and the user session JWT; it never receives `service_role`.
2. **No public admin creation:** `handle_new_auth_user` creates a `profiles` row and assigns only `customer`. The `admin` role has no signup route, signup metadata switch, client RPC, or URL-based bypass.
3. **Database authorization is authoritative:** `is_admin`, `has_permission`, ownership helpers, and RLS guard direct REST, GraphQL, and Realtime access. A future `/admin` route is only a UI concern; it must check the session/role, but direct database access stays blocked even when somebody types the route URL.
4. **Controlled state changes:** customer booking, customer cancellation, notification read state, and role assignment use narrow `SECURITY DEFINER` functions. Their search path is fixed and execution is granted only where needed. They are not general database access functions.
5. **Database-level concurrency:** the `bookings_no_overlap_per_barber` GiST exclusion constraint prevents overlapping `appointment_range` records where the dynamic status flag says the booking blocks availability. The range includes the buffer stored at booking time. The application must display PostgreSQL conflict `23P01` as “that slot was just taken” and refresh availability.
6. **PII minimization:** customer data is limited to name, phone, and email. Internal notes are a private table. Do not add payment card data, ID documents, Telegram tokens, auth passwords, or other unnecessary sensitive data.
7. **Server-side integrations only:** Telegram bot tokens, email/SMS/WhatsApp credentials, payment secrets, and the Supabase service-role key belong in Supabase Edge Function secrets or another server secret manager. An Edge Function creates `notification_deliveries`/calls providers and updates delivery status; browser code only calls an authenticated endpoint or receives authorized Realtime data.

## E. RLS strategy

| Caller | Permitted data/actions |
|---|---|
| Anonymous visitor | Read only the primary public business settings, active site sections/categories/services/barbers/assignments/recurring schedules/breaks, active gallery, public asset paths, and `public_reviews`. No anonymous writes. |
| Authenticated customer | Their profile/customer row, their booking headers/items, their own reviews, and their own notifications. Booking creation/cancellation/read marking occur through ownership-checked RPCs; customer cannot directly change status, booking items, notification content, staff notes, or another user’s data. |
| Linked barber | Their own barber schedules/time-off and bookings assigned to the barber record linked to their `profiles.id`. Further changes require an explicit permission. |
| Staff | Only capabilities deliberately granted through a role permission or unexpired `user_permissions` row. Defaults grant nothing. |
| Admin | `is_admin()` grants all permission checks and CRUD policies for the management surface. An audit trigger logs important privileged actions. |
| Service role | Bypasses RLS by design and must remain server-only. It is not used by public clients. |

Other important RLS decisions:

- Raw `reviews` are not anonymous-readable; anonymous access is only through `public_reviews`, which selects approved content and hides `customer_id`/`booking_id`.
- `customer_notes`, `activity_logs`, `notification_deliveries`, promotion configuration, business closures, and time-off reasons have no public policy.
- Bookings have no DELETE policy. They are cancelled to preserve reporting and audit history.
- `booking_items` have no client write policy and an immutable trigger. The trusted booking function writes them atomically.
- Table verbs granted to `authenticated` are harmless without a matching RLS policy; a missing policy is an explicit denial.

## F. Complete SQL migration

Run these **in exactly this order**. They are intentionally split because this is safer than debugging a single very large SQL Editor transaction and makes failure recovery obvious.

| SQL Editor run | Complete file | Includes |
|---|---|---|
| **SQL 1** | [`20260828000100_core_schema.sql`](../supabase/migrations/20260828000100_core_schema.sql) | Extensions, controlled values, tables, foreign keys, indexes, and the GiST double-booking exclusion constraint. |
| **SQL 2** | [`20260828000200_database_functions_and_triggers.sql`](../supabase/migrations/20260828000200_database_functions_and_triggers.sql) | Auth profile/customer-role trigger, authorization helpers, booking/cancellation/notification/role RPCs, snapshot/validation/audit triggers. |
| **SQL 3** | [`20260828000300_rls_storage_and_realtime.sql`](../supabase/migrations/20260828000300_rls_storage_and_realtime.sql) | Least-privilege grants, RLS enablement/policies, Storage bucket/policies, and Realtime publication configuration. |

Each file is a complete SQL query with its own `BEGIN`/`COMMIT`; **do not paste all three into one SQL Editor query**. The migrations are reasonably idempotent for a clean/project-initial setup (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`, and policy/trigger replacement are used). Do not edit a migration that has already been applied to a shared production project—create a new timestamped migration for later schema evolution.

The booking function takes the PostgreSQL/PostgREST RPC shape below; a future frontend should call this instead of inserting booking rows itself:

```ts
await supabase.rpc('create_my_booking', {
  p_service_ids: selectedServiceIds,
  p_booking_date: localDate,       // YYYY-MM-DD in configured business timezone
  p_start_time: localStartTime,    // HH:MM:SS
  p_barber_id: selectedBarberId ?? null,
  p_notes: customerBookingNote ?? null,
  p_promotion_code: enteredCode ?? null,
  p_customer_name: enteredName,
  p_customer_phone: enteredPhone ?? null,
  p_customer_email: enteredEmail ?? null,
})
```

## G. Optional development seed SQL

No seed SQL is provided on purpose. This is a production-ready clean foundation, and inserting placeholder names, services, prices, contact data, schedules, reviews, or images would violate the no-hardcoded-business-information requirement.

For local-only testing, create a separate ignored development script after real configuration is known. Never run it in production, never call it from an app startup path, and do not commit fake public business content as a production migration.

## H. Supabase setup instructions

1. Create/select the Supabase project and use a development project first.
2. In the Supabase Dashboard, go to **SQL Editor → New query**.
3. Open `supabase/migrations/20260828000100_core_schema.sql`, paste the complete file, and click **Run**. Confirm it succeeds.
4. Go to **SQL Editor → New query**, paste `20260828000200_database_functions_and_triggers.sql`, and click **Run**.
5. Go to **SQL Editor → New query**, paste `20260828000300_rls_storage_and_realtime.sql`, and click **Run**.
6. In **Authentication → Providers**, enable only the customer sign-in methods you intend to support. Configure redirect URLs, email confirmation, MFA/session controls, and password policy before launch. Do not collect a role from signup metadata.
7. Create the first admin by following the next section.
8. Sign in as that admin and create the one real `business_settings` row. Keep `booking_enabled = false` until every required booking setting is present: business name, currency, IANA timezone, minimum notice, maximum days, buffer, default interval, barber-selection setting, phone requirement, and email requirement.
9. Add real categories, services, barbers, barber-service mappings, and schedules through a protected admin surface or trusted Dashboard SQL during initial setup. Enable booking only after valid availability exists.
10. For repeatable environments, use these files through the Supabase CLI migration workflow; the SQL Editor sequence above is the explicit manual path.

## I. First-admin setup instructions

There is no public “Create Admin” flow. Use this project-owner-only bootstrap process after all three migrations have succeeded.

1. In **Supabase Dashboard → Authentication → Users**, click **Add user** (or invite a controlled owner email). Use a strong unique password/normal invitation flow and the intended production email confirmation settings.
2. Copy that user’s UUID from the Users page. The Auth trigger has already made a `profiles` row and assigned the harmless `customer` role.
3. Go to **SQL Editor → New query** and run the following as the Supabase project owner, replacing only the UUID placeholder:

   ```sql
   insert into public.user_roles (user_id, role_code)
   values ('<AUTH_USER_UUID>', 'admin')
   on conflict (user_id, role_code) do nothing;
   ```

4. Verify the database assignment in SQL Editor:

   ```sql
   select user_id, role_code, created_at
   from public.user_roles
   where user_id = '<AUTH_USER_UUID>';
   ```

5. Sign in through the future app (or an authenticated test client), call `supabase.rpc('is_admin')`, and verify it returns `true`. Verify a non-admin account returns `false` and cannot select customers/bookings/activity logs or mutate catalogue data.
6. Keep at least two independently controlled admin accounts in production. The trigger prevents removal/replacement of the final admin role to avoid accidental lockout.

After bootstrap, use the protected `assign_user_role` RPC from an authenticated authorized admin workflow. It rejects unauthenticated callers and rejects non-admin attempts to grant `admin`; never expose direct role-table mutation in a customer UI.

## J. Storage setup

SQL 3 creates one public bucket named `business-assets` with a 10 MiB image limit and allowed MIME types: JPEG, PNG, WebP, AVIF, and SVG.

Use these top-level object paths exactly:

```text
business-assets/logos/<generated-file-name>
business-assets/favicons/<generated-file-name>
business-assets/hero/<generated-file-name>
business-assets/barbers/<generated-file-name>
business-assets/services/<generated-file-name>
business-assets/gallery/<generated-file-name>
```

Store the object path (for example `barbers/<generated-file-name>`) in the database `*_path`/`image_path` columns. The frontend should call Supabase Storage to derive the public URL at runtime; it must not embed a project-specific storage origin in content or code.

- Anonymous users can read only objects under the listed public folders.
- Only users with `assets.manage` (administrators by default) can upload, replace, or delete these objects.
- The bucket is for intentionally public marketing images only. Do not put contracts, customer uploads, staff documents, or secrets there.
- Review-image upload is not a current requirement, so no unnecessary private bucket/table is created. If product requirements add it, create a **private** `review-images` bucket plus a `review_images` ownership/mapping table and serve approved images through a signed-URL server endpoint; do not turn the public media bucket into a catch-all.

## K. Realtime setup

SQL 3 adds only these tables to `supabase_realtime` and sets `REPLICA IDENTITY FULL`:

- `bookings` — admin booking board, barber’s own booking updates, and a customer’s own status changes.
- `notifications` — in-app unread/read updates for the intended recipient.

A future client subscribes with `postgres_changes` to the relevant table and refreshes its authorized query on an event. It may add a filter such as `customer_id=eq.<id>` or `barber_id=eq.<id>` for efficiency, but **the filter is not a security control**. Realtime uses the select RLS policy: only the booking owner, linked barber, or authorized staff can receive booking data; only the intended recipient or notification manager can receive notification data.

Do not publish `customers`, `customer_notes`, `activity_logs`, delivery metadata, or other sensitive tables to Realtime. External notification delivery should be handled by an Edge Function/queue worker, not a browser subscription.

## L. Security testing checklist

Run these checks with separate anonymous, customer A, customer B, barber, staff-without-permission, staff-with-one-permission, and admin test accounts before any launch.

- [ ] Anonymous REST calls can read only active public catalogue/content and `public_reviews`; they receive no rows from raw `reviews`, customers, bookings, booking items, private notes, promotions, activity logs, notifications, time off, or closures.
- [ ] A newly registered user has `customer` only; adding `role=admin` to signup metadata changes nothing.
- [ ] Customer A cannot select/update Customer B’s profile/customer row, bookings/items, reviews, or notifications by UUID.
- [ ] Customer A cannot insert/update a booking directly, change a booking status, alter an item snapshot, delete a booking, or mark Customer B’s notification as read.
- [ ] Customer A can call `create_my_booking` only with active services and valid configured availability, and the function rejects an unavailable/inactive barber, notice/window breach, break, time off, closure, invalid code, invalid promotion target, or missing required contact field.
- [ ] Two concurrent calls for the same barber and overlapping time result in exactly one committed booking. The other fails with PostgreSQL exclusion error `23P01`.
- [ ] Change a service name/price/duration after making a booking. Confirm its `booking_items` and booking totals/end time stay unchanged.
- [ ] A cancelled booking releases availability; a pending/confirmed/in-progress booking blocks it according to `booking_statuses.blocks_availability`.
- [ ] A barber sees only bookings assigned to the barber record linked to their profile and only their own time-off/schedule information.
- [ ] A staff account has no access until explicit permission. Test every permission individually, especially that `access.manage` cannot grant `admin` unless caller is already admin.
- [ ] An admin can manage intended data and activity logs are created for privileged service price, schedule, booking, promotion, review, content, and settings changes without duplicating customer PII.
- [ ] Storage upload/list/delete fails for customer/staff accounts without `assets.manage`, and succeeds only in approved public folders for an asset manager.
- [ ] Realtime booking/notification subscriptions receive only rows the test identity can select through RLS.
- [ ] Search the frontend, build output, repository, and browser network payloads for `service_role`, Telegram tokens, provider credentials, database passwords, and private environment variables. None may exist client-side.

## M. What we should build in Phase 2

Do **not** build the full marketing frontend before these database tests pass. Phase 2 should build a minimal authenticated application layer around this foundation:

1. Supabase client/server configuration using only a publishable/anon key in the browser and server-only environment validation.
2. Customer Auth screens and session handling, with protected route middleware that checks database authorization rather than trusting `/admin`.
3. Public dynamic data loaders for settings/site sections/services/barbers/gallery/public reviews; no business copy or catalogue constants in UI code.
4. Booking availability UI that calls a safe availability endpoint/query and submits only through `create_my_booking`; handle `23P01` conflicts gracefully.
5. First protected admin shell, starting with settings, categories, services, barbers, mappings, schedules, and bookings; use the RLS permissions above.
6. Server-side notification Edge Function skeleton with secrets stored in Supabase secrets, delivery queue processing, retries, and audit-safe logging.
7. Realtime booking and notification subscriptions, then analytics queries/views based on `booking_date`, immutable snapshots, and the configurable `booking_statuses` analytics flags.
