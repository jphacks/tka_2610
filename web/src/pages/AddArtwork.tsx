// ③ 作品を追加（/add）。モーダルで下から開く。
// 登録が終わると ④ 3D プレビューへ進む。登録した作品はサーバーが、作ったときの年齢のおへやに飾る
// （空きが無ければ家具を足して。それでも飾れなければ飾っていないまま。プレビューの「おうちに飾る」が残る）。
import { useEffect } from 'react'
import { useCreateArtwork, useMuseum } from '../api'
import { ArtworkForm, Busy, NavBar, Screen, useToast } from '../components'
import { useNav } from '../nav'
import { shellUrlsOf, warmUp3D, warmUpArtwork } from '../three'

export default function AddArtwork() {
  const nav = useNav()
  const create = useCreateArtwork()
  const museum = useMuseum()
  const toast = useToast()

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
                warmUpArtwork(artwork.model_url)
                if (artwork.displayed) toast(`${artwork.room_name ?? 'おうち'}に飾りました`)
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
