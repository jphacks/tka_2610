// おへや（/rooms/:roomId）。ホームで年齢を選び、積み上げの建物の階を押すと push で開く。
// 画面いっぱいの 3D のおへや（HomeScene）。はじめはおへやの中を壁の上から見下ろす近景で、ドラッグで見回せて、放っておくとゆっくり回る。
// 作品をタップすると ⑥ 作品の詳細へ。
// 3D の上に浮かぶ UI は 2 段だけ：上に戻るボタンとおへやの名前、下に飾っている数と「歩く」（⑪ 鑑賞モード）・「模様替え」（⑫）の丸いボタン。
// どちらもこのおへやを ?room= で渡す。
import { Suspense, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useAgeStack, useAges, useMuseum } from '../api'
import { GlassButton, Screen, Sheet } from '../components'
import { BackIcon, ChevronRight, SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { HomeScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './Room.css'

export default function Room() {
  const { roomId = '', floor } = useParams()
  const all = floor !== undefined
  const viewId = all ? `all-${floor}` : roomId
  const museum = useMuseum({ roomId, allFloor: floor })
  const allStack = useAgeStack(all ? 'all' : null)
  const nav = useNav()
  const [readyRoomId, setReadyRoomId] = useState<string | null>(null)
  const [pickerOpen, setPickerOpen] = useState(false)
  const ages = useAges()
  const titleButton = useRef<HTMLButtonElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  const closePicker = () => {
    setPickerOpen(false)
    titleButton.current?.focus()
  }
  useEffect(() => {
    if (!pickerOpen) return
    const focusFrame = requestAnimationFrame(() => closeButton.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        setPickerOpen(false)
        titleButton.current?.focus()
      }
      if (event.key === 'Tab') {
        const buttons = closeButton.current?.closest('.sheet')?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')
        if (!buttons?.length) return
        const first = buttons[0]
        const last = buttons[buttons.length - 1]
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault()
          last.focus()
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      cancelAnimationFrame(focusFrame)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [pickerOpen])

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  const data = museum.data
  const room = data?.room
  const back = all ? '/home?age=all' : room ? `/home?age=${room.age}` : '/home'

  return (
    <Screen className="room-screen">
      <StageShell
        className="room-stage"
        ready={readyRoomId === viewId || (!!data && !hasHouseModel(data)) || museum.isError}
        overlay={
          <>
            <div className="stage-top room-top">
              <GlassButton label="戻る" onClick={() => nav.back(back)}>
                <BackIcon size={20} strokeWidth={2.2} />
              </GlassButton>
              {room && (
                <button ref={titleButton} type="button" className="stage-title glass room-title"
                  aria-label={`${room.name}。おへやを切り替える`} aria-haspopup="dialog"
                  aria-expanded={pickerOpen} onClick={() => setPickerOpen(true)}>
                  <span>{room.name}</span><ChevronRight size={16} />
                </button>
              )}
            </div>
            <div className="room-dock">
              {data && (
                <p className="room-status glass">
                  <span className="num">{data.displayed_count}</span>点を飾っています
                </p>
              )}
              <div className="room-actions">
                <GlassButton label="歩く" className="room-action" onClick={() => nav.push(all ? `/museum/walk?all_floor=${floor}` : `/museum/walk?room=${roomId}`)}>
                  <WalkIcon size={21} />
                </GlassButton>
                {!all && <GlassButton label="模様替え" className="room-action" onClick={() => nav.push(`/home/edit?room=${roomId}`)}>
                  <SofaIcon size={21} />
                </GlassButton>}
              </div>
            </div>
          </>
        }
      >
        {data && (
          <Suspense fallback={null}>
            <HomeScene key={viewId} museum={data} onSelect={(id) => nav.push(`/artworks/${id}`)} onReady={() => setReadyRoomId(viewId)} />
          </Suspense>
        )}
        {data && !hasHouseModel(data) && <div className="stage-fallback">家の 3D モデル (GLB) が見つかりません</div>}
        {museum.isError && <div className="stage-fallback">このおへやは見つかりません</div>}
      </StageShell>
      <Sheet open={pickerOpen} onClose={closePicker} title="おへやをえらぶ">
        <div className="room-picker-list">
          {all ? (
            allStack.isError ? <div role="alert"><p>おへやを読み込めませんでした</p><button type="button" className="btn btn-outline" onClick={() => allStack.refetch()}>もう一度読み込む</button></div> :
            allStack.isPending ? <p role="status">Loading…</p> :
            <div className="room-picker-floors">
              {allStack.data.rooms.map(({ room: target }) => (
                <button key={target.id} type="button" className="room-picker-floor"
                  aria-current={target.floor === Number(floor) ? 'location' : undefined}
                  onClick={() => { closePicker(); if (target.floor !== Number(floor)) nav.replace(`/rooms/all/${target.floor}`, 'fade') }}>
                  {target.floor + 1}かい
                </button>
              ))}
            </div>
          ) : ages.isPending ? <p role="status">Loading…</p> : ages.isError ? (
            <div role="alert"><p>おへやを読み込めませんでした</p>
              <button type="button" className="btn btn-outline" onClick={() => ages.refetch()}>もう一度読み込む</button>
            </div>
          ) : (
            <>
              {ages.data.ages.filter(age => age.rooms.length > 0).map(age => (
                <section key={age.age} className="room-picker-age" aria-label={age.label}>
                  <h4>{age.label}</h4>
                  <div className="room-picker-floors">
                    {age.rooms.map(target => (
                      <button key={target.id} type="button" className="room-picker-floor"
                        aria-label={`${target.name}、${target.floor + 1}かい${target.id === roomId ? '、いまのおへや' : ''}`}
                        aria-current={target.id === roomId ? 'location' : undefined}
                        onClick={() => {
                          closePicker()
                          if (target.id !== roomId) nav.replace(`/rooms/${target.id}`, 'fade')
                        }}>
                        <span>{target.floor + 1}かい</span>
                      </button>
                    ))}
                  </div>
                </section>
              ))}
              {!ages.data.ages.some(age => age.rooms.length > 0) && <p>おへやはまだありません</p>}
            </>
          )}
        </div>
        <button ref={closeButton} type="button" autoFocus className="btn btn-gray room-picker-close" onClick={closePicker}>閉じる</button>
      </Sheet>
    </Screen>
  )
}
