import { CalendarPlus, ChevronLeft, ChevronRight, Filter, Phone, RefreshCw, Search, X } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Field, TextArea, TextInput } from '../components/forms'
import { Button, ConfirmAction, EmptyState, ErrorState, LoadingBlock, Modal, PageHeader, SecondaryButton, StatusPill, useToast } from '../components/ui'
import { dateInputValue, errorMessage, formatCurrency, formatDate, formatDateTime, formatTime, humanize } from '../lib/format'
import { getSupabase } from '../lib/supabase'
import type { Barber, Booking, BookingStatus, Customer, Service } from '../lib/types'
import { useAsyncData } from '../hooks/useAsync'
import { useDebouncedValue } from '../hooks/useDebouncedValue'

const PAGE_SIZE = 15

type BookingPageData = { bookings: Booking[]; total: number; barbers: Barber[]; services: Service[]; statuses: BookingStatus[]; transitions: Array<{ from_status: string; to_status: string }> }
type Filters = { period: 'today' | 'tomorrow' | 'range' | 'all'; start: string; end: string; barber: string; service: string; status: string; search: string }
type Slot = { barber_id: string; start_time: string; end_time: string }

function initialFilters(): Filters { const today = dateInputValue(); return { period: 'today', start: today, end: today, barber: '', service: '', status: '', search: '' } }

