<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { errText } from '../lib/store'
import { parseCategories } from '../lib/petty'

const keeper = ref('')
const categories = ref('')
const sheetUrl = ref('')
const msg = ref('')
const ok = ref('')
const busy = ref(false)

async function load() {
  const { data, error } = await supabase.from('petty_settings').select('key, value').in('key', ['keeper_name', 'categories', 'sheet_url'])
  if (error) { msg.value = '讀取失敗：' + errText(error); return }
  const s = Object.fromEntries((data ?? []).map((x) => [x.key, x.value]))
  keeper.value = s.keeper_name ?? ''
  categories.value = parseCategories(s.categories).join('\n')
  sheetUrl.value = s.sheet_url ?? ''
}

async function save() {
  msg.value = ok.value = ''
  const list = parseCategories(categories.value)
  if (!list.length) { msg.value = '類別至少要有一個'; return }
  const url = sheetUrl.value.trim()
  if (url && !/^https:\/\//.test(url)) { msg.value = '試算表網址要以 https:// 開頭'; return }
  busy.value = true
  const { error } = await supabase.from('petty_settings').upsert([
    { key: 'keeper_name', value: keeper.value.trim() },
    { key: 'categories', value: list.join('\n') },
    { key: 'sheet_url', value: url },
  ])
  busy.value = false
  if (error) { msg.value = '儲存失敗：' + errText(error); return }
  categories.value = list.join('\n')
  ok.value = '已儲存'
}

onMounted(load)
</script>

<template>
  <form class="form" @submit.prevent="save">
    <h2>設定</h2>
    <fieldset class="card">
      <label>零用金負責人（印在申請單上）<input v-model="keeper" /></label>
    </fieldset>
    <fieldset class="card">
      <label>類別（登記時選擇，一行一個）
        <textarea v-model="categories" rows="12" />
      </label>
      <p class="muted small">要和 Google 試算表「類別」欄的下拉選單一字不差，否則寫入後試算表會標示為無效值。</p>
    </fieldset>
    <fieldset class="card">
      <label>零用金明細表網址（管理頁「開啟明細表」按鈕用）<input v-model="sheetUrl" type="url" placeholder="https://docs.google.com/spreadsheets/d/…" /></label>
      <p class="muted small">在 Google 試算表上方網址列整串複製貼上；留空則不顯示按鈕。</p>
    </fieldset>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg">{{ ok }}</p>
    <div class="form-actions"><button class="btn primary" :disabled="busy">儲存</button></div>
  </form>
</template>
