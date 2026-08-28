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
  { to: '/admin', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/admin/bookings', label: 'Bookings', icon: BookOpenCheck },
  { to: '/admin/calendar', label: 'Calendar', icon: CalendarDays },
  { to: '/admin/customers', label: 'Customers', icon: Users },
  { to: '/admin/services', label: 'Services', icon: Scissors },
  { to: '/admin/categories', label: 'Categories', icon: Tags },
  { to: '/admin/barbers', label: 'Barbers', icon: Users },
  { to: '/admin/schedules', label: 'Schedules', icon: Clock3 },
  { to: '/admin/reviews', label: 'Reviews', icon: Sparkles },
  { to: '/admin/gallery', label: 'Gallery', icon: GalleryVerticalEnd },
  { to: '/admin/promotions', label: 'Promotions', icon: FolderKanban },
  { to: '/admin/analytics', label: 'Analytics', icon: BarChart3 },
  { to: '/admin/notifications', label: 'Notifications', icon: Bell },
  { to: '/admin/settings', label: 'Settings', icon: Settings2 },
  { to: '/admin/activity-log', label: 'Activity log', icon: ClipboardList },
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
          <NavLink className="brand" to="/admin" aria-label="Admin dashboard"><span className="brand-mark">✦</span><span className="brand-name">Workspace</span></NavLink>
          <button className="icon-button mobile-close" onClick={() => setMobileOpen(false)} aria-label="Close navigation"><X size={20}/></button>
        </div>
        <p className="sidebar-caption">Management</p>
        <nav className="nav-list" aria-label="Admin navigation">
          {navigation.map(({ to, label, icon: Icon, end }) => (
            <NavLink key={to} to={to} end={end} className={({ isActive }) => `nav-item ${isActive ? 'nav-active' : ''}`} title={collapsed ? label : undefined}>
              <Icon size={19} strokeWidth={1.8}/><span>{label}</span>
              {label === 'Notifications' && unreadCount > 0 && <b className="nav-count">{unreadCount > 99 ? '99+' : unreadCount}</b>}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-foot">
          <button className="collapse-button" onClick={() => setCollapsed((value) => !value)} aria-label="Toggle compact navigation">
            {collapsed ? <ChevronRight size={18}/> : <ChevronLeft size={18}/>}<span>Collapse</span>
          </button>
          <div className="security-note"><ShieldAlert size={16}/><span>Database access is protected by RLS.</span></div>
        </div>
      </aside>
      <main className="main-area">
        <header className="topbar">
          <button className="icon-button menu-button" onClick={() => setMobileOpen(true)} aria-label="Open navigation"><Menu size={21}/></button>
          <div className="topbar-date"><span>Today</span><strong>{formatDate(new Date().toISOString())}</strong></div>
          <div className="topbar-actions">
            <NavLink to="/admin/notifications" className="notification-button" aria-label="Notifications"><Bell size={19}/>{unreadCount > 0 && <b>{unreadCount > 9 ? '9+' : unreadCount}</b>}</NavLink>
            <div className="profile-chip"><span className="profile-avatar">{userName.slice(0, 1).toUpperCase()}</span><span><small>Signed in as</small><strong>{userName}</strong></span></div>
            <Button className="signout-button" onClick={() => void onSignOut()}><LogOut size={16}/> <span>Sign out</span></Button>
          </div>
        </header>
        <div className="page-content">{children}</div>
      </main>
    </div>
  )
}
