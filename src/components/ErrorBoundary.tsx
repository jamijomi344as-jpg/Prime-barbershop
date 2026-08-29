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
          <p className="eyebrow">Runtime error</p>
          <h1>{this.props.title || 'Something went wrong'}</h1>
          <p>{this.props.description || 'The interface could not render. Reload the page or sign in again.'}</p>
          <p className="muted">{this.state.error.message}</p>
          <button className="button" type="button" onClick={() => this.setState({ error: null })}>
            Try again
          </button>
        </div>
      </div>
    )
  }
}
