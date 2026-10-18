// ② ホーム（/）。タブ。
// 年齢（3さい・4さい・5さい…）のチップを選ぶと、その年齢のときに作った作品を飾る「おへや」が、1 階から積み重なった建物の 3D で出る（StackScene）。
// 建物の階か、その下の「1かい」「2かい」のボタン（おへやが 1 つなら「はいる」）を押すと、そのおへや（/rooms/:id）へ入る。「おへやを足す」でいちばん上に階が増える。
// いちばん上の階に作品を飾っていなければ、「〇〇を消す」で消せる（確かめのシートを出す。作品のある階や途中の階はサーバーが断る）。
// 上の名前（「はるのミュージアム」）を押すと、名前を変えるシートが出る（設定の museum_name。マイページのプロフィールでも変えられる）。
// 選んだ年齢は URL の ?age= に入れる（おへやから戻ったときに同じ年齢を出す）。はじめは今の年齢（作品のある年齢）を選ぶ。
// 年齢は、設定の子どもの誕生日と作品の作成日から Rust が決める（/api/ages）。誕生日が無いときは、設定へ進む案内を出す。
import { Suspense, useEffect, useState, type FormEvent } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAddRoom, useAgeStack, useAges, useDeleteRoom, useSettings, useUpdateSettings } from '../api'
import { InviteSheet, NavBar, Screen, Sheet, TLink, useToast } from '../components'
import { HomeIcon, PencilIcon, PlusIcon } from '../icons'
import { useNav } from '../nav'
import { StackScene, StageShell, warmUp3D } from '../three'
import './Home.css'

