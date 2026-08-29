import { getSupabase } from './supabase'

const ASSET_BUCKET = 'business-assets'
const MAX_ASSET_BYTES = 10 * 1024 * 1024
const ACCEPTED_IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/svg+xml']

export async function uploadBusinessAsset(folder: 'logos' | 'favicons' | 'hero' | 'barbers' | 'services' | 'gallery', file: File): Promise<string> {
  if (!ACCEPTED_IMAGE_TYPES.includes(file.type)) throw new Error('JPEG, PNG, WebP, AVIF yoki SVG rasmni tanlang.')
  if (file.size > MAX_ASSET_BYTES) throw new Error('Rasm hajmi 10 MB dan oshmasligi kerak.')

  const extension = file.name.split('.').pop()?.toLowerCase() || 'image'
  const path = `${folder}/${crypto.randomUUID()}.${extension}`
  const client = getSupabase()
  const { error } = await client.storage.from(ASSET_BUCKET).upload(path, file, {
    cacheControl: '31536000',
    upsert: false,
    contentType: file.type,
  })
  if (error) throw error
  return path
}

export function assetUrl(path: string | null | undefined): string | undefined {
  if (!path) return undefined
  return getSupabase().storage.from(ASSET_BUCKET).getPublicUrl(path).data.publicUrl
}

export async function removeBusinessAsset(path: string | null | undefined) {
  if (!path) return
  const { error } = await getSupabase().storage.from(ASSET_BUCKET).remove([path])
  if (error) throw error
}
