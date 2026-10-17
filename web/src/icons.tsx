// 線画アイコン (外部ファイルを読み込まずに済むようインライン SVG)
import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement> & { size?: number }

function Svg({ size = 22, children, ...rest }: IconProps & { children: React.ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  )
}

export const HomeIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M3 10.5 12 3l9 7.5" />
    <path d="M5 9.5V20h5v-5.5h4V20h5V9.5" />
  </Svg>
)

export const GalleryIcon = (p: IconProps) => (
  <Svg {...p}>
    <rect x="3.5" y="4" width="17" height="15" rx="2.5" />
    <path d="M3.5 15.5 8 11l4 4 3-3 5.5 5" />
    <circle cx="15.5" cy="8.5" r="1.4" />
  </Svg>
)

export const MuseumIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M3 9 12 4l9 5H3Z" />
    <path d="M5.5 9.5v8M9.8 9.5v8M14.2 9.5v8M18.5 9.5v8M3.5 20h17" />
  </Svg>
)

export const UserIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="8.5" r="3.8" />
    <path d="M4.5 20c1.2-3.6 4-5.4 7.5-5.4s6.3 1.8 7.5 5.4" />
  </Svg>
)

export const PlusIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M12 5v14M5 12h14" />
  </Svg>
)

export const BellIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15l1.5-2Z" />
    <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
  </Svg>
)

export const BackIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="m15 5-7 7 7 7" />
  </Svg>
)

export const CloseIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M6 6l12 12M18 6 6 18" />
  </Svg>
)

export const MoreIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="5.5" cy="12" r="1.2" fill="currentColor" />
    <circle cx="12" cy="12" r="1.2" fill="currentColor" />
    <circle cx="18.5" cy="12" r="1.2" fill="currentColor" />
  </Svg>
)

export const CameraIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4 8.5A1.5 1.5 0 0 1 5.5 7h2.3l1.4-2h5.6l1.4 2h2.3A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5v-9Z" />
    <circle cx="12" cy="13" r="3.4" />
  </Svg>
)

export const CalendarIcon = (p: IconProps) => (
  <Svg {...p}>
    <rect x="4" y="5.5" width="16" height="14.5" rx="2" />
    <path d="M4 10h16M8.5 3.5v4M15.5 3.5v4" />
  </Svg>
)

export const PersonIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="8" r="3.4" />
    <path d="M5.5 19.5c.9-3.3 3.4-5 6.5-5s5.6 1.7 6.5 5" />
  </Svg>
)

export const FamilyIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="9" cy="8" r="3" />
    <circle cx="17" cy="9.5" r="2.3" />
    <path d="M3.5 19c.8-3 3-4.6 5.5-4.6s4.7 1.6 5.5 4.6M14.5 14.6c.8-.4 1.6-.6 2.5-.6 2 0 3.5 1.3 4 3.6" />
  </Svg>
)

export const HelpIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M9.6 9.6a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .8-1 1.5v.6" />
    <circle cx="12" cy="17" r=".6" fill="currentColor" />
  </Svg>
)

export const DocIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10.5A1 1 0 0 1 6 19.5v-15a1 1 0 0 1 1-1Z" />
    <path d="M14 3.5V8h4M9 12h6M9 15.5h6" />
  </Svg>
)

export const ChevronRight = (p: IconProps) => (
  <Svg {...p}>
    <path d="m9 5 7 7-7 7" />
  </Svg>
)

export const HeartIcon = ({ filled, ...p }: IconProps & { filled?: boolean }) => (
  <Svg {...p} fill={filled ? 'currentColor' : 'none'}>
    <path d="M12 20s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 7.4 4.2 4.2 0 0 1 19.5 10c0 5.6-7.5 10-7.5 10Z" />
  </Svg>
)

export const ShareIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="17.5" cy="5.5" r="2.3" />
    <circle cx="6.5" cy="12" r="2.3" />
    <circle cx="17.5" cy="18.5" r="2.3" />
    <path d="m8.5 10.8 7-4M8.5 13.2l7 4" />
  </Svg>
)

export const ExpandIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M4.5 9V4.5H9M15 4.5h4.5V9M19.5 15v4.5H15M9 19.5H4.5V15" />
  </Svg>
)

export const LeafIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="M5 19c0-8 5-13 14-14-1 9-6 14-14 14Z" />
    <path d="M5 19 13 11" />
  </Svg>
)

export const CubeIcon = (p: IconProps) => (
  <Svg {...p}>
    <path d="m12 3 8 4.5v9L12 21l-8-4.5v-9L12 3Z" />
    <path d="m4 7.5 8 4.5 8-4.5M12 12v9" />
  </Svg>
)

export const WalkIcon = (p: IconProps) => (
  <Svg {...p}>
    <circle cx="13" cy="4.5" r="1.8" />
    <path d="m9 21 2.5-6.5L14 17v4M8 11l2.5-3.5h3l2 3.5 2.5 1M11.5 14.5 12 8" />
  </Svg>
)