export default function Home() {
  const ages = useAges()
  const nav = useNav()
  const toast = useToast()
  const addRoom = useAddRoom()
  const deleteRoom = useDeleteRoom()
  const [params] = useSearchParams()
  const [ready, setReady] = useState(false)
  // テスト用の招待状のシート
  const [showInvite, setShowInvite] = useState(false)
  // 「〇〇を消す」の確かめのシート
  const [confirmRemove, setConfirmRemove] = useState(false)
  // 名前（「はるのミュージアム」）を変えるシート。タイトルを押すと開く
  const [renaming, setRenaming] = useState(false)
  const settings = useSettings()
  const updateSettings = useUpdateSettings()

  const data = ages.data
  // 選んでいる年齢：?age= があればそれ、無ければ今の年齢、それも無ければ作品のあるいちばん大きい年齢
  const fromUrl = Number(params.get('age'))
  const list = data?.ages ?? []
  const selected =
    list.find((a) => a.age === fromUrl) ??
    list.find((a) => a.age === data?.current_age && a.artwork_count > 0) ??
    [...list].reverse().find((a) => a.artwork_count > 0) ??
    list[list.length - 1] ??
    null
  const stack = useAgeStack(selected?.age ?? null)
  const rooms = selected?.rooms ?? []
  // 消せるのは、作品を飾っていないいちばん上の階だけ
  const top = rooms[rooms.length - 1]
  const removable = top && top.count === 0 ? top : null
  const initial = (data?.name ?? 'は').slice(0, 1)

  // 建物の GLB を先に読んでおく（どの階も同じ建物）
  useEffect(() => {
    if (stack.data) warmUp3D(stack.data.house.rooms.flatMap((r) => (r.model_url ? [r.model_url] : [])))
  }, [stack.data])
  // 年齢を変えたら、新しい建物を描き終わるまで「準備しています…」を出す
  useEffect(() => setReady(false), [selected?.age])

  const choose = (age: number) => nav.replace(`/?age=${age}`, 'fade')
  const enter = (roomId: string) => nav.push(`/rooms/${roomId}`)
  const add = () => {
    if (!selected) return
    addRoom.mutate(selected.age, {
      onSuccess: (room) => toast(`${room.name}を足しました`),
      onError: (e) => toast(e.message),
    })
  }
  const rename = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (!settings.data) return
    const name = String(new FormData(e.currentTarget).get('museum_name') ?? '')
    // 生年月日は送らない（省くと今のまま）
    updateSettings.mutate(
      { museum_name: name, owner_name: settings.data.owner_name },
      {
        onSuccess: (s) => {
          setRenaming(false)
          toast(`「${s.museum_name}」にしました`)
        },
      },
    )
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
        large
        title={
          <button type="button" className="home-title" onClick={() => setRenaming(true)} aria-label="名前を変える">
            {data?.name ?? 'はるのミュージアム'}
            <PencilIcon size={16} className="home-title-pencil" />
          </button>
        }
        right={
          <TLink to="/settings" kind="tab" className="avatar" aria-label="マイページ">
            {initial}
          </TLink>
        }
      />

      {data && !data.child_birthday && (
        <TLink to="/settings" kind="tab" className="home-notice">
          子どもの生年月日を設定すると、作った年齢ごとにおへやを分けられます
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
            {a.age === selected?.age && <HomeIcon size={17} />}
            {a.label}
          </button>
        ))}
      </div>

      {selected && (
        <div className="home-heading">
          <span className="home-heading-name">{selected.label}のおへや</span>
          <span className="home-heading-count num">{selected.displayed_count}</span>
          {selected.artwork_count > selected.displayed_count && (
            <span className="home-heading-stored">しまってある {selected.artwork_count - selected.displayed_count}</span>
          )}
        </div>
      )}

      <StageShell
        className="home-stage"
        ready={ready || rooms.length === 0 || stack.isError}
        overlay={
          rooms.length === 0 &&
          selected && <div className="home-empty">{selected.label}のおへやは、まだありません</div>
        }
      >
        {stack.data && stack.data.age === selected?.age && stack.data.rooms.length > 0 && (
          <Suspense fallback={null}>
            <StackScene key={stack.data.age} stack={stack.data} onRoom={enter} onReady={() => setReady(true)} />
          </Suspense>
        )}
      </StageShell>

      <div className="home-actions">
        {rooms.length > 1 && (
          <>
            <div className="home-floors">
              {[...rooms].reverse().map((room) => (
                <button key={room.id} type="button" className="home-floor" onClick={() => enter(room.id)}>
                  {room.floor + 1}かい
                  <small className="num">{room.count}</small>
                </button>
              ))}
            </div>
            <p className="home-hint">階を押すと、中に入れます</p>
          </>
        )}
        <div className="home-buttons">
          {rooms.length === 1 && (
            <button type="button" className="btn btn-filled home-enter" onClick={() => enter(rooms[0].id)}>
              はいる
            </button>
          )}
          {selected && (
            <button type="button" className="btn btn-outline home-add" disabled={addRoom.isPending} onClick={add}>
              <PlusIcon size={17} strokeWidth={2.2} />
              {rooms.length === 0 ? 'おへやをつくる' : 'おへやを足す'}
            </button>
          )}
        </div>
        {removable && (
          <button type="button" className="btn btn-plain home-remove" onClick={() => setConfirmRemove(true)}>
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

      <Sheet open={renaming && !!settings.data} onClose={() => setRenaming(false)} title="名前を変える">
        {settings.data && (
          <form className="sheet-body form" onSubmit={rename}>
            <div className="field">
              <label htmlFor="home_museum_name">memoriaの名前</label>
              <input
                id="home_museum_name"
                name="museum_name"
                className="input"
                maxLength={30}
                defaultValue={settings.data.museum_name}
                placeholder="例）はるのミュージアム"
                required
              />
            </div>
            {updateSettings.error && <div className="form-error">{updateSettings.error.message}</div>}
            <button className="btn btn-filled" disabled={updateSettings.isPending}>
              保存
            </button>
          </form>
        )}
      </Sheet>

      {/* テスト用：画面の右上に出す「招待状を開く」ボタン */}
      <div style={{ position: 'fixed', top: 10, right: 10, zIndex: 1000 }}>
        <button
          onClick={() => setShowInvite(true)}
          style={{ background: '#fff', padding: '6px 12px', borderRadius: '8px', border: '1px solid #ccc', cursor: 'pointer', boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }}
        >
          💌 招待状を見る
        </button>
      </div>
      <InviteSheet Open={showInvite} onClose={() => setShowInvite(false)} />
    </Screen>
  )
}
