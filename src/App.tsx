import { AlertTriangle, LockKeyhole, LogIn, ShieldCheck } from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { PublicWebsite } from './customer/PublicWebsite'
import { AdminShell } from './components/AdminShell'
import { ErrorBoundary } from './components/ErrorBoundary'
import { Button, LoadingBlock, ToastProvider, useToast } from './components/ui'
import { errorMessage } from './lib/format'
import { getSupabase, isSupabaseConfigured, supabase } from './lib/supabase'
import { DashboardPage } from './pages/DashboardPage'
import { BookingsPage } from './pages/BookingsPage'
import { BarbersPage, CategoriesPage, ServicesPage } from './pages/CatalogPages'
import { CustomersPage } from './pages/CustomersPage'
import { CalendarPage, GalleryPage, PromotionsPage, ReviewsPage } from './pages/OperationsPages'
import { AnalyticsPage, ActivityLogPage, NotificationsPage, SettingsPage } from './pages/AdminPages'
import { SchedulesPage } from './pages/SchedulesPage'

type AccessState = 'loading' | 'authorized' | 'unauthenticated' | 'unauthorized'

export function App() {
  return (
    <ToastProvider>
      <Routes>
        <Route path="/admin/login" element={<AdminLoginRoute />} />
        <Route path="/admin/*" element={<ProtectedAdmin />} />
        <Route path="/*" element={<ErrorBoundary title="Saytni yuklash imkoni bo‘lmadi"><PublicWebsite /></ErrorBoundary>} />
      </Routes>
    </ToastProvider>
  )
}

function useAdminAccess() {
  const [session, setSession] = useState<Session | null>(null)
  const [access, setAccess] = useState<AccessState>(isSupabaseConfigured ? 'loading' : 'unauthenticated')
  const [userName, setUserName] = useState('Administrator')

  useEffect(() => {
    if (!supabase) {
      setAccess('unauthenticated')
      return
    }
    let mounted = true
    const verify = async (candidate: Session | null) => {
      if (!mounted) return
      setSession(candidate)
      if (!candidate) {
        setAccess('unauthenticated')
        return
      }
      setAccess('loading')
      try {
        const [roleResult, profileResult] = await Promise.all([
          getSupabase().rpc('is_admin'),
          getSupabase().from('profiles').select('full_name').eq('id', candidate.user.id).maybeSingle(),
        ])
        if (!mounted) return
        if (roleResult.error || roleResult.data !== true) {
          setAccess('unauthorized')
          return
        }
        setUserName(profileResult.data?.full_name || candidate.user.email || 'Administrator')
        setAccess('authorized')
      } catch {
        if (mounted) setAccess('unauthorized')
      }
    }
    void getSupabase().auth.getSession().then(({ data }) => verify(data.session))
    const { data: listener } = getSupabase().auth.onAuthStateChange((event, nextSession) => {
      if (event === 'SIGNED_OUT' || event === 'TOKEN_REFRESHED' || event === 'SIGNED_IN' || event === 'INITIAL_SESSION') {
        void verify(nextSession)
      }
    })
    return () => {
      mounted = false
      listener.subscription.unsubscribe()
    }
  }, [])

  return { session, access, userName }
}

function AdminLoginRoute() {
  const { access } = useAdminAccess()
  if (!isSupabaseConfigured) return <ConfigurationRequired />
  if (access === 'loading') return <div className="auth-screen"><LoadingBlock label="Admin sessiyasi tekshirilmoqda…" /></div>
  if (access === 'authorized') return <Navigate to="/admin" replace />
  return <LoginPage />
}

function ProtectedAdmin() {
  const { access, userName } = useAdminAccess()
  const { pushToast } = useToast()
  const navigate = useNavigate()
  const [unreadCount, setUnreadCount] = useState(0)

  const refreshUnread = async () => {
    if (!supabase) return
    const { count, error } = await supabase.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null)
    if (!error) setUnreadCount(count ?? 0)
  }

  useEffect(() => {
    if (access === 'authorized') void refreshUnread()
  }, [access])

  useEffect(() => {
    if (!supabase || access !== 'authorized') return
    const client = supabase
    const channel = client.channel('admin-notifications-live')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications' }, (payload) => {
        const row = payload.new as { title?: string; message?: string; data?: Record<string, unknown> }
        setUnreadCount((count) => count + 1)
        window.dispatchEvent(new Event('admin-notification-changed'))
        pushToast({
          title: row.title || 'Yangi bildirishnoma',
          message: row.message,
          tone: 'info',
          action: () => {
            const booking = row.data?.booking_id
            navigate(booking ? `/admin/bookings?open=${booking}` : '/admin/notifications')
          },
        })
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'bookings' }, () => {
        window.dispatchEvent(new Event('admin-booking-changed'))
        void refreshUnread()
      })
      .subscribe()
    return () => { void client.removeChannel(channel) }
  }, [access, navigate, pushToast])

  const signOut = async () => {
    if (!supabase) return
    const { error } = await supabase.auth.signOut()
    if (error) pushToast({ title: 'Tizimdan chiqib bo‘lmadi', message: errorMessage(error), tone: 'error' })
    else navigate('/admin/login', { replace: true })
  }

  if (!isSupabaseConfigured) return <ConfigurationRequired />
  if (access === 'loading') return <div className="auth-screen"><LoadingBlock label="Xavfsiz kirish tekshirilmoqda…" /></div>
  if (access === 'unauthenticated') return <Navigate to="/admin/login" replace />
  if (access === 'unauthorized') return <UnauthorizedPage onSignOut={signOut} />

  return (
    <ErrorBoundary title="Admin panel yuklanmadi" description="Ishlash jarayonidagi xatolik panelni to‘xtatdi. Tizimga kirish muvaffaqiyatli bo‘ldi, ammo sahifa yuklanmadi.">
      <AdminShell userName={userName} unreadCount={unreadCount} onSignOut={signOut}>
        <AdminRoutes onUnreadChanged={refreshUnread} />
      </AdminShell>
    </ErrorBoundary>
  )
}

