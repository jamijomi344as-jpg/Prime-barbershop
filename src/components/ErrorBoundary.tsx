import { Component, type ErrorInfo, type ReactNode } from 'react'

type Props = { children: ReactNode; title?: string; description?: string }
type State = { error: Error | null }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Application error boundary', error, info.componentStack)
  }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <div className="auth-screen">
        <div className="login-card unauthorized-card">
          <p className="eyebrow">Ishlash xatosi</p>
          <h1>{this.props.title || 'Nimadir xato ketdi'}</h1>
          <p>{this.props.description || 'Interfeys yuklanmadi. Sahifani yangilang yoki qayta kiring.'}</p>
          <p className="muted">{this.state.error.message}</p>
          <button className="button" type="button" onClick={() => this.setState({ error: null })}>
            Qayta urinish
          </button>
        </div>
      </div>
    )
  }
}
