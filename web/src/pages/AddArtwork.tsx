// ③ 作品を追加（/add）。モーダルで下から開く。
// 登録が終わると ④ 3D プレビューへ進む。
import { useEffect } from 'react'
import { useCreateArtwork, useMuseum } from '../api'
import { ArtworkForm, Busy, NavBar, Screen } from '../components'
import { useNav } from '../nav'
import { shellUrlsOf, warmUp3D } from '../three'

export default function AddArtwork() {
  const nav = useNav()
  const create = useCreateArtwork()
  const museum = useMuseum()

  // 入力している間に 3D の準備をしておき、次のプレビュー画面をすぐ出す
  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data))
  }, [museum.data])

  return (
    <Screen>
      <NavBar
        title="作品を追加"
        left={
          <button className="btn-plain" onClick={() => nav.dismiss('/')}>
            キャンセル
          </button>
        }
      />
      <div className="page" style={{ paddingTop: 6 }}>
        <ArtworkForm
          variant="add"
          submitLabel="作品を登録する"
          busy={create.isPending}
          error={create.error?.message}
          onSubmit={(form) =>
            create.mutate(form, {
              onSuccess: (artwork) => {
                warmUp3D(null, [artwork.model_url])
                nav.replace(`/artworks/${artwork.id}/preview`, 'fade')
              },
            })
          }
        />
      </div>
      {create.isPending && <Busy label="写真から3Dを作っています" />}
    </Screen>
  )
}
