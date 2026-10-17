import { Sheet } from './Sheet'
import './InviteSheet.css'

interface InviteSheetProps {
  Open: boolean
  onClose: () => void
}

export function InviteSheet({ Open, onClose }: InviteSheetProps) {
  // チーム確認用のダミーURL
  const dummyUrl = `${window.location.origin}/museum?invite=demo`

  const handleCopy = () => {
    navigator.clipboard.writeText(dummyUrl)
    alert('招待リンクをコピーしました！（モック）')
  }

  return (
    <Sheet open={Open} onClose={onClose}>
      <div className="invite-card-wrapper">
        {/* 上部のメッセージ */}
        <div className="invite-header-text">
          <h2>私たちのアトリエにようこそ</h2>
          <p>
            はるのミュージアムへようこそ。<br />
            大切な家族の思い出の品々を、<br />
            一つひとつ大切に並べました。<br />
            どうぞ、ゆっくりとご覧ください。
          </p>
        </div>

        {/* おうちのプレビュー画像部分 */}
        <div className="invite-image-frame">
          {/* 画像を差し込む場所（publicフォルダ等に画像を置くか、仮の背景にできます） */}
          <div className="invite-house-art"></div>
        </div>

        {/* 「ここに見に来てね」ボタン */}
        <button type="button" className="invite-visit-btn" onClick={handleCopy}>
          <span className="icon">🏠</span> ここに見に来てね
        </button>

        {/* URL表示 */}
        <div className="invite-url-text">
          {dummyUrl}
        </div>

        {/* QRコード風の案内 */}
        <div className="invite-qr-section">
          <span className="qr-label">QRコードでアクセス</span>
          {/* ダミーのQRコード枠（実際のQR画像を貼ることも可能です） */}
          <div className="invite-qr-box">
            <div className="dummy-qr-grid"></div>
          </div>
        </div>
      </div>
    </Sheet>
  )
}