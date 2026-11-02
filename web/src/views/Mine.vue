<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import { canAddVouchers, recentMonths, MINE_MONTHS } from '../lib/petty'
import { BUCKET } from '../lib/photos'
import RequestCard from '../components/RequestCard.vue'
import AddVouchers from '../components/AddVouchers.vue'

const rows = ref([])
const loading = ref(true)
const msg = ref('')
const adding = ref(null)    // 正在補憑證的申請 id
// 只列最近 3 個月（依填寫日期，草稿一律列出）；可再篩選月份。資料庫本身不刪
const recent = recentMonths()
const month = ref('')
const shown = computed(() => rows.value.filter((r) => !month.value || r.status === 'draft' || r.fill_date?.startsWith(month.value)))

async function load() {
  loading.value = true
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)')
    .eq('applicant_id', store.uid).or(`status.eq.draft,fill_date.gte.${recent.from}`)
    .order('submitted_at', { ascending: false })
  loading.value = false
  if (error) msg.value = '讀取失敗：' + errText(error)
  else rows.value = data
}

const router = useRouter()

// 草稿：還沒送出前可以編輯或刪除（只限自己的）
async function deleteDraft(r) {
  if (!confirm(`刪除這筆草稿？\n${r.reason || '（事由未填）'}\n連同已存的憑證照片一起刪除，無法復原。`)) return
  msg.value = ''
  const { data, error } = await supabase.rpc('petty_delete_draft', { p_id: r.id })
  if (error) { msg.value = '刪除失敗：' + errText(error); return }
  if (data?.length) await supabase.storage.from(BUCKET).remove(data)
  await load()
}

async function vouchersSaved() {
  adding.value = null
  await load()
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>我的申請 <span class="muted small head-note">（資料保存 {{ MINE_MONTHS }} 個月）</span></h2>
      <label class="inline">月份
        <select v-model="month">
          <option value="">近 {{ MINE_MONTHS }} 個月</option>
          <option v-for="m in recent.months" :key="m" :value="m">{{ m.replace('-', '/') }}</option>
        </select>
      </label>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!shown.length" class="muted center empty">{{ month ? '這個月沒有申請。' : `最近 ${MINE_MONTHS} 個月沒有申請。` }}</p>
    <div class="list">
      <RequestCard v-for="r in shown" :key="r.id" :request="r">
        <template #actions>
          <template v-if="r.status === 'draft'">
            <button class="btn small danger ghost" @click="deleteDraft(r)">刪除</button>
            <button class="btn small primary" @click="router.push({ path: '/apply', query: { draft: r.id } })">編輯／送出</button>
          </template>
          <button v-if="canAddVouchers(r) && adding !== r.id" class="btn small" @click="adding = r.id">
            補憑證<span v-if="!r.petty_vouchers.length" class="badge">!</span>
          </button>
        </template>
        <template v-if="adding === r.id" #extra>
          <AddVouchers :request="r" @saved="vouchersSaved" @cancel="adding = null" />
        </template>
      </RequestCard>
    </div>
  </div>
</template>
