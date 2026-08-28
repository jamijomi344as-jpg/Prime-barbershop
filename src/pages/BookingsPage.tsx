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
    <PageHeader title="Bookings" description="Search, review, and safely manage every appointment." action={<Button onClick={() => setManualOpen(true)}><CalendarPlus size={17}/> Add booking</Button>}/>
    <section className="filter-panel">
      <div className="segmented"><button className={filters.period === 'today' ? 'selected' : ''} onClick={() => updatePeriod('today')}>Today</button><button className={filters.period === 'tomorrow' ? 'selected' : ''} onClick={() => updatePeriod('tomorrow')}>Tomorrow</button><button className={filters.period === 'range' ? 'selected' : ''} onClick={() => setFilter('period', 'range')}>Date range</button><button className={filters.period === 'all' ? 'selected' : ''} onClick={() => setFilter('period', 'all')}>All</button></div>
      <div className="filter-grid">
        {filters.period === 'range' && <><Field label="From"><TextInput type="date" value={filters.start} onChange={(event) => setFilter('start', event.target.value)}/></Field><Field label="To"><TextInput type="date" value={filters.end} onChange={(event) => setFilter('end', event.target.value)}/></Field></>}
        <Field label="Barber"><select className="input" value={filters.barber} onChange={(event) => setFilter('barber', event.target.value)}><option value="">All barbers</option>{data?.barbers.map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}</select></Field>
        <Field label="Service"><select className="input" value={filters.service} onChange={(event) => setFilter('service', event.target.value)}><option value="">All services</option>{data?.services.map((service) => <option key={service.id} value={service.id}>{service.name}</option>)}</select></Field>
        <Field label="Status"><select className="input" value={filters.status} onChange={(event) => setFilter('status', event.target.value)}><option value="">All statuses</option>{data?.statuses.map((status) => <option key={status.code} value={status.code}>{status.display_name}</option>)}</select></Field>
        <Field label="Search customer"><span className="input-with-icon"><Search size={16}/><TextInput placeholder="Name, phone, or email" value={filters.search} onChange={(event) => setFilter('search', event.target.value)}/></span></Field>
      </div>
    </section>
    {loading ? <LoadingBlock label="Loading bookings…"/> : error || !data ? <ErrorState message={error ?? 'Unable to load bookings.'} retry={() => void reload()}/> : <>
      <section className="table-panel"><div className="table-toolbar"><span>{data.total} booking{data.total === 1 ? '' : 's'}</span><button className="text-button" onClick={() => void reload()}><RefreshCw size={15}/> Refresh</button></div>
        {data.bookings.length ? <div className="responsive-table booking-table"><div className="table-head"><span>Customer</span><span>Services</span><span>Barber</span><span>Date & time</span><span>Total</span><span>Status</span><span></span></div>{data.bookings.map((booking) => <article className="table-row" key={booking.id}><div><strong>{booking.customers?.full_name ?? 'Customer'}</strong><small><Phone size={12}/>{booking.customers?.phone || 'No phone'}</small></div><div className="service-cell">{booking.booking_items?.map((item) => item.service_name_snapshot).join(', ') || '—'}</div><div>{booking.barbers?.name ?? '—'}</div><div><strong>{formatDate(booking.booking_date)}</strong><small>{formatTime(booking.start_time)} – {formatTime(booking.end_time)}</small></div><div><strong>{formatCurrency(booking.total_amount, booking.currency)}</strong><small>Created {formatDateTime(booking.created_at)}</small></div><StatusPill value={booking.status}/><button className="text-button" onClick={() => setSelected(booking)}>Details</button></article>)}</div> : <EmptyState title="No bookings found" description="Try changing filters, or add a phone booking for a customer." action={<Button onClick={() => setManualOpen(true)}>Add booking</Button>}/>}</section>
      <Pagination page={page} totalPages={totalPages} onPage={setPage}/>
      {selected && <BookingDetail booking={selected} statuses={data.statuses} transitions={data.transitions} barbers={data.barbers} onClose={() => setSelected(null)} onChanged={() => { pushToast({ title: 'Booking updated', tone: 'success' }); setSelected(null); void reload() }}/>} 
      {manualOpen && <ManualBookingModal barbers={data.barbers} services={data.services} statuses={data.statuses} onClose={() => setManualOpen(false)} onCreated={() => { pushToast({ title: 'Booking created', message: 'The booking is now visible in the live queue.', tone: 'success' }); setManualOpen(false); void reload() }}/>} 
    </>}
  </>
}

