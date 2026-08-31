import {
  BarChart3, Bell, BookOpenCheck, CalendarDays, ChevronLeft, ChevronRight, ClipboardList,
  Clock3, FolderKanban, GalleryVerticalEnd, LayoutDashboard, LogOut, Menu, Scissors,
  Settings2, ShieldAlert, Sparkles, Tags, Users, X,
} from 'lucide-react'
import { useEffect, useState, type ReactNode } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { formatDate } from '../lib/format'
import { Button } from './ui'

const navigation = [
  { to: '/admin', label: 'Boshqaruv', icon: LayoutDashboard, end: true },
  { to: '/admin/bookings', label: 'Bronlar', icon: BookOpenCheck },
  { to: '/admin/calendar', label: 'Kalendar', icon: CalendarDays },
  { to: '/admin/customers', label: 'Mijozlar', icon: Users },
  { to: '/admin/services', label: 'Xizmatlar', icon: Scissors },
  { to: '/admin/categories', label: 'Kategoriyalar', icon: Tags },
  { to: '/admin/barbers', label: 'Sartaroshlar', icon: Users },
  { to: '/admin/schedules', label: 'Jadvallar', icon: Clock3 },
  { to: '/admin/reviews', label: 'Sharhlar', icon: Sparkles },
  { to: '/admin/gallery', label: 'Galereya', icon: GalleryVerticalEnd },
  { to: '/admin/promotions', label: 'Aksiyalar', icon: FolderKanban },
  { to: '/admin/analytics', label: 'Tahlillar', icon: BarChart3 },
  { to: '/admin/notifications', label: 'Bildirishnomalar', icon: Bell },
  { to: '/admin/settings', label: 'Sozlamalar', icon: Settings2 },
  { to: '/admin/activity-log', label: 'Faoliyat jurnali', icon: ClipboardList },
]

export function AdminShell({ children, userName, unreadCount, onSignOut }: { children: ReactNode; userName: string; unreadCount: number; onSignOut: () => Promise<void> }) {
  const [mobileOpen, setMobileOpen] = useState(false)
  const [collapsed, setCollapsed] = useState(false)
  const location = useLocation()

  useEffect(() => { setMobileOpen(false) }, [location.pathname])

  return (
    <div className={`admin-shell ${collapsed ? 'sidebar-collapsed' : ''}`}>
      {mobileOpen && <div className="mobile-scrim" onClick={() => setMobileOpen(false)} />}
      <aside className={`sidebar ${mobileOpen ? 'sidebar-open' : ''}`}>
        <div className="brand-row">
          <NavLink className="brand" to="/admin" aria-label="Boshqaruv paneli"><span className="brand-mark">✦</span><span className="brand-name">Boshqaruv</span></NavLink>
          <button className="icon-button mobile-close" onClick={() => setMobileOpen(false)} aria-label="Navigatsiyani yopish"><X size={20}/></button>
        </div>
        <p className="sidebar-caption">Boshqaruv</p>
        <nav className="nav-list" aria-label="Admin navigatsiyasi">
          {navigation.map(({ to, label, icon: Icon, end }) => (
            <NavLink key={to} to={to} end={end} className={({ isActive }) => `nav-item ${isActive ? 'nav-active' : ''}`} title={collapsed ? label : undefined}>
              <Icon size={19} strokeWidth={1.8}/><span>{label}</span>
              {label === 'Bildirishnomalar' && unreadCount > 0 && <b className="nav-count">{unreadCount > 99 ? '99+' : unreadCount}</b>}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-foot">
          <button className="collapse-button" onClick={() => setCollapsed((value) => !value)} aria-label="Yig‘ilgan navigatsiyani almashtirish">
            {collapsed ? <ChevronRight size={18}/> : <ChevronLeft size={18}/>}<span>Yig‘ish</span>
          </button>
          <div className="security-note"><ShieldAlert size={16}/><span>Ma’lumotlaringiz xavfsiz saqlanadi.</span></div>
        </div>
      </aside>
      <main className="main-area">
        <header className="topbar">
          <button className="icon-button menu-button" onClick={() => setMobileOpen(true)} aria-label="Navigatsiyani ochish"><Menu size={21}/></button>
          <div className="topbar-date"><span>Bugun</span><strong>{formatDate(new Date().toISOString())}</strong></div>
          <div className="topbar-actions">
            <NavLink to="/admin/notifications" className="notification-button" aria-label="Bildirishnomalar"><Bell size={19}/>{unreadCount > 0 && <b>{unreadCount > 9 ? '9+' : unreadCount}</b>}</NavLink>
            <div className="profile-chip"><span className="profile-avatar">{userName.slice(0, 1).toUpperCase()}</span><span><small>Tizimga kirgan</small><strong>{userName}</strong></span></div>
            <Button className="signout-button" onClick={() => void onSignOut()}><LogOut size={16}/> <span>Chiqish</span></Button>
          </div>
        </header>
        <div className="page-content">{children}</div>
      </main>
    </div>
  )
}
