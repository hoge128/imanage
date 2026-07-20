// サイト全体で共有する定数。URL をハードコードせず、必ずここを参照する。
// 公開先を変える場合はこのファイルだけを書き換えれば済むようにしておく。

/** 公開サイトのオリジン（末尾スラッシュなし） */
export const SITE_ORIGIN = 'https://imanage.itotsum.com'

/** ソースリポジトリ */
export const REPO_URL = 'https://github.com/hoge128/imanage'

/** 問い合わせ先 */
export const CONTACT_EMAIL = 'itotsum128lab@gmail.com'

/** 対応言語。先頭が既定（サイトのルートに置く言語）。 */
export const LOCALES = ['ja', 'en'] as const

/** hreflang の x-default に指定する言語 */
export const DEFAULT_HREFLANG = 'en'
