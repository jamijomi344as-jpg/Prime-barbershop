export type Id = string

export type BusinessSettings = {
  id: Id
  business_name: string | null
  logo_path: string | null
  favicon_path: string | null
  description: string | null
  phone: string | null
  email: string | null
  address: string | null
  google_maps_url: string | null
  instagram_url: string | null
  telegram_url: string | null
  whatsapp_url: string | null
  facebook_url: string | null
  tiktok_url: string | null
  currency: string | null
  timezone: string | null
  booking_enabled: boolean
  minimum_booking_notice_minutes: number | null
  maximum_booking_days: number | null
  cancellation_policy: string | null
  booking_buffer_minutes: number | null
  default_slot_interval_minutes: number | null
  allow_any_barber: boolean | null
  require_phone: boolean | null
  require_email: boolean | null
}

export type Category = {
  id: Id
  name: string
  description: string | null
  image_path: string | null
  is_active: boolean
  sort_order: number
  archived_at: string | null
  created_at: string
}

export type Service = {
  id: Id
  category_id: Id
  name: string
  description: string | null
  price: number
  currency: string
  duration_minutes: number
  image_path: string | null
  is_active: boolean
  is_popular: boolean
  consultation_only: boolean
  sort_order: number
  archived_at: string | null
  categories?: Pick<Category, 'name'> | null
}

export type Barber = {
  id: Id
  profile_id: Id | null
  name: string
  profile_image_path: string | null
  bio: string | null
  position: string | null
  specialties: string[]
  is_active: boolean
  sort_order: number
  archived_at: string | null
}

export type Customer = {
  id: Id
  profile_id: Id | null
  full_name: string
  phone: string | null
  email: string | null
  created_at: string
}

export type BookingItem = {
  id: Id
  service_id: Id
  service_name_snapshot: string
  price_snapshot: number
  currency_snapshot: string
  duration_minutes_snapshot: number
  sort_order: number
}

export type Booking = {
  id: Id
  customer_id: Id
  barber_id: Id
  booking_date: string
  start_time: string
  end_time: string
  booking_timezone: string
  starts_at: string
  ends_at: string
  service_duration_minutes: number
  status: string
  currency: string
  subtotal_amount: number
  discount_amount: number
  total_amount: number
  notes: string | null
  cancellation_reason: string | null
  created_at: string
  customers?: Pick<Customer, 'full_name' | 'phone' | 'email'> | null
  barbers?: Pick<Barber, 'name'> | null
  booking_items?: BookingItem[]
}

export type BookingStatus = {
  code: string
  display_name: string
  blocks_availability: boolean
  is_terminal: boolean
  is_cancellation: boolean
  is_no_show: boolean
  counts_toward_revenue: boolean
  customer_cancellable: boolean
  manual_creation_allowed?: boolean
  sort_order: number
}

export type Review = {
  id: Id
  customer_id: Id
  booking_id: Id
  rating: number
  comment: string | null
  status: 'pending' | 'approved' | 'rejected' | 'hidden'
  is_featured?: boolean
  created_at: string
  customers?: Pick<Customer, 'full_name'> | null
}

export type Promotion = {
  id: Id
  code: string
  promotion_type: 'percentage' | 'fixed_amount'
  discount_value: number
  currency: string | null
  start_date: string | null
  end_date: string | null
  minimum_booking_amount: number | null
  maximum_usage: number | null
  is_active: boolean
  archived_at?: string | null
}

export type Notification = {
  id: Id
  notification_type: string
  title: string
  message: string
  data: Record<string, unknown>
  read_at: string | null
  created_at: string
}

export type ActivityLog = {
  id: Id
  actor_profile_id: Id | null
  action: string
  entity_type: string
  entity_id: Id | null
  metadata: Record<string, unknown>
  created_at: string
  profiles?: Pick<{ full_name: string | null }, 'full_name'> | null
}

export type SiteSection = {
  id: Id
  page_slug: string
  section_key: string
  content: {
    title?: string
    subtitle?: string
    description?: string
    image_path?: string
    [key: string]: unknown
  }
  media_path: string | null
  is_active: boolean
  sort_order: number
}

export type BusinessHour = {
  id: Id
  day_of_week: number
  is_active: boolean
  start_time: string | null
  end_time: string | null
}
