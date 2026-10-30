<script setup>
import { onMounted, reactive, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import { ROLES, toLoginEmail } from '../lib/petty'

const rows = ref([])
const msg = ref('')
const ok = ref('')
const busy = ref(false)
const form = reactive({ login: '', name: '', unit: '', role: 'applicant' })
const editing = ref(null)   // 編輯中的成員（複本）

async function load() {
  const { data, error } = await supabase.from('petty_members').select('*').order('created_at')
  if (error) msg.value = '讀取失敗：' + errText(error)
  else rows.value = data
}

async function add() {
  msg.value = ok.value = ''
  if (!form.login.trim() || !form.name.trim()) { msg.value = '請填帳號和姓名'; return }
  busy.value = true
  const { error } = await supabase.rpc('petty_add_member', {
    p_login: form.login, p_name: form.name, p_unit: form.unit, p_role: form.role,
  })
  busy.value = false
  if (error) { msg.value = '加入失敗：' + errText(error); return }
  ok.value = `已加入 ${form.name}（${toLoginEmail(form.login)}）`
  Object.assign(form, { login: '', name: '', unit: '', role: 'applicant' })
  await load()
}

async function save() {
  msg.value = ok.value = ''
  const m = editing.value
  if (!m.name.trim()) { msg.value = '姓名不能空白'; return }
  if (m.user_id === store.uid && (m.role !== 'admin' || !m.active)
      && !confirm('你正在取消自己的管理者權限，存檔後就不能再管理成員。確定嗎？')) return
  busy.value = true
  const { error } = await supabase.from('petty_members')
    .update({ name: m.name.trim(), unit: m.unit.trim(), role: m.role, active: m.active }).eq('user_id', m.user_id)
  busy.value = false
  if (error) { msg.value = '儲存失敗：' + errText(error); return }
  editing.value = null
  await load()
}

onMounted(load)
</script>

<template>
  <div class="page">
    <h2>成員</h2>
    <p class="muted small">
      帳號要先在 Supabase 後台 Authentication → Add user 建立（Email 用「名字@parttrail.local」，Auto Confirm User 打勾），
      再在這裡加入。姓名、單位會印在申請單上；之前送出的申請不會跟著改。
    </p>

    <form class="card add-member" @submit.prevent="add">
      <div class="grid4">
        <label>帳號<input v-model="form.login" autocapitalize="none" spellcheck="false" placeholder="例：alice" /></label>
        <label>姓名<input v-model="form.name" /></label>
        <label>單位<input v-model="form.unit" placeholder="可空白" /></label>
        <label>角色
          <select v-model="form.role"><option v-for="(l, k) in ROLES" :key="k" :value="k">{{ l }}</option></select>
        </label>
      </div>
      <div class="form-actions"><button class="btn primary small" :disabled="busy">加入成員</button></div>
    </form>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg">{{ ok }}</p>

    <table class="member-table">
      <thead><tr><th>帳號</th><th>姓名</th><th>單位</th><th>角色</th><th>狀態</th><th></th></tr></thead>
      <tbody>
        <tr v-for="m in rows" :key="m.user_id" :class="{ inactive: !m.active }">
          <template v-if="editing?.user_id === m.user_id">
            <td class="small">{{ m.email }}</td>
            <td><input v-model="editing.name" /></td>
            <td><input v-model="editing.unit" /></td>
            <td><select v-model="editing.role"><option v-for="(l, k) in ROLES" :key="k" :value="k">{{ l }}</option></select></td>
            <td><label class="check"><input v-model="editing.active" type="checkbox" />啟用</label></td>
            <td class="nowrap">
              <button class="btn small primary" :disabled="busy" @click="save">儲存</button>
              <button class="btn small ghost" @click="editing = null">取消</button>
            </td>
          </template>
          <template v-else>
            <td class="small">{{ m.email }}</td>
            <td>{{ m.name }}</td>
            <td>{{ m.unit || '—' }}</td>
            <td>{{ ROLES[m.role] }}</td>
            <td>{{ m.active ? '啟用' : '停用' }}</td>
            <td><button class="btn small ghost" @click="editing = { ...m }">編輯</button></td>
          </template>
        </tr>
      </tbody>
    </table>
  </div>
</template>
