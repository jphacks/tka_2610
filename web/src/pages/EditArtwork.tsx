// ⑨ 作品を編集（/artworks/:id/edit）。モーダルで下から開く。
// フォームは ③ 作品を追加と共通（components/ArtworkForm.tsx）。
import { useParams } from 'react-router-dom'
import { useArtwork, useUpdateArtwork } from '../api'
import { ArtworkForm, Busy, NavBar, Screen, useToast } from '../components'
import { useNav } from '../nav'

export default function EditArtwork() {
  const { id = '' } = useParams()
  const detail = useArtwork(id)
  const update = useUpdateArtwork(id)
  const nav = useNav()
  const toast = useToast()
  const artwork = detail.data?.artwork

  return (
    <Screen>
      <NavBar
        title="作品を編集"
        left={
          <button className="btn-plain" onClick={() => nav.dismiss(`/artworks/${id}`)}>
            キャンセル
          </button>
        }
      />
      <div className="page" style={{ paddingTop: 6 }}>
        {artwork ? (
          <ArtworkForm
            key={artwork.id}
            variant="edit"
            initial={artwork}
            submitLabel="保存する"
            busy={update.isPending}
            error={update.error?.message}
            onSubmit={(form) =>
              update.mutate(form, {
                onSuccess: () => {
                  toast('作品を更新しました')
                  nav.dismiss(`/artworks/${id}`)
                },
              })
            }
          />
        ) : detail.isError ? (
          <div className="empty">作品が見つかりませんでした。</div>
        ) : (
          <div className="photo-picker skeleton" />
        )}
      </div>
      {update.isPending && <Busy label="保存しています" />}
    </Screen>
  )
}
