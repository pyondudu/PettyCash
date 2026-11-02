<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { fullImageCorners } from '../lib/scanner'

// 四角調整：在照片上拖曳四個圓點，讓綠框貼齊憑證邊緣（移植自 Photo to PDF 的 cornerEditor.js）
const props = defineProps({
  source: { type: Object, required: true },     // canvas（原圖座標）
  corners: { type: Array, required: true },     // [左上, 右上, 右下, 左下]
  label: { type: String, default: '' },
})
const emit = defineEmits(['done'])              // 確定回傳四角，取消回傳 null

const W = props.source.width
const H = props.source.height
const clampPoint = (p) => ({ x: Math.min(Math.max(p.x, 0), W), y: Math.min(Math.max(p.y, 0), H) })

const stage = ref(null)
const frame = ref(null)
const view = ref(null)
// 座標一律用原圖像素，顯示時再乘上 scale；偵測結果超出照片的點拉回照片內
const points = reactive(props.corners.map(clampPoint))
const scale = ref(0)
const size = computed(() => ({ w: Math.round(W * scale.value), h: Math.round(H * scale.value) }))
const active = ref(-1)

// 依舞台實際可用空間（扣掉 padding）等比縮放；手機拍完照回來時畫面大小還會變，所以持續監看
function layout() {
  const s = stage.value
  if (!s) return
  const cs = getComputedStyle(s)
  const availW = s.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
  const availH = s.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom)
  if (availW <= 0 || availH <= 0) return
  const next = Math.min(availW / W, availH / H)
  if (Math.abs(next - scale.value) < 1e-4) return
  scale.value = next
  const dpr = window.devicePixelRatio || 1
  const c = view.value
  c.width = Math.round(W * next * dpr)
  c.height = Math.round(H * next * dpr)
  c.getContext('2d').drawImage(props.source, 0, 0, c.width, c.height)
}

let observer = null
onMounted(() => {
  layout()
  observer = new ResizeObserver(layout)
  observer.observe(stage.value)
})
onBeforeUnmount(() => {
  observer?.disconnect()
  stopDrag()
})

const polygon = computed(() => points.map((p) => `${p.x * scale.value},${p.y * scale.value}`).join(' '))

// 拖曳：按下圓點後在整個視窗追蹤手指，手指滑出圓點也能繼續拖
function onMove(e) {
  if (active.value < 0) return
  e.preventDefault()
  const rect = frame.value.getBoundingClientRect()
  points[active.value] = clampPoint({ x: (e.clientX - rect.left) / scale.value, y: (e.clientY - rect.top) / scale.value })
}
function stopDrag() {
  active.value = -1
  window.removeEventListener('pointermove', onMove)
  window.removeEventListener('pointerup', stopDrag)
  window.removeEventListener('pointercancel', stopDrag)
}
function down(i, e) {
  e.preventDefault()
  stopDrag()
  active.value = i
  window.addEventListener('pointermove', onMove, { passive: false })
  window.addEventListener('pointerup', stopDrag)
  window.addEventListener('pointercancel', stopDrag)
}

function finish(result) {
  stopDrag()
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
        <div ref="frame" class="corner-frame" :style="{ width: size.w + 'px', height: size.h + 'px' }">
          <canvas ref="view" />
          <svg class="corner-svg"><polygon :points="polygon" /></svg>
          <div
            v-for="(p, i) in points" :key="i" class="corner-handle" :class="{ active: active === i }"
            :style="{ transform: `translate(${p.x * scale}px, ${p.y * scale}px)` }"
            @pointerdown="down(i, $event)"
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