export function BookingsPage() {
  const { pushToast } = useToast()
  const [searchParams, setSearchParams] = useSearchParams()
  const [filters, setFilters] = useState<Filters>(initialFilters)
  const [page, setPage] = useState(0)
  const [selected, setSelected] = useState<Booking | null>(null)
  const [manualOpen, setManualOpen] = useState(false)
  const debouncedSearch = useDebouncedValue(filters.search)

  const { data, loading, error, reload } = useAsyncData<BookingPageData>(async () => {
    const client = getSupabase()
    let customerIds: string[] | null = null
    if (debouncedSearch.trim()) {
      const escaped = debouncedSearch.trim().replace(/[%_,]/g, '')
      const result = await client.from('customers').select('id').or(`full_name.ilike.%${escaped}%,phone.ilike.%${escaped}%,email.ilike.%${escaped}%`).limit(120)
      if (result.error) throw result.error
      customerIds = (result.data ?? []).map((item: { id: string }) => item.id)
      if (!customerIds.length) return { bookings: [], total: 0, barbers: [], services: [], statuses: [], transitions: [] }
    }
    let bookingIds: string[] | null = null
    if (filters.service) {
      const result = await client.from('booking_items').select('booking_id').eq('service_id', filters.service).limit(500)
      if (result.error) throw result.error
      bookingIds = [...new Set((result.data ?? []).map((item: { booking_id: string }) => item.booking_id))]
      if (!bookingIds.length) return { bookings: [], total: 0, barbers: [], services: [], statuses: [], transitions: [] }
    }
    let query = client.from('bookings').select('*, customers(full_name, phone, email), barbers(name), booking_items(*)', { count: 'exact' }).order('booking_date', { ascending: false }).order('start_time', { ascending: false })
    if (filters.period !== 'all') query = query.gte('booking_date', filters.start).lte('booking_date', filters.end)
    if (filters.barber) query = query.eq('barber_id', filters.barber)
    if (filters.status) query = query.eq('status', filters.status)
    if (customerIds) query = query.in('customer_id', customerIds)
    if (bookingIds) query = query.in('id', bookingIds)
    const [bookingsResult, barbersResult, servicesResult, statusesResult, transitionsResult] = await Promise.all([
      query.range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1),
      client.from('barbers').select('*').order('sort_order').order('name').limit(100),
      client.from('services').select('*, categories(name)').order('sort_order').order('name').limit(100),
      client.from('booking_statuses').select('*').order('sort_order'),
      client.from('booking_status_transitions').select('from_status,to_status'),
    ])
    for (const result of [bookingsResult, barbersResult, servicesResult, statusesResult, transitionsResult]) if (result.error) throw result.error
    return { bookings: (bookingsResult.data ?? []) as Booking[], total: bookingsResult.count ?? 0, barbers: (barbersResult.data ?? []) as Barber[], services: (servicesResult.data ?? []) as Service[], statuses: (statusesResult.data ?? []) as BookingStatus[], transitions: transitionsResult.data ?? [] }
  }, [filters.period, filters.start, filters.end, filters.barber, filters.service, filters.status, debouncedSearch, page])

  useEffect(() => {
    const refresh = () => void reload()
    window.addEventListener('admin-booking-changed', refresh)
    return () => window.removeEventListener('admin-booking-changed', refresh)
  }, [reload])

  const openBookingId = searchParams.get('open')
  useEffect(() => {
    if (!openBookingId || !data) return
    const clearOpen = () => { const next = new URLSearchParams(searchParams); next.delete('open'); setSearchParams(next, { replace: true }) }
    const match = data.bookings.find((booking) => booking.id === openBookingId)
    if (match) { setSelected(match); clearOpen(); return }
    let active = true
    void getSupabase().from('bookings').select('*, customers(full_name, phone, email), barbers(name), booking_items(*)').eq('id', openBookingId).maybeSingle().then(({ data: booking }) => {
      if (active && booking) setSelected(booking as Booking)
      if (active) clearOpen()
    })
    return () => { active = false }
  }, [data, openBookingId, searchParams, setSearchParams])

  const updatePeriod = (period: Filters['period']) => {
    const today = new Date()
    let start = dateInputValue(today), end = start
    if (period === 'tomorrow') { today.setDate(today.getDate() + 1); start = end = dateInputValue(today) }
    setFilters((current) => ({ ...current, period, start, end })); setPage(0)
  }
  const setFilter = <K extends keyof Filters>(key: K, value: Filters[K]) => { setFilters((current) => ({ ...current, [key]: value })); setPage(0) }
  const totalPages = Math.max(1, Math.ceil((data?.total ?? 0) / PAGE_SIZE))

  return <>
    <PageHeader title="Bronlar" description="Har bir qabulni qidiring, ko‘rib chiqing va xavfsiz boshqaring." action={<Button onClick={() => setManualOpen(true)}><CalendarPlus size={17}/> Bron qo‘shish</Button>}/>
    <section className="filter-panel">
      <div className="segmented"><button className={filters.period === 'today' ? 'selected' : ''} onClick={() => updatePeriod('today')}>Bugun</button><button className={filters.period === 'tomorrow' ? 'selected' : ''} onClick={() => updatePeriod('tomorrow')}>Ertaga</button><button className={filters.period === 'range' ? 'selected' : ''} onClick={() => setFilter('period', 'range')}>Sana oralig‘i</button><button className={filters.period === 'all' ? 'selected' : ''} onClick={() => setFilter('period', 'all')}>Hammasi</button></div>
      <div className="filter-grid">
        {filters.period === 'range' && <><Field label="Dan"><TextInput type="date" value={filters.start} onChange={(event) => setFilter('start', event.target.value)}/></Field><Field label="Gacha"><TextInput type="date" value={filters.end} onChange={(event) => setFilter('end', event.target.value)}/></Field></>}
        <Field label="Sartarosh"><select className="input" value={filters.barber} onChange={(event) => setFilter('barber', event.target.value)}><option value="">Barcha sartaroshlar</option>{data?.barbers.map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}</select></Field>
        <Field label="Xizmat"><select className="input" value={filters.service} onChange={(event) => setFilter('service', event.target.value)}><option value="">Barcha xizmatlar</option>{data?.services.map((service) => <option key={service.id} value={service.id}>{service.name}</option>)}</select></Field>
        <Field label="Holat"><select className="input" value={filters.status} onChange={(event) => setFilter('status', event.target.value)}><option value="">Barcha holatlar</option>{data?.statuses.map((status) => <option key={status.code} value={status.code}>{status.display_name}</option>)}</select></Field>
        <Field label="Mijozni qidirish"><span className="input-with-icon"><Search size={16}/><TextInput placeholder="Ism, telefon yoki email" value={filters.search} onChange={(event) => setFilter('search', event.target.value)}/></span></Field>
      </div>
    </section>
    {loading ? <LoadingBlock label="Bronlar yuklanmoqda…"/> : error || !data ? <ErrorState message={error ?? 'Bronlarni yuklab bo‘lmadi.'} retry={() => void reload()}/> : <>
      <section className="table-panel"><div className="table-toolbar"><span>Jami {data.total} ta bron</span><button className="text-button" onClick={() => void reload()}><RefreshCw size={15}/> Yangilash</button></div>
        {data.bookings.length ? <div className="responsive-table booking-table"><div className="table-head"><span>Mijoz</span><span>Xizmatlar</span><span>Sartarosh</span><span>Sana va vaqt</span><span>Jami</span><span>Holat</span><span></span></div>{data.bookings.map((booking) => <article className="table-row" key={booking.id}><div><strong>{booking.customers?.full_name ?? 'Mijoz'}</strong><small><Phone size={12}/>{booking.customers?.phone || 'Telefon yo‘q'}</small></div><div className="service-cell">{booking.booking_items?.map((item) => item.service_name_snapshot).join(', ') || '—'}</div><div>{booking.barbers?.name ?? '—'}</div><div><strong>{formatDate(booking.booking_date)}</strong><small>{formatTime(booking.start_time)} – {formatTime(booking.end_time)}</small></div><div><strong>{formatCurrency(booking.total_amount, booking.currency)}</strong><small>Yaratilgan {formatDateTime(booking.created_at)}</small></div><StatusPill value={booking.status}/><button className="text-button" onClick={() => setSelected(booking)}>Tafsilotlar</button></article>)}</div> : <EmptyState title="Bronlar topilmadi" description="Filtrni o‘zgartiring yoki mijoz uchun telefon orqali bron qo‘shing." action={<Button onClick={() => setManualOpen(true)}>Bron qo‘shish</Button>}/>}</section>
      <Pagination page={page} totalPages={totalPages} onPage={setPage}/>
      {selected && <BookingDetail booking={selected} statuses={data.statuses} transitions={data.transitions} barbers={data.barbers} onClose={() => setSelected(null)} onChanged={() => { pushToast({ title: 'Bron yangilandi', tone: 'success' }); setSelected(null); void reload() }}/>} 
      {manualOpen && <ManualBookingModal barbers={data.barbers} services={data.services} statuses={data.statuses} onClose={() => setManualOpen(false)} onCreated={() => { pushToast({ title: 'Bron yaratildi', message: 'Bron endi jonli navbatda ko‘rinadi.', tone: 'success' }); setManualOpen(false); void reload() }}/>} 
    </>}
  </>
}

