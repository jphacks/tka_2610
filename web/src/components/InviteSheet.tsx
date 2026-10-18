
import { Sheet } from './Sheet'
import { QRCodeSVG } from 'qrcode.react'
import './InviteSheet.css'

interface InviteSheetProps {
  Open: boolean
  onClose: () => void
}

export function InviteSheet({ Open, onClose }: InviteSheetProps) {
  // 招待先のURL
  const inviteUrl = `${window.location.origin}/museum?invite=demo`

  const handleCopy = async () => {
     try {
       await navigator.clipboard.writeText(inviteUrl)
       alert('招待リンクをコピーしました！')
     } catch {
       window.prompt('この招待リンクをコピーしてください', inviteUrl)
     }
   }

  return (
    <Sheet open={Open} onClose={onClose}>
      <div className="invite-card-wrapper">
        {/* 上部の水彩風イラスト */}
        <div className="invite-sky" aria-hidden="true">
          <div className="invite-blue-paint" />
          <div className="invite-rainbow">
            <span />
            <span />
            <span />
            <span />
            <span />
          </div>
          <span className="invite-sky-star">✿</span>
        </div>

        {/* 招待メッセージ */}
        <header className="invite-header-text">
          <h2>
            あなたを、わたしの
            <br />
            memoriaにご招待します
          </h2>

          <p>
            子どもが作った作品や、たくさんの思い出を
            <br />
            デジタルの空間に飾りました。
            <br />
            ぜひ、見にきてください。
          </p>
        </header>

        {/* 手描き風の装飾 */}
        <span className="invite-spark invite-spark-left" aria-hidden="true">
          ✳
        </span>
        <span className="invite-spark invite-spark-right" aria-hidden="true">
          ✳
        </span>

        {/* QRコードと手描き風の案内 */}
        <section className="invite-qr-layout">
          <div className="invite-side-note invite-side-note-left">
            <span>
              スマホのカメラで
              <br />
              こちらのQRコードを
              <br />
              読み取ってね！
              <br />
              ☺
            </span>
          </div>

          <button
            type="button"
            className="invite-qr-frame"
            onClick={handleCopy}
            aria-label="招待リンクをコピー"
            title="クリックして招待リンクをコピー"
          >
            <div className="invite-qr-paper">
              <QRCodeSVG
                value={inviteUrl}
                size={148}
                level="H"
                bgColor="#ffffff"
                fgColor="#365b75"
                marginSize={1}
              />
            </div>
          </button>

          <div className="invite-side-note invite-side-note-right">
            <span>
              家族みんなで
              <br />
              見にきてね！
              <br />
              ♡
            </span>
          </div>
        </section>

        {/* URLコピー */}
        <button
          type="button"
          className="invite-copy-btn"
          onClick={handleCopy}
        >
          <span aria-hidden="true">♡</span>
          招待リンクをコピー
        </button>

        {/* ブランドロゴ風の文字 */}
        <footer className="invite-footer">
          <h3>memoria</h3>
          <p>作品と一緒に、思い出も残す。</p>
          <span className="invite-footer-underline" />
        </footer>

        {/* 下部の家・草原・花のイラスト */}
        <div className="invite-garden" aria-hidden="true">
          <div className="invite-house">
            <div className="invite-house-roof" />
            <div className="invite-house-body">
              <div className="invite-house-window">✳</div>
              <div className="invite-house-door" />
            </div>
          </div>

          <span className="invite-flower invite-flower-one">🌼</span>
          <span className="invite-flower invite-flower-two">🌷</span>
          <span className="invite-flower invite-flower-three">🌻</span>
          <span className="invite-flower invite-flower-four">🌸</span>

          <div className="invite-grass" />
        </div>
      </div>
    </Sheet>
  )
}
