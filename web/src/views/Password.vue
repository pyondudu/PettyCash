<script setup>
import { reactive, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'

const MIN_LENGTH = 6
const form = reactive({ current: '', next: '', confirm: '' })
const busy = ref(false)
const msg = ref('')
const ok = ref(false)

// Supabase 常見錯誤轉成中文
function explain(e) {
  const m = errText(e)
  if (/different from the old password/i.test(m)) return '新密碼不能和目前密碼相同'
  if (/at least|weak|short/i.test(m)) return `密碼太簡單或太短（至少 ${MIN_LENGTH} 個字）`
  return m
}

async function save() {
  msg.value = ''
  ok.value = false
  if (!form.current || !form.next) { msg.value = '請填寫目前密碼和新密碼'; return }
  if (form.next.length < MIN_LENGTH) { msg.value = `新密碼至少 ${MIN_LENGTH} 個字`; return }
  if (form.next !== form.confirm) { msg.value = '兩次輸入的新密碼不一樣'; return }
  busy.value = true
  try {
    // 先用目前密碼驗證是本人
    const check = await supabase.auth.signInWithPassword({ email: store.session.user.email, password: form.current })
    if (check.error) { msg.value = '目前密碼不正確'; return }
    const { error } = await supabase.auth.updateUser({ password: form.next })
    if (error) { msg.value = '修改失敗：' + explain(error); return }
    Object.assign(form, { current: '', next: '', confirm: '' })
    ok.value = true
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <form class="form narrow" @submit.prevent="save">
    <h2>修改密碼</h2>
    <fieldset class="card">
      <div class="stack">
        <label>目前密碼<input v-model="form.current" type="password" autocomplete="current-password" /></label>
        <label>新密碼（至少 {{ MIN_LENGTH }} 個字）<input v-model="form.next" type="password" autocomplete="new-password" /></label>
        <label>再輸入一次新密碼<input v-model="form.confirm" type="password" autocomplete="new-password" /></label>
      </div>
    </fieldset>
    <p class="muted small">這個帳號和 PartTrail 共用，改了之後 PartTrail 也要用新密碼登入。密碼有分大小寫。</p>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg success">密碼已更新，下次請用新密碼登入。</p>
    <div class="form-actions"><button class="btn primary" :disabled="busy">{{ busy ? '更新中…' : '更新密碼' }}</button></div>
  </form>
</template>