function Pagination({ page, totalPages, onPage }: { page: number; totalPages: number; onPage: (page: number) => void }) { return <div className="pagination"><span>{page + 1}-sahifa, jami {totalPages}</span><div><SecondaryButton disabled={page === 0} onClick={() => onPage(page - 1)}><ChevronLeft size={16}/> Oldingi</SecondaryButton><SecondaryButton disabled={page + 1 >= totalPages} onClick={() => onPage(page + 1)}>Keyingi <ChevronRight size={16}/></SecondaryButton></div></div> }

function BookingDetail({ booking, statuses, transitions, barbers, onClose, onChanged }: { booking: Booking; statuses: BookingStatus[]; transitions: Array<{ from_status: string; to_status: string }>; barbers: Barber[]; onClose: () => void; onChanged: () => void }) {
  const { pushToast } = useToast()
  const [busy, setBusy] = useState(false)
  const [reschedule, setReschedule] = useState(false)
  const [date, setDate] = useState(booking.booking_date)
  const [time, setTime] = useState(booking.start_time.slice(0, 5))
  const [barberId, setBarberId] = useState(booking.barber_id)
  const allowed = transitions.filter((transition) => transition.from_status === booking.status).map((transition) => transition.to_status)
  const statusLabels = new Map(statuses.map((status) => [status.code, status.display_name]))
  const update = async (payload: Record<string, unknown>) => {
    setBusy(true)
    const { error } = await getSupabase().rpc('admin_update_booking', { p_booking_id: booking.id, ...payload })
    setBusy(false)
    if (error) { pushToast({ title: 'Bronni yangilab bo‘lmadi', message: errorMessage(error), tone: 'error' }); return }
    onChanged()
  }
  const transition = (status: string) => void update({ p_status: status, p_cancellation_reason: status === 'cancelled' ? 'Administrator tomonidan bekor qilindi' : null })
  return <Modal title="Bron tafsilotlari" onClose={onClose} wide><div className="detail-grid"><section><span className="detail-label">Mijoz</span><h3>{booking.customers?.full_name ?? 'Mijoz'}</h3><p>{booking.customers?.phone || 'Telefon yo‘q'}<br/>{booking.customers?.email || 'Email yo‘q'}</p></section><section><span className="detail-label">Qabul</span><h3>{formatDate(booking.booking_date)} · {formatTime(booking.start_time)}</h3><p>{booking.barbers?.name ?? '—'} · {booking.service_duration_minutes} daq</p></section><section><span className="detail-label">Jami</span><h3>{formatCurrency(booking.total_amount, booking.currency)}</h3><p>Yaratilgan {formatDateTime(booking.created_at)}</p></section><section><span className="detail-label">Holat</span><StatusPill value={statusLabels.get(booking.status) ?? booking.status}/>{booking.cancellation_reason && <p>{booking.cancellation_reason}</p>}</section></div>
    <div className="detail-section"><h3>Xizmatlar</h3>{booking.booking_items?.map((item) => <div className="line-item" key={item.id}><span>{item.service_name_snapshot}</span><span>{item.duration_minutes_snapshot} daq</span><strong>{formatCurrency(item.price_snapshot, item.currency_snapshot)}</strong></div>)}</div>
    <div className="detail-section"><h3>Mijoz izohi</h3><p className="note-box">{booking.notes || 'Bu bron uchun izoh qoldirilmagan.'}</p></div>
    <div className="detail-section"><div className="section-inline-heading"><h3>Holat amallari</h3><span>Faqat sozlangan to‘g‘ri o‘tishlar mavjud.</span></div><div className="action-row">{allowed.map((status) => <Button key={status} className={status === 'cancelled' ? 'button-danger' : 'button-secondary'} disabled={busy} onClick={() => transition(status)}>{statusLabels.get(status) ?? humanize(status)}</Button>)}{!allowed.length && <small>Bu bron yakuniy holatda.</small>}</div></div>
    <div className="detail-section"><div className="section-inline-heading"><h3>Qabulni boshqa vaqtga ko‘chirish yoki sartaroshni almashtirish</h3><button className="text-button" onClick={() => setReschedule((open) => !open)}>{reschedule ? 'Yopish' : 'Qabulni tahrirlash'}</button></div>{reschedule && <div className="form-grid compact-form"><Field label="Sana"><TextInput type="date" value={date} onChange={(event) => setDate(event.target.value)}/></Field><Field label="Vaqt"><TextInput type="time" value={time} onChange={(event) => setTime(event.target.value)}/></Field><Field label="Sartarosh"><select className="input" value={barberId} onChange={(event) => setBarberId(event.target.value)}>{barbers.filter((barber) => barber.is_active && !barber.archived_at).map((barber) => <option value={barber.id} key={barber.id}>{barber.name}</option>)}</select></Field><Button disabled={busy} onClick={() => void update({ p_booking_date: date, p_start_time: time, p_barber_id: barberId })}>{busy ? 'Tekshirilmoqda…' : 'Qabulni saqlash'}</Button></div>}</div>
  </Modal>
}

