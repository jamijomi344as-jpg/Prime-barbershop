import { ArrowUpRight, CalendarClock, CheckCircle2, CircleDollarSign, Clock3, UsersRound } from 'lucide-react'
import { useEffect, useMemo } from 'react'
import { Link } from 'react-router-dom'
import { EmptyState, ErrorState, LoadingBlock, PageHeader, StatusPill } from '../components/ui'
import { formatCurrency, formatDate, formatTime, dateInputValue } from '../lib/format'
import { getSupabase } from '../lib/supabase'
import type { Booking, BookingStatus, Review } from '../lib/types'
import { useAsyncData } from '../hooks/useAsync'

type Analytics = { summary: Record<string, number>; status_counts: Record<string, number>; top_services: Array<{ name: string; bookings: number }>; top_barbers: Array<{ name: string; bookings: number }> }
type DashboardData = { today: Analytics; month: Analytics; totalCustomers: number; activeBarbers: number; currency: string; upcoming: Booking[]; recent: Booking[]; reviews: Review[] }

function zonedDate(timezone?: string | null, date = new Date()) {
  try { return new Intl.DateTimeFormat('en-CA', { timeZone: timezone || undefined }).format(date) } catch { return dateInputValue(date) }
}

function monthStart(date: string) { return `${date.slice(0, 7)}-01` }

