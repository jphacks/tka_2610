// 子の描画中に起きたエラーを受け止めて、代わりに fallback を表示する。
// 3D の読み込み失敗（GLB が見つからない・壊れている、3D のコードを読み込めない）を画面に出すのに使う。
// fallback の retry を呼ぶと、もう一度子を描画し直す。
import { Component, type ReactNode } from 'react'

interface Props {
  fallback: (error: Error, retry: () => void) => ReactNode
  children: ReactNode
}

export class ErrorBoundary extends Component<Props, { error: Error | null }> {
  state = { error: null as Error | null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  retry = () => this.setState({ error: null })

  render() {
    return this.state.error ? this.props.fallback(this.state.error, this.retry) : this.props.children
  }
}
