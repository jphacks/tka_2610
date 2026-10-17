// ⑩ 設定（/settings）。タブ。iOS の設定アプリ風。
import { useState, type FormEvent, type ReactNode } from 'react'
import { useMuseum, useSettings, useUpdateSettings } from '../api'
import { NavBar, Screen, Sheet, useToast } from '../components'
import { BellIcon, ChevronRight, DocIcon, FamilyIcon, HelpIcon, MuseumIcon, PersonIcon } from '../icons'
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

export default function Settings() {
  const settings = useSettings()
  const museum = useMuseum()
  const update = useUpdateSettings()
  const toast = useToast()
  const [editing, setEditing] = useState(false)

  const owner = settings.data?.owner_name ?? ''
  const soon = () => toast('この機能は準備中です')

  const save = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const data = new FormData(e.currentTarget)
    update.mutate(
      {
        museum_name: String(data.get('museum_name') ?? ''),
        owner_name: String(data.get('owner_name') ?? ''),
      },
      {
        onSuccess: () => {
          setEditing(false)
          toast('プロフィールを保存しました')
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
            detail={museum.data ? `${museum.data.displayed_count} / ${museum.data.capacity} 点を飾っています` : undefined}
            onClick={() => setEditing(true)}
          />
        </div>

        <div className="list-group">
          <Row icon={<PersonIcon size={18} />} label="プロフィール編集" onClick={() => setEditing(true)} />
          <Row icon={<FamilyIcon size={18} />} label="家族の管理" onClick={soon} />
          <Row icon={<BellIcon size={18} />} label="通知設定" onClick={soon} />
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
    </Screen>
  )
}
