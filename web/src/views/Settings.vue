<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { errText } from '../lib/store'

const keeper = ref('')
const msg = ref('')
const ok = ref('')
const busy = ref(false)

async function load() {
  const { data, error } = await supabase.from('petty_settings').select('value').eq('key', 'keeper_name').maybeSingle()
  if (error) msg.value = '讀取失敗：' + errText(error)
  else keeper.value = data?.value ?? ''
}

async function save() {
  msg.value = ok.value = ''
  busy.value = true
  const { error } = await supabase.from('petty_settings').upsert({ key: 'keeper_name', value: keeper.value.trim() })
  busy.value = false
  if (error) msg.value = '儲存失敗：' + errText(error)
  else ok.value = '已儲存'
}

onMounted(load)
</script>

<template>
  <form class="form" @submit.prevent="save">
    <h2>設定</h2>
    <fieldset class="card">
      <label>零用金負責人（印在申請單上）<input v-model="keeper" /></label>
    </fieldset>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg">{{ ok }}</p>
    <div class="form-actions"><button class="btn primary" :disabled="busy">儲存</button></div>
  </form>
</template>
