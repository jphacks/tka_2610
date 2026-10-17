// ⑦ おへやの一覧（/map）。タブ（「ミュージアム」）。
// 年齢ごとに、その年齢のときに作った作品を飾る「おへや」を並べる（1 階から）。行を押すと、そのおへや（/rooms/:id）へ入る。
// 作品の数・おへやは /api/ages（Rust が子どもの誕生日と作品の作成日から年齢を決める）。
// 年齢の見出しの「ホームで見る」で、② ホームのその年齢の積み上げの建物へ。
import { useAges } from '../api'
import { Img, NavBar, Screen } from '../components'
import { ChevronRight, MuseumIcon } from '../icons'
import { useNav } from '../nav'
import './MapView.css'

export default function MapView() {
  const ages = useAges()
  const nav = useNav()
  const list = ages.data?.ages ?? []

  return (
    <Screen tabbar>
      <NavBar large title={ages.data?.name ?? 'はるのミュージアム'} />

      <div className="page">
        {ages.isError && <p className="note">おへやを読み込めませんでした</p>}
        {[...list].reverse().map((age) => (
          <section key={age.age} className="age-section">
            <div className="section-head">
              <h2>
                {age.label}
                <small className="age-count num">
                  {age.displayed_count} / {age.artwork_count} 点
                </small>
              </h2>
              <button className="btn-plain" onClick={() => nav.tab(`/?age=${age.age}`)}>
                ホームで見る
              </button>
            </div>
            <div className="list-group" style={{ marginTop: 0 }}>
              {age.rooms.length === 0 && <p className="list-empty">まだおへやがありません。ホームの「おへやをつくる」で作れます</p>}
              {age.rooms.map((room) => (
                <button key={room.id} className="list-item room-row" onClick={() => nav.push(`/rooms/${room.id}`)}>
                  {room.thumbs[0] ? (
                    <Img src={room.thumbs[0]} tint={room.tint ?? undefined} alt="" />
                  ) : (
                    <div className="thumb">
                      <MuseumIcon size={22} />
                    </div>
                  )}
                  <span className="grow">
                    <div className="name">{room.name}</div>
                    <div className="desc">{room.floor + 1} 階</div>
                  </span>
                  <span className="detail num">
                    {room.count} / {room.capacity}
                  </span>
                  <ChevronRight size={16} strokeWidth={2.2} className="chev" />
                </button>
              ))}
            </div>
          </section>
        ))}
        <p className="note">作品は、作ったときの年齢のおへやの、空いている棚や机の上に自動で飾られます。</p>
      </div>
    </Screen>
  )
}
