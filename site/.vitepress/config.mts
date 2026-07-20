import { defineConfig } from 'vitepress'
import { SITE_ORIGIN, REPO_URL, DEFAULT_HREFLANG } from './constants'

/**
 * relativePath（例: 'index.md' / 'privacy.md' / 'en/privacy.md'）から
 * 「言語」と「言語を除いたページキー」を取り出す。
 * ページキーは日本語版・英語版で共通になる（'' = トップページ）。
 */
function splitPath(relativePath: string): { lang: string; key: string } {
  let p = relativePath.replace(/\.md$/, '').replace(/(^|\/)index$/, '$1')
  if (p === '/') p = ''

  if (p === 'en' || p.startsWith('en/')) {
    return { lang: 'en', key: p.slice(2).replace(/^\//, '') }
  }
  return { lang: 'ja', key: p }
}

/** 言語とページキーから正規 URL を組み立てる */
function urlFor(lang: string, key: string): string {
  const prefix = lang === 'ja' ? '' : `/${lang}`
  return `${SITE_ORIGIN}${prefix}/${key}`.replace(/\/+$/, '/')
}

export default defineConfig({
  // 独自ドメインのルートで配信するため base はルート
  base: '/',
  cleanUrls: true,
  lastUpdated: true,
  // 各ページの title をそのまま使う（"... | Imanage" の重複を避ける）
  titleTemplate: false,

  // sitemap.xml を自動生成する（robots.txt から参照している）
  sitemap: {
    hostname: SITE_ORIGIN,
  },

  head: [
    // アプリアイコン（AppIcon.icon）と同じレターマークを使う
    ['link', { rel: 'icon', href: '/favicon.svg', type: 'image/svg+xml' }],
    ['link', { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' }],
    ['meta', { name: 'theme-color', content: '#000000' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'Imanage' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
  ],

  locales: {
    root: {
      label: '日本語',
      lang: 'ja',
      title: 'Imanage',
      description:
        'Imanage は撮影日・機種・レンズ・評価などの EXIF / XMP 情報をもとに、カメラの静止画をフォルダへ自動で振り分ける macOS アプリです。すべての処理は Mac の中だけで完結します。',
      themeConfig: {
        nav: [
          { text: '特徴', link: '/#features' },
          { text: 'プライバシー', link: '/privacy' },
        ],
        editLink: undefined,
        docFooter: { prev: false, next: false },
        darkModeSwitchLabel: 'テーマ',
        returnToTopLabel: 'トップに戻る',
        langMenuLabel: '言語を変更',
        lastUpdatedText: '最終更新',
        footer: {
          message: '<a href="/privacy">プライバシーポリシー</a>',
          copyright: 'Copyright © 2026 hoge128 (Tsuyoshi Ito)',
        },
      },
    },

    en: {
      label: 'English',
      lang: 'en',
      link: '/en/',
      title: 'Imanage',
      description:
        'Imanage is a macOS app that files your camera stills into folders using their EXIF and XMP data — capture date, camera model, lens, rating and more. Everything happens on your Mac.',
      themeConfig: {
        nav: [
          { text: 'Features', link: '/en/#features' },
          { text: 'Privacy', link: '/en/privacy' },
        ],
        docFooter: { prev: false, next: false },
        footer: {
          message: '<a href="/en/privacy">Privacy Policy</a>',
          copyright: 'Copyright © 2026 hoge128 (Tsuyoshi Ito)',
        },
      },
    },
  },

  themeConfig: {
    // 角丸の黒背景はダークテーマで沈むため、ナビにはレターマークのみを使う
    logo: { light: '/logo-light.svg', dark: '/logo-dark.svg', alt: 'Imanage' },
    siteTitle: 'Imanage',
    // 1 ページずつの LP なのでサイドバーと検索は持たない
    sidebar: false,
    aside: false,
    outline: false,
    socialLinks: [{ icon: 'github', link: REPO_URL }],
  },

  /**
   * canonical と hreflang を全ページに付与する。
   * hreflang は「自分自身を含む全言語版を相互に列挙」しないと Google に無視されるため、
   * 各ページで ja / en / x-default の 3 本を必ず出す。
   */
  transformPageData(pageData) {
    const { lang, key } = splitPath(pageData.relativePath)
    const canonical = urlFor(lang, key)

    pageData.frontmatter.head ??= []
    pageData.frontmatter.head.push(
      ['link', { rel: 'canonical', href: canonical }],
      ['meta', { property: 'og:url', content: canonical }],
      ['link', { rel: 'alternate', hreflang: 'ja', href: urlFor('ja', key) }],
      ['link', { rel: 'alternate', hreflang: 'en', href: urlFor('en', key) }],
      ['link', {
        rel: 'alternate',
        hreflang: 'x-default',
        href: urlFor(DEFAULT_HREFLANG, key),
      }],
    )

    const title = pageData.frontmatter.title ?? pageData.title
    const description = pageData.frontmatter.description ?? pageData.description
    if (title) {
      pageData.frontmatter.head.push(['meta', { property: 'og:title', content: title }])
    }
    if (description) {
      pageData.frontmatter.head.push([
        'meta',
        { property: 'og:description', content: description },
      ])
    }
  },
})
