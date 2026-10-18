// ⑩ 設定（/settings）。タブ。iOS の設定アプリ風。
import { useState, type FormEvent, type ReactNode } from 'react'
import { useAges, useSettings, useUpdateSettings } from '../api'
import { InviteSheet, NavBar, Screen, Sheet, useToast } from '../components'
import { BellIcon, ChevronRight, DocIcon, FamilyIcon, HelpIcon, HomeIcon, MuseumIcon, PersonIcon } from '../icons'
import './Settings.css'

function Row({
  icon,
  label,
  detail,
  onClick,
}: {
  icon: ReactNode
  label: string
  detail?: string
  onClick: () => void
}) {
  return (
    <button className="list-item" onClick={onClick}>
      <span className="list-icon">{icon}</span>
      <span className="grow">{label}</span>
      {detail && <span className="detail">{detail}</span>}
      <ChevronRight size={16} strokeWidth={2.2} className="chev" />
    </button>
  )
}

/** "2021-06-01" → "2021年6月1日" */
const birthdayLabel = (date: string) => {
  const [y, m, d] = date.split('-').map(Number)
  return `${y}年${m}月${d}日`
}

/** 今日（ローカルの日付）。誕生日の入力の上限 */
const today = () => {
  const now = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

export default function Settings() {
  const settings = useSettings()
  const ages = useAges()
  const update = useUpdateSettings()
  const toast = useToast()
  const [editing, setEditing] = useState(false)
  const [inviting, setInviting] = useState(false)   

  const owner = settings.data?.owner_name ?? ''
  const birthday = settings.data?.child_birthday ?? null
  const displayed = ages.data?.ages.reduce((n, a) => n + a.displayed_count, 0) ?? 0
  const roomCount = ages.data?.ages.reduce((n, a) => n + a.rooms.length, 0) ?? 0
  const soon = () => toast('この機能は準備中です')

  const save = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const data = new FormData(e.currentTarget)
    const nextBirthday = String(data.get('child_birthday') ?? '')
    update.mutate(
      {
        museum_name: String(data.get('museum_name') ?? ''),
        owner_name: String(data.get('owner_name') ?? ''),
        // 空なら今のまま（消すことはできない）
        ...(nextBirthday ? { child_birthday: nextBirthday } : {}),
      },
      {
        onSuccess: () => {
          setEditing(false)
          // 誕生日が変わると、作品は作ったときの年齢のおへやへ移る（サーバーが置き直す）
          toast(nextBirthday && nextBirthday !== birthday ? 'お誕生日を変えて、作品をおへやに分け直しました' : 'プロフィールを保存しました')
        },
      },
    )
  }


  return (
    <Screen tabbar>
      <NavBar large title="設定" />
      <div className="page">
        <div className="list-group" style={{ marginTop: 6 }}>
          <button className="list-item profile-row" onClick={() => setEditing(true)}>
            <span className="avatar large">{owner.slice(0, 1) || '?'}</span>
            <span className="grow">
              <div className="who">{owner || ' '}</div>
              <div className="sub">プロフィール・博物館の名前</div>
            </span>
            <ChevronRight size={16} strokeWidth={2.2} className="chev" />
          </button>
          <Row
            icon={<MuseumIcon size={18} />}
            label="おうち"
            detail={ages.data ? `おへや ${roomCount}・${displayed} 点を飾っています` : undefined}
            onClick={() => setEditing(true)}
          />
          <Row
            icon={<HomeIcon size={18} />}
            label="お誕生日"
            detail={birthday ? birthdayLabel(birthday) : '未設定'}
            onClick={() => setEditing(true)}
          />
        </div>

        <div className="list-group">
          <Row icon={<PersonIcon size={18} />} label="プロフィール編集" onClick={() => setEditing(true)} />
          <Row icon={<FamilyIcon size={18} />} label="家族の管理" onClick={soon} />
          <Row icon={<BellIcon size={18} />} label="通知設定" onClick={soon} />
          <Row icon={<BellIcon size={18} />} label="招待状発行" onClick={() => setInviting(true)} />
        </div>

        <div className="list-group">
          <Row icon={<HelpIcon size={18} />} label="ヘルプ・よくある質問" onClick={soon} />
          <Row icon={<DocIcon size={18} />} label="利用規約・プライバシーポリシー" onClick={soon} />
        </div>

        <div className="list-group">
          <button className="list-item logout" onClick={() => toast('ログイン機能は準備中です')}>
            ログアウト
          </button>
        </div>
      </div>

      <Sheet open={editing && !!settings.data} onClose={() => setEditing(false)} title="プロフィール">
        {settings.data && (
          <form className="sheet-body form" onSubmit={save}>
            <div className="field">
              <label htmlFor="owner_name">あなたの名前</label>
              <input id="owner_name" name="owner_name" className="input" maxLength={30} defaultValue={settings.data.owner_name} required />
            </div>
            <div className="field">
              <label htmlFor="child_birthday">子どものお誕生日</label>
              <input
                id="child_birthday"
                name="child_birthday"
                type="date"
                className="input"
                max={today()}
                defaultValue={settings.data.child_birthday ?? ''}
              />
              <p className="hint">作品を作ったときの年齢を計算して、年齢ごとのおへやに分けます。変えると、作品のおへやも変わります</p>
            </div>
            <div className="field">
              <label htmlFor="museum_name">博物館の名前</label>
              <input id="museum_name" name="museum_name" className="input" maxLength={30} defaultValue={settings.data.museum_name} required />
            </div>
            {update.error && <div className="form-error">{update.error.message}</div>}
            <button className="btn btn-filled" disabled={update.isPending}>
              保存
            </button>
          </form>
        )}
      </Sheet>
      <InviteSheet Open={inviting} onClose={() => setInviting(false)} /> 
    </Screen>
  )
}
