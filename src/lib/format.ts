export function formatCurrency(value: number | string | null | undefined, currency = ''): string {
  const amount = Number(value ?? 0)
  if (currency && /^[A-Z]{3}$/.test(currency)) {
    return new Intl.NumberFormat('uz', { style: 'currency', currency, maximumFractionDigits: 2 }).format(amount)
  }
  return new Intl.NumberFormat('uz', { maximumFractionDigits: 2 }).format(amount)
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return '—'
  const parsed = new Date(`${value.length === 10 ? `${value}T00:00:00` : value}`)
  return Number.isNaN(parsed.getTime())
    ? value
    : new Intl.DateTimeFormat('uz', { dateStyle: 'medium' }).format(parsed)
}

export function formatDateTime(value: string | null | undefined): string {
  if (!value) return '—'
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime())
    ? value
    : new Intl.DateTimeFormat('uz', { dateStyle: 'medium', timeStyle: 'short' }).format(parsed)
}

export function formatTime(value: string | null | undefined): string {
  if (!value) return '—'
  return value.slice(0, 5)
}

export function dateInputValue(date = new Date()): string {
  const offset = date.getTimezoneOffset()
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 10)
}

export function humanize(value: string): string {
  return value.replace(/[._-]/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

const STATUS_LABELS: Record<string, string> = {
  active: 'Faol',
  inactive: 'Nofaol',
  archived: 'Arxivlangan',
  open: 'Ochiq',
  closed: 'Yopiq',
  pending: 'Kutilmoqda',
  approved: 'Tasdiqlangan',
  rejected: 'Rad etilgan',
  hidden: 'Yashirin',
  confirmed: 'Tasdiqlangan',
  completed: 'Yakunlangan',
  cancelled: 'Bekor qilingan',
  canceled: 'Bekor qilingan',
  no_show: 'Kelmaslik',
  upcoming: 'Yaqinlashmoqda',
}

export function localizeStatus(value: string): string {
  return STATUS_LABELS[value.toLowerCase()] ?? value
}

export function errorMessage(error: unknown, fallback = 'Nimadir xato ketdi. Qayta urinib ko‘ring.'): string {
  if (error && typeof error === 'object' && 'message' in error && typeof error.message === 'string') {
    const message = error.message
    if (message.includes('23P01') || /overlap|not available|slot was just taken|band qilindi/i.test(message)) return 'Bu vaqt hozirgina band qilindi. Mavjudlikni yangilab, boshqa vaqtni tanlang.'
    if (/duplicate key|unique constraint/i.test(message)) return 'Bu qiymatga ega yozuv allaqachon mavjud. Boshqa qiymatni tanlang.'
    if (/foreign key|still referenced/i.test(message)) return 'Bu element boshqa yozuvlarda hali ham ishlatilmoqda. O‘rniga uni arxivlang yoki o‘chiring.'
    if (/permission|not authorized|row-level security/i.test(message)) return 'Sizning hisobingiz bu amalni bajarishga ruxsatga ega emas.'
    // Application RPCs intentionally raise short, human-readable validation
    // messages. Do not surface unexpected driver/SQL errors to the user.
    if (message.length < 180 && !/sql|postgres|relation|column|syntax/i.test(message)) return message
  }
  return fallback
}
