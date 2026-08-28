export function formatCurrency(value: number | string | null | undefined, currency = ''): string {
  const amount = Number(value ?? 0)
  if (currency && /^[A-Z]{3}$/.test(currency)) {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency, maximumFractionDigits: 2 }).format(amount)
  }
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(amount)
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return '—'
  const parsed = new Date(`${value.length === 10 ? `${value}T00:00:00` : value}`)
  return Number.isNaN(parsed.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(parsed)
}

export function formatDateTime(value: string | null | undefined): string {
  if (!value) return '—'
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(parsed)
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

export function errorMessage(error: unknown, fallback = 'Something went wrong. Please try again.'): string {
  if (error && typeof error === 'object' && 'message' in error && typeof error.message === 'string') {
    const message = error.message
    if (message.includes('23P01') || /overlap|not available|slot was just taken/i.test(message)) return 'This time slot was just taken. Refresh availability and choose another time.'
    if (/duplicate key|unique constraint/i.test(message)) return 'A record with this value already exists. Choose a different value.'
    if (/foreign key|still referenced/i.test(message)) return 'This item is still used by other records. Archive or deactivate it instead.'
    if (/permission|not authorized|row-level security/i.test(message)) return 'Your account is not authorized for this action.'
    // Application RPCs intentionally raise short, human-readable validation
    // messages. Do not surface unexpected driver/SQL errors to the user.
    if (message.length < 180 && !/sql|postgres|relation|column|syntax/i.test(message)) return message
  }
  return fallback
}
