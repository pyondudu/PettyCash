<script setup>
import { nextTick, onMounted, reactive, ref } from 'vue'
import { fullImageCorners } from '../lib/scanner'

// 四角調整：在照片上拖曳四個圓點，讓綠框貼齊憑證邊緣（移植自 Photo to PDF 的 cornerEditor.js）
const props = defineProps({
  source: { type: Object, required: true },     // canvas（原圖座標）
  corners: { type: Array, required: true },     // [左上, 右上, 右下, 左下]
  label: { type: String, default: '' },
})
const emit = defineEmits(['done'])              // 確定回傳四角，取消回傳 null

const stage = ref(null)
const view = ref(null)
const points = reactive(props.corners.map((p) => ({ ...p })))
const size = reactive({ w: 0, h: 0, scale: 1 })
const active = ref(-1)

onMounted(async () => {
  await nextTick()
  const s = stage.value
  size.scale = Math.min(s.clientWidth / props.source.width, s.clientHeight / props.source.height)
  size.w = Math.round(props.source.width * size.scale)
  size.h = Math.round(props.source.height * size.scale)
  const dpr = window.devicePixelRatio || 1
  const c = view.value
  c.width = Math.round(size.w * dpr)
  c.height = Math.round(size.h * dpr)
  c.getContext('2d').drawImage(props.source, 0, 0, c.width, c.height)
})

const polygon = () => points.map((p) => `${p.x * size.scale},${p.y * size.scale}`).join(' ')

function down(i, e) {
  e.preventDefault()
  e.currentTarget.setPointerCapture(e.pointerId)
  active.value = i
}
function move(i, e) {
  if (!e.currentTarget.hasPointerCapture(e.pointerId)) return
  const rect = e.currentTarget.parentElement.getBoundingClientRect()
  const x = Math.min(Math.max(e.clientX - rect.left, 0), size.w)
  const y = Math.min(Math.max(e.clientY - rect.top, 0), size.h)
  points[i] = { x: x / size.scale, y: y / size.scale }
}
function up() { active.value = -1 }

function finish(result) {
  if (view.value) { view.value.width = 0; view.value.height = 0 }
  emit('done', result)
}
function useFull() {
  points.splice(0, 4, ...fullImageCorners(props.source))
}
</script>

<template>
  <Teleport to="body">
    <section class="corner-editor no-print">
      <p class="corner-hint">拖曳四個圓點，讓綠框貼齊憑證邊緣<span v-if="label">（{{ label }}）</span></p>
      <div ref="stage" class="corner-stage">
        <div class="corner-frame" :style="{ width: size.w + 'px', height: size.h + 'px' }">
          <canvas ref="view" />
          <svg class="corner-svg"><polygon :points="polygon()" /></svg>
          <div
            v-for="(p, i) in points" :key="i" class="corner-handle" :class="{ active: active === i }"
            :style="{ transform: `translate(${p.x * size.scale}px, ${p.y * size.scale}px)` }"
            @pointerdown="down(i, $event)" @pointermove="move(i, $event)" @pointerup="up" @pointercancel="up"
          />
        </div>
      </div>
      <div class="corner-actions">
        <button type="button" class="btn ghost" @click="finish(null)">不加這張</button>
        <button type="button" class="btn ghost" @click="useFull">整張照片</button>
        <button type="button" class="btn primary" @click="finish(points.map((p) => ({ ...p })))">確定</button>
      </div>
    </section>
  </Teleport>
</template>