export function DashboardPage() {
  const { data, loading, error, reload } = useAsyncData<DashboardData>(async () => {
    const client = getSupabase()
    const { data: settings, error: settingsError } = await client.from('business_settings').select('currency, timezone').eq('is_primary', true).maybeSingle()
    if (settingsError) throw settingsError
    const today = zonedDate(settings?.timezone)
    const todayAnalytics = client.rpc('admin_analytics', { p_from: today, p_to: today })
    const monthlyAnalytics = client.rpc('admin_analytics', { p_from: monthStart(today), p_to: today })
    const [todayResult, monthResult, customersResult, barbersResult, upcomingResult, recentResult, reviewsResult] = await Promise.all([
      todayAnalytics,
      monthlyAnalytics,
      client.from('customers').select('id', { count: 'exact', head: true }),
      client.from('barbers').select('id', { count: 'exact', head: true }).eq('is_active', true).is('archived_at', null),
      client.from('bookings').select('*, customers(full_name, phone, email), barbers(name), booking_items(*)').gte('booking_date', today).order('booking_date').order('start_time').limit(6),
      client.from('bookings').select('*, customers(full_name, phone, email), barbers(name), booking_items(*)').order('created_at', { ascending: false }).limit(6),
      client.from('reviews').select('*, customers(full_name)').order('created_at', { ascending: false }).limit(5),
    ])
    for (const result of [todayResult, monthResult, customersResult, barbersResult, upcomingResult, recentResult, reviewsResult]) if (result.error) throw result.error
    return {
      today: (todayResult.data ?? { summary: {}, status_counts: {}, top_services: [], top_barbers: [] }) as Analytics,
      month: (monthResult.data ?? { summary: {}, status_counts: {}, top_services: [], top_barbers: [] }) as Analytics,
      totalCustomers: customersResult.count ?? 0,
      activeBarbers: barbersResult.count ?? 0,
      currency: settings?.currency ?? '',
      upcoming: (upcomingResult.data ?? []) as Booking[],
      recent: (recentResult.data ?? []) as Booking[],
      reviews: (reviewsResult.data ?? []) as Review[],
    }
  }, [])

  useEffect(() => {
    const refresh = () => void reload()
    window.addEventListener('admin-booking-changed', refresh)
    return () => window.removeEventListener('admin-booking-changed', refresh)
  }, [reload])

  const cards = useMemo(() => data ? [
    { label: 'Bugungi bronlar', value: data.today.summary.bookings ?? 0, icon: CalendarClock, tone: 'gold' },
    { label: 'Kutilayotgan bronlar', value: data.today.status_counts.pending ?? 0, icon: Clock3, tone: 'amber' },
    { label: 'Tasdiqlangan bronlar', value: data.today.status_counts.confirmed ?? 0, icon: CheckCircle2, tone: 'green' },
    { label: 'Yakunlangan bronlar', value: data.today.status_counts.completed ?? 0, icon: CheckCircle2, tone: 'blue' },
    { label: 'Bugungi tushum', value: formatCurrency(data.today.summary.revenue, data.currency), icon: CircleDollarSign, tone: 'gold' },
    { label: 'Oylik tushum', value: formatCurrency(data.month.summary.revenue, data.currency), icon: ArrowUpRight, tone: 'purple' },
    { label: 'Jami mijozlar', value: data.totalCustomers, icon: UsersRound, tone: 'blue' },
    { label: 'Faol sartaroshlar', value: data.activeBarbers, icon: UsersRound, tone: 'green' },
  ] : [], [data])

  if (loading) return <LoadingBlock label="Jonli boshqaruv paneli yuklanmoqda…"/>
  if (error || !data) return <ErrorState message={error ?? 'Boshqaruv ma’lumotlari mavjud emas.'} retry={() => void reload()}/>

  return <>
    <PageHeader title="Xush kelibsiz" description="Jonli ma’lumotlar, namunaviy raqamlar emas." action={<Link className="button" to="/admin/settings">Biznes sozlamalarini ochish</Link>}/>
    {!data.currency && <div className="inline-info" style={{ marginBottom: 18 }}>Hali birlamchi business_settings yozuvi yo‘q. Ommaviy sayt ishlashi uchun Sozlamalar bo‘limida uni yarating.</div>}
    <section className="stat-grid">{cards.map(({ label, value, icon: Icon, tone }) => <article className="stat-card" key={label}><span className={`stat-icon tone-${tone}`}><Icon size={19}/></span><div><span>{label}</span><strong>{value}</strong></div></article>)}</section>
    <section className="dashboard-grid">
      <article className="panel panel-wide"><div className="panel-heading"><div><h2>Yaqinlashayotgan bronlar</h2><p>Keyingi rejalashtirilgan qabullar</p></div><Link to="/admin/bookings">Hammasini ko‘rish</Link></div>
        {data.upcoming.length ? <div className="booking-list">{data.upcoming.map((booking) => <Link key={booking.id} to={`/admin/bookings?open=${booking.id}`} className="booking-row"><div className="date-chip"><strong>{booking.booking_date.slice(-2)}</strong><span>{formatDate(booking.booking_date).slice(0, 3)}</span></div><div className="booking-person"><strong>{booking.customers?.full_name ?? 'Mijoz'}</strong><span>{booking.booking_items?.map((item) => item.service_name_snapshot).join(', ') || 'Xizmat ma’lumotlari yo‘q'}</span></div><div className="booking-meta"><span>{booking.barbers?.name ?? '—'}</span><strong>{formatTime(booking.start_time)}</strong></div><StatusPill value={booking.status}/></Link>)}</div> : <EmptyState title="Yaqinlashayotgan bronlar yo‘q" description="Tasdiqlangan yangi bronlar shu yerda ko‘rinadi." action={<Link className="button button-secondary" to="/admin/bookings">Bronlarni ochish</Link>}/>}</article>
      <article className="panel"><div className="panel-heading"><div><h2>So‘nggi sharhlar</h2><p>Moderatsiya navbati</p></div><Link to="/admin/reviews">Ko‘rib chiqish</Link></div>{data.reviews.length ? <div className="compact-list">{data.reviews.map((review) => <div key={review.id} className="compact-row"><span className="rating-mark">{review.rating}★</span><div><strong>{review.customers?.full_name ?? 'Mijoz'}</strong><p>{review.comment || 'Yozma izoh yo‘q'}</p></div><StatusPill value={review.status}/></div>)}</div> : <EmptyState title="Hozircha sharhlar yo‘q" description="Yuborilgan sharhlar moderatsiya uchun shu yerda chiqadi."/>}</article>
      <article className="panel"><div className="panel-heading"><div><h2>Ommabop xizmatlar</h2><p>Joriy oy bronlari</p></div><Link to="/admin/analytics">Tahlillar</Link></div>{data.month.top_services.length ? <RankedList entries={data.month.top_services}/> : <EmptyState title="Hozircha xizmat ma’lumotlari yo‘q" description="Yakunlangan va bron qilingan xizmatlar real reytingni shakllantiradi."/>}</article>
      <article className="panel"><div className="panel-heading"><div><h2>Ommabop sartaroshlar</h2><p>Joriy oy bronlari</p></div><Link to="/admin/analytics">Tahlillar</Link></div>{data.month.top_barbers.length ? <RankedList entries={data.month.top_barbers}/> : <EmptyState title="Hozircha sartarosh ma’lumotlari yo‘q" description="Reytinglar jonli bron ma’lumotlaridan shakllanadi."/>}</article>
      <article className="panel panel-wide"><div className="panel-heading"><div><h2>So‘nggi bronlar</h2><p>So‘nggi so‘rovlar va telefon orqali kiritilganlar</p></div><Link to="/admin/bookings">Navbatni ochish</Link></div>{data.recent.length ? <div className="compact-list">{data.recent.map((booking) => <div className="compact-row" key={booking.id}><div><strong>{booking.customers?.full_name ?? 'Mijoz'}</strong><p>{formatDate(booking.booking_date)} · {formatTime(booking.start_time)} · {booking.barbers?.name ?? '—'}</p></div><strong>{formatCurrency(booking.total_amount, booking.currency)}</strong><StatusPill value={booking.status}/></div>)}</div> : <EmptyState title="Hozircha bronlar yo‘q" description="Mijozlar yoki xodimlar qabul yaratgach, ular shu yerda ko‘rinadi."/>}</article>
    </section>
  </>
}

function RankedList({ entries }: { entries: Array<{ name: string; bookings: number }> }) {
  return <ol className="ranked-list">{entries.map((entry, index) => <li key={`${entry.name}-${index}`}><b>{String(index + 1).padStart(2, '0')}</b><span>{entry.name}</span><strong>{entry.bookings}</strong></li>)}</ol>
}
