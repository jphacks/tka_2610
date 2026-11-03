import { useState } from 'react'
import { useGenerateMemo, useUpdateArtwork } from '../api'
import { Sheet } from './Sheet'
import { useToast } from './Toast'

/** AI の下書きと保存済みメモを分け、保存操作までは元のメモを変えない。 */
export function ArtworkMemo({ artworkId, memo }: { artworkId: string; memo: string }) {
  const generate = useGenerateMemo(artworkId)
  const update = useUpdateArtwork(artworkId)
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [draft, setDraft] = useState('')
  const [error, setError] = useState('')
  const busy = generate.isPending || update.isPending

  const start = () => {
    setDraft(memo)
    setError('')
    setOpen(true)
  }

  return (
    <>
      <div className="memory-note">
        <span className="memory-note-label">メモ</span>
        {memo && <p>{memo}</p>}
        <button type="button" className="btn btn-plain btn-small" onClick={start}>
          {memo ? 'メモを編集・AIで下書きをつくる' : 'メモを書く・AIで下書きをつくる'}
        </button>
      </div>
      <Sheet open={open} title="作品のメモ" onClose={() => { if (!busy) setOpen(false) }}>
        <div className="sheet-body">
          <p className="hint">作品をもとに、あればおもいでの写真と音声も参考にします。生成時にこれらをGoogleのGemini APIへ送ります。動画は使いません。</p>
          <button type="button" className="btn btn-outline" disabled={busy} onClick={async () => {
            setError('')
            try {
              const result = await generate.mutateAsync()
              setDraft(result.memo)
            } catch (e) {
              setError(e instanceof Error ? e.message : '下書きを作れませんでした')
            }
          }}>
            {generate.isPending ? '下書きをつくっています…' : 'AIで下書きをつくる'}
          </button>
          {memo && <p className="hint">保存中のメモ：{memo}</p>}
          <label htmlFor={`memo-draft-${artworkId}`}>メモの下書き</label>
          <textarea id={`memo-draft-${artworkId}`} className="input" rows={6} maxLength={500}
            value={draft} disabled={busy} onChange={(e) => setDraft(e.target.value)} />
          <p className="hint">内容を確認して自由に直せます。「保存する」を押すまで、作品のメモは変わりません。</p>
          {error && <p role="alert">{error}</p>}
          <button type="button" className="btn btn-filled" disabled={busy} onClick={async () => {
            setError('')
            const form = new FormData()
            form.set('memo', draft)
            try {
              await update.mutateAsync(form)
              setOpen(false)
              toast('メモを保存しました')
            } catch (e) {
              setError(e instanceof Error ? e.message : '保存できませんでした')
            }
          }}>{update.isPending ? '保存しています…' : '保存する'}</button>
          <button type="button" className="btn btn-gray" disabled={busy} onClick={() => setOpen(false)}>キャンセル</button>
        </div>
      </Sheet>
    </>
  )
}
