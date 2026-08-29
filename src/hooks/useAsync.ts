import { useCallback, useEffect, useState } from 'react'

export type AsyncState<T> = {
  data: T | null
  loading: boolean
  error: string | null
}

export function useAsyncData<T>(loader: () => Promise<T>, dependencies: unknown[] = []) {
  const [state, setState] = useState<AsyncState<T>>({ data: null, loading: true, error: null })

  const reload = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: null }))
    try {
      const data = await loader()
      setState({ data, loading: false, error: null })
    } catch (error) {
      setState({ data: null, loading: false, error: error instanceof Error ? error.message : 'Ma’lumotlarni yuklab bo‘lmadi.' })
    }
    // loaders are purposefully supplied by the page that owns its dependencies.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, dependencies)

  useEffect(() => {
    void reload()
  }, [reload])

  return { ...state, reload }
}