function ManualBookingModal({ barbers, services, statuses, onClose, onCreated }: { barbers: Barber[]; services: Service[]; statuses: BookingStatus[]; onClose: () => void; onCreated: () => void }) {
  const { pushToast } = useToast()
  const [customerSearch, setCustomerSearch] = useState('')
  const [customers, setCustomers] = useState<Customer[]>([])
  const [customerId, setCustomerId] = useState('')
  const [serviceIds, setServiceIds] = useState<string[]>([])
  const [barberId, setBarberId] = useState('')
  const [date, setDate] = useState(dateInputValue())
  const [slot, setSlot] = useState('')
  const [slots, setSlots] = useState<Slot[]>([])
  const [slotsLoading, setSlotsLoading] = useState(false)
  const [busy, setBusy] = useState(false)
  const [notes, setNotes] = useState('')
  const [status, setStatus] = useState('confirmed')
  const search = useDebouncedValue(customerSearch)

  useEffect(() => { let active = true; const run = async () => { const query = search.trim().replace(/[%_,]/g, ''); const result = await getSupabase().from('customers').select('*').or(query ? `full_name.ilike.%${query}%,phone.ilike.%${query}%,email.ilike.%${query}%` : 'full_name.not.is.null').order('created_at', { ascending: false }).limit(30); if (active && !result.error) setCustomers((result.data ?? []) as Customer[]) }; void run(); return () => { active = false } }, [search])
  useEffect(() => { let active = true; const run = async () => { setSlot(''); if (!serviceIds.length || !date) { setSlots([]); return } setSlotsLoading(true); const { data, error } = await getSupabase().rpc('admin_available_slots', { p_service_ids: serviceIds, p_booking_date: date, p_barber_id: barberId || null }); if (!active) return; setSlotsLoading(false); if (error) { setSlots([]); pushToast({ title: 'Mavjudlikni aniqlab bo‘lmadi', message: errorMessage(error), tone: 'error' }); return }; setSlots((data ?? []) as Slot[]) }; void run(); return () => { active = false } }, [serviceIds.join(','), date, barberId])
  const relevantSlots = useMemo(() => slots.filter((candidate) => !barberId || candidate.barber_id === barberId), [slots, barberId])
  const toggleService = (id: string) => setServiceIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id])
  const submit = async () => {
    if (!customerId || !serviceIds.length || !date || !slot) { pushToast({ title: 'Bronni to‘ldiring', message: 'Mijozni, kamida bitta xizmatni, sanani va bo‘sh vaqtni tanlang.', tone: 'error' }); return }
    setBusy(true)
    const { error } = await getSupabase().rpc('create_admin_booking', { p_customer_id: customerId, p_service_ids: serviceIds, p_booking_date: date, p_start_time: slot, p_barber_id: barberId || null, p_notes: notes || null, p_initial_status: status })
    setBusy(false)
    if (error) { pushToast({ title: 'Bronni yaratib bo‘lmadi', message: errorMessage(error), tone: 'error' }); return }
    onCreated()
  }
  return <Modal title="Bron qo‘shish" onClose={onClose} wide><p className="modal-copy">Server mijoz bronlarida qo‘llaniladigan jadvallar, yopilishlar, tanaffuslar, buferlar va to‘qnashuv himoyasini tekshiradi.</p><div className="booking-wizard"><section><Field label="Mijozni toping"><TextInput value={customerSearch} placeholder="Ism, telefon yoki email" onChange={(event) => setCustomerSearch(event.target.value)}/></Field><div className="customer-picker">{customers.map((customer) => <button type="button" key={customer.id} className={customerId === customer.id ? 'picker-selected' : ''} onClick={() => setCustomerId(customer.id)}><strong>{customer.full_name}</strong><small>{customer.phone || customer.email || 'Aloqa ma’lumotlari yo‘q'}</small></button>)}</div></section><section><Field label="Xizmatlarni tanlang"><div className="check-list">{services.filter((service) => service.is_active && !service.archived_at).map((service) => <label key={service.id}><input type="checkbox" checked={serviceIds.includes(service.id)} onChange={() => toggleService(service.id)}/><span>{service.name}</span><small>{service.duration_minutes} daq · {formatCurrency(service.price, service.currency)}</small></label>)}</div></Field></section><section className="form-grid compact-form"><Field label="Sartarosh"><select className="input" value={barberId} onChange={(event) => setBarberId(event.target.value)}><option value="">Har qanday bo‘sh sartarosh</option>{barbers.filter((barber) => barber.is_active && !barber.archived_at).map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}</select></Field><Field label="Sana"><TextInput type="date" min={dateInputValue()} value={date} onChange={(event) => setDate(event.target.value)}/></Field><Field label="Boshlang‘ich holat"><select className="input" value={status} onChange={(event) => setStatus(event.target.value)}>{statuses.filter((item) => item.manual_creation_allowed).map((item) => <option key={item.code} value={item.code}>{item.display_name}</option>)}</select></Field></section><section><Field label="Bo‘sh vaqt" hint="Vaqtlar server tomonidan yaratiladi va bron tasdiqlanganda qayta tekshiriladi.">{slotsLoading ? <LoadingBlock label="Bo‘sh vaqtlar qidirilmoqda…"/> : <div className="slot-list">{relevantSlots.map((candidate) => <button type="button" key={`${candidate.barber_id}-${candidate.start_time}`} className={slot === candidate.start_time ? 'slot-selected' : ''} onClick={() => { setSlot(candidate.start_time); if (!barberId) setBarberId(candidate.barber_id) }}>{formatTime(candidate.start_time)}</button>)}{serviceIds.length > 0 && !relevantSlots.length && <small>Bu tanlov uchun bo‘sh vaqt yo‘q.</small>}</div>}</Field></section><Field label="Ichki bron izohi"><TextArea value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="Qabul uchun ixtiyoriy izoh"/></Field></div><div className="form-actions"><SecondaryButton onClick={onClose}>Bekor qilish</SecondaryButton><Button disabled={busy} onClick={() => void submit()}>{busy ? 'Yaratilmoqda…' : 'Bronni tasdiqlash'}</Button></div></Modal>
}
