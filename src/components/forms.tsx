import { ImagePlus, LoaderCircle, UploadCloud } from 'lucide-react'
import { useRef, useState, type InputHTMLAttributes, type ReactNode, type TextareaHTMLAttributes } from 'react'
import { assetUrl, uploadBusinessAsset } from '../lib/db'

export function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return <label className="field"><span className="field-label">{label}</span>{children}{hint && <small className="field-hint">{hint}</small>}</label>
}

export function TextInput(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input className="input" {...props}/>
}

export function TextArea({ className = '', ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={`input textarea ${className}`} {...props}/>
}

export function Toggle({ checked, onChange, label, description }: { checked: boolean; onChange: (checked: boolean) => void; label: string; description?: string }) {
  return <label className="toggle-row"><span><strong>{label}</strong>{description && <small>{description}</small>}</span><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)}/><i aria-hidden="true"/></label>
}

export function ImageUpload({ folder, value, onChange, label = 'Rasm' }: { folder: 'logos' | 'favicons' | 'hero' | 'barbers' | 'services' | 'gallery'; value: string | null; onChange: (path: string | null) => void; label?: string }) {
  const input = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const preview = value ? assetUrl(value) : undefined
  const selectFile = async (file?: File) => {
    if (!file) return
    setBusy(true); setError(null)
    try { onChange(await uploadBusinessAsset(folder, file)) }
    catch (reason) { setError(reason instanceof Error ? reason.message : 'Yuklashda xatolik yuz berdi.') }
    finally { setBusy(false); if (input.current) input.current.value = '' }
  }

  return <div className="field image-upload"><span className="field-label">{label}</span>
    <div className="image-upload-row">
      <button type="button" className="image-preview" onClick={() => input.current?.click()} aria-label={`${label.toLowerCase()} yuklash`}>
        {preview ? <img src={preview} alt="Tanlangan"/> : <ImagePlus size={24}/>} {busy && <span className="image-loading"><LoaderCircle className="spin" size={18}/></span>}
      </button>
      <div><button type="button" className="button button-secondary" disabled={busy} onClick={() => input.current?.click()}><UploadCloud size={16}/>{busy ? 'Yuklanmoqda…' : 'Rasm yuklash'}</button>
      {value && <button type="button" className="text-button danger-text" onClick={() => onChange(null)}>Havolani olib tashlash</button>}
      <small className="field-hint">JPEG, PNG, WebP, AVIF yoki SVG · maksimal 10 MB</small></div>
    </div>
    <input ref={input} type="file" accept="image/jpeg,image/png,image/webp,image/avif,image/svg+xml" hidden onChange={(event) => void selectFile(event.target.files?.[0])}/>
    {error && <small className="field-error">{error}</small>}
  </div>
}
