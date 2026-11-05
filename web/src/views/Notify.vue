<script setup>
import { onMounted, ref } from 'vue'
import { store, errText } from '../lib/store'
import { pushSupport, pushEnabled, enablePush, disablePush, sendTestPush } from '../lib/push'

const support = pushSupport()
const enabled = ref(false)
const busy = ref(false)
const msg = ref('')
const ok = ref('')

async function run(fn, done) {
  msg.value = ok.value = ''
  busy.value = true
  try {
    await fn()
    ok.value = done
  } catch (e) {
    msg.value = errText(e)
  }
  enabled.value = await pushEnabled().catch(() => false)
  busy.value = false
}

const turnOn = () => run(enablePush, '已開啟通知。可以按「傳送測試通知」試試看。')
const turnOff = () => run(disablePush, '已關閉這個裝置的通知。')
const test = () => run(sendTestPush, '已送出測試通知，幾秒內應該會收到。')

onMounted(async () => { enabled.value = await pushEnabled().catch(() => false) })
</script>

<template>
  <div class="form narrow">
    <h2>通知</h2>
    <fieldset class="card">
      <div class="stack">
        <p v-if="store.isApprover">開啟後，每週五早上 9:00 如果有待核准的申請，這個裝置會收到通知。</p>
        <p v-else>開啟後，主管核准申請時，這個裝置會收到通知（要在「設定」頁的「核准通知對象」裡）。</p>
        <p class="muted small">通知只寫「有新通知」，不會顯示姓名和金額。手機、電腦每個裝置要各自開啟；隨時可以關閉。</p>

        <template v-if="support === 'ok'">
          <p><strong>這個裝置：</strong>{{ enabled ? '已開啟通知' : '尚未開啟通知' }}</p>
          <div class="form-actions">
            <button v-if="!enabled" class="btn primary" :disabled="busy" @click="turnOn">開啟通知</button>
            <template v-else>
              <button class="btn" :disabled="busy" @click="turnOff">關閉通知</button>
              <button class="btn primary" :disabled="busy" @click="test">傳送測試通知</button>
            </template>
          </div>
        </template>

        <template v-else-if="support === 'ios-install'">
          <p><strong>iPhone 要先把網頁加到主畫面才能收通知（iOS 16.4 以上）：</strong></p>
          <ol>
            <li>用 Safari 開啟本網站，按下方的「分享」按鈕。</li>
            <li>選「加入主畫面」，按「新增」。</li>
            <li>從主畫面的「零用金」圖示開啟、登入，再回到這一頁按「開啟通知」。</li>
          </ol>
        </template>

        <p v-else-if="support === 'dev'" class="muted">本機開發版沒有 Service Worker，請在正式網址測試通知。</p>
        <p v-else class="msg error">這個瀏覽器不支援通知，請改用 Chrome（Android）或 Safari（iPhone 加到主畫面）。</p>
      </div>
    </fieldset>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg success">{{ ok }}</p>
  </div>
</template>
