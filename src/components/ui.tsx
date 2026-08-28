import { AlertCircle, CheckCircle2, LoaderCircle, X } from 'lucide-react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ButtonHTMLAttributes, type PropsWithChildren, type ReactNode } from 'react'

export function Button({ className = '', children, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button className={`button ${className}`} {...props}>{children}</button>
}

export function SecondaryButton({ className = '', children, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button className={`button button-secondary ${className}`} {...props}>{children}</button>
}

type Toast = { id: number; title: string; message?: string; tone?: 'success' | 'error' | 'info'; action?: () => void }
type ToastContextValue = { pushToast: (toast: Omit<Toast, 'id'>) => void }
const ToastContext = createContext<ToastContextValue | null>(null)

export function ToastProvider({ children }: PropsWithChildren) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const pushToast = useCallback((toast: Omit<Toast, 'id'>) => {
    const id = Date.now() + Math.floor(Math.random() * 1000)
    setToasts((current) => [...current, { ...toast, id }])
    window.setTimeout(() => setToasts((current) => current.filter((item) => item.id !== id)), 5000)
  }, [])
  const value = useMemo(() => ({ pushToast }), [pushToast])

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div className="toast-stack" aria-live="polite">
        {toasts.map((toast) => (
          <button key={toast.id} className={`toast toast-${toast.tone ?? 'info'}`} onClick={toast.action}>
            {toast.tone === 'error' ? <AlertCircle size={18} /> : <CheckCircle2 size={18} />}
            <span><strong>{toast.title}</strong>{toast.message && <small>{toast.message}</small>}</span>
            <X size={16} onClick={(event) => { event.stopPropagation(); setToasts((current) => current.filter((item) => item.id !== toast.id)) }} />
          </button>
        ))}
      </div>
    </ToastContext.Provider>
  )
}

export function useToast() {
  const context = useContext(ToastContext)
  if (!context) throw new Error('useToast must be used inside ToastProvider')
  return context
}

export function Modal({ title, children, onClose, wide = false }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  const dialog = useRef<HTMLElement>(null)
  useEffect(() => {
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    dialog.current?.focus()
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', closeOnEscape)
    return () => { document.body.style.overflow = previousOverflow; window.removeEventListener('keydown', closeOnEscape) }
  }, [onClose])
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section ref={dialog} tabIndex={-1} className={`modal ${wide ? 'modal-wide' : ''}`} role="dialog" aria-modal="true" aria-label={title} onMouseDown={(event) => event.stopPropagation()}>
        <header className="modal-header"><h2>{title}</h2><button type="button" className="icon-button" onClick={onClose} aria-label="Close dialog"><X size={20} /></button></header>
        <div className="modal-body">{children}</div>
      </section>
    </div>
  )
}

export function PageHeader({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return <div className="page-header"><div><p className="eyebrow">Admin workspace</p><h1>{title}</h1>{description && <p>{description}</p>}</div>{action && <div className="page-action">{action}</div>}</div>
}

export function LoadingBlock({ label = 'Loading data…' }: { label?: string }) {
  return <div className="loading-block"><LoaderCircle className="spin" size={22} /> {label}</div>
}

export function EmptyState({ title, description, action }: { title: string; description: string; action?: ReactNode }) {
  return <div className="empty-state"><div className="empty-mark">✦</div><h3>{title}</h3><p>{description}</p>{action}</div>
}

export function ErrorState({ message, retry }: { message: string; retry?: () => void }) {
  return <div className="error-state"><AlertCircle size={20}/><div><strong>Unable to load this section</strong><p>{message}</p></div>{retry && <SecondaryButton onClick={retry}>Try again</SecondaryButton>}</div>
}

export function StatusPill({ value }: { value: string }) {
  const tone = value.toLowerCase().replace(/[_ ]/g, '-')
  return <span className={`status status-${tone}`}>{value.replace(/_/g, ' ')}</span>
}

export function ConfirmAction({ title, description, confirmLabel = 'Confirm', onConfirm, children }: { title: string; description: string; confirmLabel?: string; onConfirm: () => Promise<void> | void; children: (open: () => void) => ReactNode }) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    try { await onConfirm(); setOpen(false) } finally { setBusy(false) }
  }
  return <>
    {children(() => setOpen(true))}
    {open && <Modal title={title} onClose={() => !busy && setOpen(false)}><p className="modal-copy">{description}</p><div className="form-actions"><SecondaryButton disabled={busy} onClick={() => setOpen(false)}>Keep it</SecondaryButton><Button className="button-danger" disabled={busy} onClick={() => void run()}>{busy ? 'Working…' : confirmLabel}</Button></div></Modal>}
  </>
}
