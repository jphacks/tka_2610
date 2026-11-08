// ② ホーム（/）。タブ。
// 年齢（3さい・4さい・5さい…）のチップを選ぶと、その年齢のときに作った作品を飾る「おへや」が、1 階から積み重なった建物の 3D で出る（StackScene）。
// 建物の階か、その下の「1かい」「2かい」のボタンを押すと、そのおへや（/rooms/:id）へ入る。「おへやを足す」でいちばん上に階が増える。
// いちばん上の階に作品を飾っていなければ、「〇〇を消す」で消せる（確かめのシートを出す。作品のある階や途中の階はサーバーが断る）。
// 選んだ年齢は URL の ?age= に入れる（おへやから戻ったときに同じ年齢を出す）。はじめは今の年齢（作品のある年齢）を選ぶ。
// 年齢は、設定の子どもの誕生日と作品の作成日から Rust が決める（/api/ages）。誕生日が無いときは、設定へ進む案内を出す。
import { Suspense, useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAddRoom, useAgeStack, useAges, useDeleteRoom, type AgeStack } from '../api'
import { NavBar, Screen, Sheet, StageFallback, TLink, useToast } from '../components'
import { PlusIcon } from '../icons'
import { useNav } from '../nav'
import { StackScene, StageShell, warmUp3D } from '../three'
import './Home.css'

