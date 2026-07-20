<script setup lang="ts">
// スクリーンショットの枠。クリック / タップで拡大表示する。
import { computed, ref } from 'vue'
import { useData } from 'vitepress'

defineProps<{ src: string; alt: string }>()

const { lang } = useData()
const closeLabel = computed(() => (lang.value.startsWith('en') ? 'Close' : '閉じる'))

const dialog = ref<HTMLDialogElement | null>(null)
const loaded = ref(false)

function open() {
  if (!loaded.value) return
  dialog.value?.showModal()
  // 画面が狭いときは画像が横にはみ出すので、中央から見えるようにする
  const el = dialog.value
  if (el) el.scrollLeft = Math.max(0, (el.scrollWidth - el.clientWidth) / 2)
}

function onBackdrop(ev: MouseEvent) {
  if (ev.target === dialog.value) dialog.value?.close()
}
</script>

<template>
  <figure
    class="shot"
    :class="{ empty: !loaded }"
    :role="loaded ? 'button' : undefined"
    :tabindex="loaded ? 0 : undefined"
    @click="open"
    @keydown.enter.prevent="open"
    @keydown.space.prevent="open"
  >
    <img :src="src" :alt="alt" @load="loaded = true" @error="loaded = false" />
    <div v-if="!loaded" class="ph" aria-hidden="true">
      <div class="ph-file">{{ src }}</div>
    </div>
  </figure>

  <dialog ref="dialog" class="lightbox" @click="onBackdrop">
    <button
      type="button"
      class="lightbox-close"
      :aria-label="closeLabel"
      @click="dialog?.close()"
    >
      &times;
    </button>
    <img :src="src" :alt="alt" />
  </dialog>
</template>