function AdminRoutes({ onUnreadChanged }: { onUnreadChanged: () => void }) {
  return (
    <Routes>
      <Route index element={<DashboardPage />} />
      <Route path="bookings" element={<BookingsPage />} />
      <Route path="calendar" element={<CalendarPage />} />
      <Route path="customers" element={<CustomersPage />} />
      <Route path="services" element={<ServicesPage />} />
      <Route path="categories" element={<CategoriesPage />} />
      <Route path="barbers" element={<BarbersPage />} />
      <Route path="schedules" element={<SchedulesPage />} />
      <Route path="reviews" element={<ReviewsPage />} />
      <Route path="gallery" element={<GalleryPage />} />
      <Route path="promotions" element={<PromotionsPage />} />
      <Route path="analytics" element={<AnalyticsPage />} />
      <Route path="notifications" element={<NotificationsPage onUnreadChanged={onUnreadChanged} />} />
      <Route path="settings" element={<SettingsPage />} />
      <Route path="activity-log" element={<ActivityLogPage />} />
      <Route path="*" element={<Navigate to="/admin" replace />} />
    </Routes>
  )
}

function LoginPage() {
  const { pushToast } = useToast()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!email.trim() || !password) {
      pushToast({ title: 'Email va parolni kiriting', tone: 'error' })
      return
    }
    setBusy(true)
    const { error } = await getSupabase().auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (error) pushToast({ title: 'Kirish muvaffaqiyatsiz', message: 'Ma’lumotlaringizni tekshirib, qayta urinib ko‘ring.', tone: 'error' })
    else pushToast({ title: 'Tizimga kirildi', tone: 'success' })
  }
  return (
    <div className="auth-screen">
      <form className="login-card" onSubmit={(event) => void submit(event)}>
        <div className="login-mark"><ShieldCheck size={26} /></div>
        <p className="eyebrow">Xavfsiz kirish</p>
        <h1>Admin paneli</h1>
        <p>Administrator roli mavjud hisob bilan kiring. Ommaviy admin ro‘yxatdan o‘tish yo‘q.</p>
        {location.state?.message && <div className="inline-info">{String(location.state.message)}</div>}
        <label className="field"><span className="field-label">Email</span><input className="input" autoComplete="email" type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
        <label className="field"><span className="field-label">Parol</span><input className="input" autoComplete="current-password" type="password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
        <Button type="submit" disabled={busy}>{busy ? 'Kirilmoqda…' : <><LogIn size={17} /> Kirish</>}</Button>
        <small>Sessiyaga kirish va har bir so‘rov alohida tekshiriladi.</small>
      </form>
    </div>
  )
}

function UnauthorizedPage({ onSignOut }: { onSignOut: () => Promise<void> }) {
  return (
    <div className="auth-screen">
      <div className="login-card unauthorized-card">
        <div className="login-mark warning"><AlertTriangle size={26} /></div>
        <p className="eyebrow">Kirish rad etildi</p>
        <h1>Bu hisob administrator emas</h1>
        <p>Panel himoyalangan ma’lumotlarni yuklamadi. Rolni tekshirish uchun loyiha administratoriga murojaat qiling.</p>
        <Button onClick={() => void onSignOut()}>Chiqish</Button>
      </div>
    </div>
  )
}

function ConfigurationRequired() {
  return (
    <div className="auth-screen">
      <div className="login-card unauthorized-card">
        <div className="login-mark warning"><LockKeyhole size={26} /></div>
        <p className="eyebrow">Admin paneli</p>
        <h1>Supabase sozlamalari yoki autentifikatsiya talab qilinadi.</h1>
        <p>Xosting muhitida brauzer uchun xavfsiz <code>VITE_SUPABASE_URL</code> va <code>VITE_SUPABASE_ANON_KEY</code> qiymatlarini qo‘shing, so‘ng administrator hisobi bilan kiring. Bu ilovaga hech qachon service role kalitini qo‘shmang.</p>
      </div>
    </div>
  )
}
