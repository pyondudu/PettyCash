<script setup>
import { ref } from 'vue'
import { supabase } from '../lib/supabase'
import { toLoginEmail } from '../lib/petty'
import appLogo from '../assets/app-logo.png'

const email = ref('')
const password = ref('')
const msg = ref('')
const busy = ref(false)

async function submit() {
  msg.value = ''
  busy.value = true
  try {
    const { error } = await supabase.auth.signInWithPassword({ email: toLoginEmail(email.value), password: password.value })
    if (error) msg.value = error.message === 'Invalid login credentials' ? '帳號或密碼錯誤' : '登入失敗：' + error.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="center-box card login">
    <img :src="appLogo" alt="零用金" class="login-logo" />
    <h1>零用金申請</h1>
    <form @submit.prevent="submit">
      <label>帳號<input v-model="email" type="text" required autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="例：alice" /></label>
      <label>密碼<input v-model="password" type="password" required autocomplete="current-password" /></label>
      <button class="btn primary block" :disabled="busy">{{ busy ? '登入中…' : '登入' }}</button>
    </form>
    <p v-if="msg" class="msg error">{{ msg }}</p>
  </div>
</template>