export default function Home() {
  const ages = useAges()
  const nav = useNav()
  const toast = useToast()
  const addRoom = useAddRoom()
  const deleteRoom = useDeleteRoom()
  const [params, setParams] = useSearchParams()
  const [displayedStack, setDisplayedStack] = useState<AgeStack | null>(null)
  const [showLoading, setShowLoading] = useState(false)
  // 「〇〇を消す」の確かめのシート
  const [confirmRemove, setConfirmRemove] = useState(false)

  const data = ages.data
  // 選んでいる年齢：?age= があればそれ、無ければ今の年齢、それも無ければ作品のあるいちばん大きい年齢
  const ageParam = params.get('age')
  const fromUrl = ageParam !== null && ageParam.trim() !== '' ? Number(ageParam) : null
  const list = data?.ages ?? []
  const selected =
    list.find((a) => a.age === fromUrl) ??
    list.find((a) => a.age === data?.current_age && a.artwork_count > 0) ??
    [...list].reverse().find((a) => a.artwork_count > 0) ??
    list[list.length - 1] ??
    null
  const stack = useAgeStack(selected?.age ?? null, true)
  // 次のおへやは別レイヤーで準備し、準備完了までは前のCanvasを残す。
  const candidate = !stack.isPlaceholderData && stack.data?.age === selected?.age ? stack.data : undefined
  const layers = displayedStack && displayedStack.age !== candidate?.age
    ? [displayedStack, ...(candidate ? [candidate] : [])]
    : candidate ? [candidate] : displayedStack ? [displayedStack] : []
  const rooms = selected?.rooms ?? []
  const loading = ages.isPending || (!!selected && rooms.length > 0 &&
    (stack.isPlaceholderData || !stack.data || displayedStack?.age !== selected.age))
  // 消せるのは、作品を飾っていないいちばん上の階だけ
  const top = rooms[rooms.length - 1]
  const removable = top && top.count === 0 ? top : null
  const initial = (data?.name ?? 'は').slice(0, 1)

  // 建物の GLB を先に読んでおく（どの階も同じ建物）
  useEffect(() => {
    if (stack.data) warmUp3D(stack.data.house.rooms.flatMap((r) => (r.model_url ? [r.model_url] : [])))
  }, [stack.data])
  // すぐ表示できる場合は点滅させず、待ち時間がある場合だけ案内する。
  useEffect(() => {
    setShowLoading(false)
    if (!loading || stack.isError) return
    const timer = window.setTimeout(() => setShowLoading(true), 250)
    return () => window.clearTimeout(timer)
  }, [loading, selected?.age, stack.isError])

  const choose = (age: number) => setParams({ age: String(age) }, { replace: true })
  const enter = (roomId: string) => nav.push(`/rooms/${roomId}`)
  const add = () => {
    if (!selected) return
    addRoom.mutate(selected.age, {
      onSuccess: (room) => toast(`${room.name}を足しました`),
      onError: (e) => toast(e.message),
    })
  }
  const remove = () => {
    if (!removable) return
    deleteRoom.mutate(removable.id, {
      onSuccess: () => {
        setConfirmRemove(false)
        toast(`${removable.name}を消しました`)
      },
      onError: (e) => toast(e.message),
    })
  }

  return (
    <Screen tabbar className="home-screen">
      <NavBar
        title={data?.name ?? 'はるのミュージアム'}
        right={
          <TLink to="/settings" kind="tab" className="avatar" aria-label="マイページ">
            {initial}
          </TLink>
        }
      />

      {data && !data.child_birthday && (
        <TLink to="/settings" kind="tab" className="home-notice">
          お誕生日を設定すると、作った年齢ごとにおへやを分けられます
        </TLink>
      )}

      <div className="age-chips" role="tablist" aria-label="年齢">
        {list.map((a) => (
          <button
            key={a.age}
            type="button"
            role="tab"
            aria-selected={a.age === selected?.age}
            className={`age-chip${a.age === selected?.age ? ' selected' : ''}`}
            onClick={() => choose(a.age)}
          >
            {a.label}
          </button>
        ))}
      </div>

      <StageShell
        className="home-stage"
        ready={true}
        overlay={
          <>
            {showLoading && loading && !stack.isError && !ages.isError && (
              <div className="home-loading" role="status" aria-live="polite">
                <StageFallback label="Loading…" />
              </div>
            )}
            {(stack.isError || ages.isError) ? (
              <div className="home-empty" role="alert">
                <p>おへやを読み込めませんでした</p>
                <button type="button" className="btn btn-outline" onClick={() => { void ages.refetch(); void stack.refetch() }}>もう一度読み込む</button>
              </div>
            ) : rooms.length === 0 && selected && (
              <div className="home-empty">{selected.label}のおへやは、まだありません</div>
            )}
          </>
        }
      >
        {rooms.length > 0 && layers.map(layer => (
          <div key={layer.age} className="home-stack-layer"
            style={{ visibility: layer.age === displayedStack?.age ? 'visible' : 'hidden' }}
            aria-hidden={layer.age !== displayedStack?.age}>
            <Suspense fallback={null}>
              <StackScene stack={layer}
                onRoom={!loading && !stack.isError && layer.age === selected?.age ? enter : undefined}
                onReady={() => setDisplayedStack(layer)} />
            </Suspense>
          </div>
        ))}
      </StageShell>

      <div className="home-actions">
        {rooms.length > 1 && (
          <>
            <div className="home-floors">
              {[...rooms].reverse().map((room) => (
                <button key={room.id} type="button" className="home-floor" disabled={loading || stack.isError} onClick={() => enter(room.id)}>
                  {room.floor + 1}かい
                  <small className="num">{room.count}</small>
                </button>
              ))}
            </div>
          </>
        )}
        <div className="home-buttons">
          {selected && (
            <button type="button" className="btn btn-outline home-add" disabled={addRoom.isPending || loading || stack.isError} onClick={add}>
              <PlusIcon size={17} strokeWidth={2.2} />
              {rooms.length === 0 ? 'おへやをつくる' : 'おへやを足す'}
            </button>
          )}
        </div>
        {removable && (
          <button type="button" className="btn btn-plain home-remove" disabled={loading || stack.isError} onClick={() => setConfirmRemove(true)}>
            {removable.name}を消す
          </button>
        )}
      </div>

      <Sheet open={confirmRemove && !!removable} onClose={() => setConfirmRemove(false)} title={`${removable?.name ?? ''}を消しますか？`}>
        <p className="hint" style={{ textAlign: 'center', margin: '4px 8px 0' }}>
          置いてある家具とテーマも消えます。作品は飾っていないので、作品はそのまま残ります。
        </p>
        <div className="sheet-body">
          <button className="btn btn-destructive" disabled={deleteRoom.isPending} onClick={remove}>
            おへやを消す
          </button>
          <button className="btn btn-gray" onClick={() => setConfirmRemove(false)}>
            キャンセル
          </button>
        </div>
      </Sheet>
    </Screen>
  )
}
