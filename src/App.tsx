import { AlertTriangle, LockKeyhole, LogIn, ShieldCheck } from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { AdminShell } from './components/AdminShell'
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
  return <ToastProvider><AdminRouter/></ToastProvider>
}

function AdminRouter() {
  const [session, setSession] = useState<Session | null>(null)
  const [access, setAccess] = useState<AccessState>('loading')
  const [userName, setUserName] = useState('Administrator')
  const [unreadCount, setUnreadCount] = useState(0)
  const { pushToast } = useToast()
  const navigate = useNavigate()

  const refreshUnread = async () => {
    if (!supabase) return
    const { count, error } = await supabase.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null)
    if (!error) setUnreadCount(count ?? 0)
  }

  useEffect(() => {
    if (!supabase) { setAccess('unauthenticated'); return }
    let mounted = true
    const verify = async (candidate: Session | null) => {
      if (!mounted) return
      setSession(candidate)
      if (!candidate) { setAccess('unauthenticated'); return }
      setAccess('loading')
      const [roleResult, profileResult] = await Promise.all([
        getSupabase().rpc('is_admin'),
        getSupabase().from('profiles').select('full_name').eq('id', candidate.user.id).maybeSingle(),
      ])
      if (!mounted) return
      if (roleResult.error || roleResult.data !== true) { setAccess('unauthorized'); return }
      setUserName(profileResult.data?.full_name || candidate.user.email || 'Administrator')
      setAccess('authorized')
      void refreshUnread()
    }
    void getSupabase().auth.getSession().then(({ data }) => verify(data.session))
    const { data: listener } = getSupabase().auth.onAuthStateChange((event, nextSession) => {
      if (event === 'SIGNED_OUT' || event === 'TOKEN_REFRESHED' || event === 'SIGNED_IN' || event === 'INITIAL_SESSION') void verify(nextSession)
    })
    return () => { mounted = false; listener.subscription.unsubscribe() }
  }, [])

  useEffect(() => {
    if (!supabase || access !== 'authorized') return
    const client = supabase
    const channel = client.channel('admin-notifications-live')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications' }, (payload) => {
        const row = payload.new as { title?: string; message?: string; data?: Record<string, unknown> }
        setUnreadCount((count) => count + 1)
        window.dispatchEvent(new Event('admin-notification-changed'))
        pushToast({ title: row.title || 'New notification', message: row.message, tone: 'info', action: () => { const booking = row.data?.booking_id; navigate(booking ? `/admin/bookings?open=${booking}` : '/admin/notifications') } })
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'bookings' }, () => {
        // RLS has already authorized the event. Pages listen for this signal and
        // refresh their bounded query without polling.
        window.dispatchEvent(new Event('admin-booking-changed'))
        void refreshUnread()
      })
      .subscribe()
    return () => { void client.removeChannel(channel) }
  }, [access, navigate, pushToast])

  const signOut = async () => { if (!supabase) return; const { error } = await supabase.auth.signOut(); if (error) pushToast({ title: 'Could not sign out', message: errorMessage(error), tone: 'error' }); else navigate('/admin/login', { replace: true }) }

  if (!isSupabaseConfigured) return <ConfigurationRequired/>
  if (access === 'loading') return <div className="auth-screen"><LoadingBlock label="Verifying secure admin access…"/></div>
  return <Routes>
    <Route path="/admin/login" element={access === 'authorized' ? <Navigate to="/admin" replace/> : <LoginPage onSignedIn={() => undefined}/>}/>
    <Route path="/admin/*" element={access === 'unauthenticated' ? <Navigate to="/admin/login" replace/> : access === 'unauthorized' ? <UnauthorizedPage onSignOut={signOut}/> : <AdminShell userName={userName} unreadCount={unreadCount} onSignOut={signOut}><AdminRoutes onUnreadChanged={refreshUnread}/></AdminShell>}/>
    <Route path="*" element={<Navigate to="/admin" replace/>}/>
  </Routes>
}

function AdminRoutes({ onUnreadChanged }: { onUnreadChanged: () => void }) { return <Routes><Route index element={<DashboardPage/>}/><Route path="bookings" element={<BookingsPage/>}/><Route path="calendar" element={<CalendarPage/>}/><Route path="customers" element={<CustomersPage/>}/><Route path="services" element={<ServicesPage/>}/><Route path="categories" element={<CategoriesPage/>}/><Route path="barbers" element={<BarbersPage/>}/><Route path="schedules" element={<SchedulesPage/>}/><Route path="reviews" element={<ReviewsPage/>}/><Route path="gallery" element={<GalleryPage/>}/><Route path="promotions" element={<PromotionsPage/>}/><Route path="analytics" element={<AnalyticsPage/>}/><Route path="notifications" element={<NotificationsPage onUnreadChanged={onUnreadChanged}/>}/><Route path="settings" element={<SettingsPage/>}/><Route path="activity-log" element={<ActivityLogPage/>}/><Route path="*" element={<Navigate to="/admin" replace/>}/></Routes> }

function LoginPage({ onSignedIn }: { onSignedIn: () => void }) { const { pushToast } = useToast(); const location = useLocation(); const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [busy, setBusy] = useState(false); const submit = async (event: FormEvent) => { event.preventDefault(); if (!email.trim() || !password) { pushToast({ title: 'Enter email and password', tone: 'error' }); return } setBusy(true); const { error } = await getSupabase().auth.signInWithPassword({ email: email.trim(), password }); setBusy(false); if (error) pushToast({ title: 'Sign in failed', message: 'Check your credentials and try again.', tone: 'error' }); else { onSignedIn(); pushToast({ title: 'Signed in', tone: 'success' }) } }; return <div className="auth-screen"><form className="login-card" onSubmit={(event) => void submit(event)}><div className="login-mark"><ShieldCheck size={26}/></div><p className="eyebrow">Secure access</p><h1>Admin workspace</h1><p>Sign in with an account that has the administrator role. There is no public admin registration.</p>{location.state?.message && <div className="inline-info">{String(location.state.message)}</div>}<label className="field"><span className="field-label">Email</span><input className="input" autoComplete="email" type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label><label className="field"><span className="field-label">Password</span><input className="input" autoComplete="current-password" type="password" value={password} onChange={(event) => setPassword(event.target.value)} /></label><Button type="submit" disabled={busy}>{busy ? 'Signing in…' : <><LogIn size={17}/> Sign in</>}</Button><small>Session access and every database request are independently verified.</small></form></div> }

function UnauthorizedPage({ onSignOut }: { onSignOut: () => Promise<void> }) { return <div className="auth-screen"><div className="login-card unauthorized-card"><div className="login-mark warning"><AlertTriangle size={26}/></div><p className="eyebrow">Access denied</p><h1>This account is not an administrator</h1><p>The dashboard has not loaded any protected data. Ask an existing project administrator to verify your role assignment.</p><Button onClick={() => void onSignOut()}>Sign out</Button></div></div> }
function ConfigurationRequired() { return <div className="auth-screen"><div className="login-card unauthorized-card"><div className="login-mark warning"><LockKeyhole size={26}/></div><p className="eyebrow">Configuration required</p><h1>Connect Supabase first</h1><p>Add browser-safe <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> values to a local <code>.env</code> file. Never add a service role key to this application.</p></div></div> }
