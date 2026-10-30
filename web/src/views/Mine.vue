<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import RequestCard from '../components/RequestCard.vue'

const rows = ref([])
const loading = ref(true)
const msg = ref('')

async function load() {
  loading.value = true
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)')
    .eq('applicant_id', store.uid).order('submitted_at', { ascending: false })
  loading.value = false
  if (error) msg.value = '讀取失敗：' + errText(error)
  else rows.value = data
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>我的申請</h2>
      <button class="btn small" @click="load">重新整理</button>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!rows.length" class="muted center empty">還沒有申請。</p>
    <div class="list">
      <RequestCard v-for="r in rows" :key="r.id" :request="r" />
    </div>
  </div>
</template>
