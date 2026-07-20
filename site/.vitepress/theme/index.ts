import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import Shot from './components/Shot.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    // markdown から <Shot> をそのまま書けるようにする
    app.component('Shot', Shot)
  },
} satisfies Theme