function Pagination({ page, totalPages, onPage }: { page: number; totalPages: number; onPage: (page: number) => void }) { return <div className="pagination"><span>Page {page + 1} of {totalPages}</span><div><SecondaryButton disabled={page === 0} onClick={() => onPage(page - 1)}><ChevronLeft size={16}/> Previous</SecondaryButton><SecondaryButton disabled={page + 1 >= totalPages} onClick={() => onPage(page + 1)}>Next <ChevronRight size={16}/></SecondaryButton></div></div> }

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
    if (error) { pushToast({ title: 'Booking could not be updated', message: errorMessage(error), tone: 'error' }); return }
    onChanged()
  }
  const transition = (status: string) => void update({ p_status: status, p_cancellation_reason: status === 'cancelled' ? 'Cancelled by administrator' : null })
  return <Modal title="Booking details" onClose={onClose} wide><div className="detail-grid"><section><span className="detail-label">Customer</span><h3>{booking.customers?.full_name ?? 'Customer'}</h3><p>{booking.customers?.phone || 'No phone'}<br/>{booking.customers?.email || 'No email'}</p></section><section><span className="detail-label">Appointment</span><h3>{formatDate(booking.booking_date)} · {formatTime(booking.start_time)}</h3><p>{booking.barbers?.name ?? '—'} · {booking.service_duration_minutes} min</p></section><section><span className="detail-label">Total</span><h3>{formatCurrency(booking.total_amount, booking.currency)}</h3><p>Created {formatDateTime(booking.created_at)}</p></section><section><span className="detail-label">Status</span><StatusPill value={statusLabels.get(booking.status) ?? booking.status}/>{booking.cancellation_reason && <p>{booking.cancellation_reason}</p>}</section></div>
    <div className="detail-section"><h3>Services</h3>{booking.booking_items?.map((item) => <div className="line-item" key={item.id}><span>{item.service_name_snapshot}</span><span>{item.duration_minutes_snapshot} min</span><strong>{formatCurrency(item.price_snapshot, item.currency_snapshot)}</strong></div>)}</div>
    <div className="detail-section"><h3>Customer note</h3><p className="note-box">{booking.notes || 'No note was left with this booking.'}</p></div>
    <div className="detail-section"><div className="section-inline-heading"><h3>Lifecycle actions</h3><span>Only configured valid transitions are available.</span></div><div className="action-row">{allowed.map((status) => <Button key={status} className={status === 'cancelled' ? 'button-danger' : 'button-secondary'} disabled={busy} onClick={() => transition(status)}>{statusLabels.get(status) ?? humanize(status)}</Button>)}{!allowed.length && <small>This booking is in a terminal state.</small>}</div></div>
    <div className="detail-section"><div className="section-inline-heading"><h3>Reschedule or change barber</h3><button className="text-button" onClick={() => setReschedule((open) => !open)}>{reschedule ? 'Close' : 'Edit appointment'}</button></div>{reschedule && <div className="form-grid compact-form"><Field label="Date"><TextInput type="date" value={date} onChange={(event) => setDate(event.target.value)}/></Field><Field label="Time"><TextInput type="time" value={time} onChange={(event) => setTime(event.target.value)}/></Field><Field label="Barber"><select className="input" value={barberId} onChange={(event) => setBarberId(event.target.value)}>{barbers.filter((barber) => barber.is_active && !barber.archived_at).map((barber) => <option value={barber.id} key={barber.id}>{barber.name}</option>)}</select></Field><Button disabled={busy} onClick={() => void update({ p_booking_date: date, p_start_time: time, p_barber_id: barberId })}>{busy ? 'Checking…' : 'Save appointment'}</Button></div>}</div>
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
  useEffect(() => { let active = true; const run = async () => { setSlot(''); if (!serviceIds.length || !date) { setSlots([]); return } setSlotsLoading(true); const { data, error } = await getSupabase().rpc('admin_available_slots', { p_service_ids: serviceIds, p_booking_date: date, p_barber_id: barberId || null }); if (!active) return; setSlotsLoading(false); if (error) { setSlots([]); pushToast({ title: 'Availability unavailable', message: errorMessage(error), tone: 'error' }); return }; setSlots((data ?? []) as Slot[]) }; void run(); return () => { active = false } }, [serviceIds.join(','), date, barberId])
  const relevantSlots = useMemo(() => slots.filter((candidate) => !barberId || candidate.barber_id === barberId), [slots, barberId])
  const toggleService = (id: string) => setServiceIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id])
  const submit = async () => {
    if (!customerId || !serviceIds.length || !date || !slot) { pushToast({ title: 'Complete the booking', message: 'Choose a customer, at least one service, a date, and an available time.', tone: 'error' }); return }
    setBusy(true)
    const { error } = await getSupabase().rpc('create_admin_booking', { p_customer_id: customerId, p_service_ids: serviceIds, p_booking_date: date, p_start_time: slot, p_barber_id: barberId || null, p_notes: notes || null, p_initial_status: status })
    setBusy(false)
    if (error) { pushToast({ title: 'Booking could not be created', message: errorMessage(error), tone: 'error' }); return }
    onCreated()
  }
  return <Modal title="Add booking" onClose={onClose} wide><p className="modal-copy">The server checks the same schedules, closures, breaks, buffers, and overlap protection used for customer bookings.</p><div className="booking-wizard"><section><Field label="Find customer"><TextInput value={customerSearch} placeholder="Search name, phone, or email" onChange={(event) => setCustomerSearch(event.target.value)}/></Field><div className="customer-picker">{customers.map((customer) => <button type="button" key={customer.id} className={customerId === customer.id ? 'picker-selected' : ''} onClick={() => setCustomerId(customer.id)}><strong>{customer.full_name}</strong><small>{customer.phone || customer.email || 'No contact details'}</small></button>)}</div></section><section><Field label="Select services"><div className="check-list">{services.filter((service) => service.is_active && !service.archived_at).map((service) => <label key={service.id}><input type="checkbox" checked={serviceIds.includes(service.id)} onChange={() => toggleService(service.id)}/><span>{service.name}</span><small>{service.duration_minutes} min · {formatCurrency(service.price, service.currency)}</small></label>)}</div></Field></section><section className="form-grid compact-form"><Field label="Barber"><select className="input" value={barberId} onChange={(event) => setBarberId(event.target.value)}><option value="">Any available barber</option>{barbers.filter((barber) => barber.is_active && !barber.archived_at).map((barber) => <option key={barber.id} value={barber.id}>{barber.name}</option>)}</select></Field><Field label="Date"><TextInput type="date" min={dateInputValue()} value={date} onChange={(event) => setDate(event.target.value)}/></Field><Field label="Initial status"><select className="input" value={status} onChange={(event) => setStatus(event.target.value)}>{statuses.filter((item) => item.manual_creation_allowed).map((item) => <option key={item.code} value={item.code}>{item.display_name}</option>)}</select></Field></section><section><Field label="Available time" hint="Times are generated by the server and revalidated when this booking is confirmed.">{slotsLoading ? <LoadingBlock label="Finding available times…"/> : <div className="slot-list">{relevantSlots.map((candidate) => <button type="button" key={`${candidate.barber_id}-${candidate.start_time}`} className={slot === candidate.start_time ? 'slot-selected' : ''} onClick={() => { setSlot(candidate.start_time); if (!barberId) setBarberId(candidate.barber_id) }}>{formatTime(candidate.start_time)}</button>)}{serviceIds.length > 0 && !relevantSlots.length && <small>No available times for this selection.</small>}</div>}</Field></section><Field label="Internal booking note"><TextArea value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="Optional context for the appointment"/></Field></div><div className="form-actions"><SecondaryButton onClick={onClose}>Cancel</SecondaryButton><Button disabled={busy} onClick={() => void submit()}>{busy ? 'Creating…' : 'Confirm booking'}</Button></div></Modal>
}
