import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  canTransition, canApprove, canAddVouchers, normalizeAmount, validateAmount, fmtMoney,
  normalizeDate, fmtDate, fmtTaipei, todayTaipei, approvedText, submittedText,
  voucherKey, findLocalDuplicates, voucherPairs, printFields, toLoginEmail,
  addMonths, requestFinished, requestMonth, archiveZipName, archivePhotoPath, archiveMonths,
} from '../src/lib/petty.js'

test('normalizeDate 接受多種寫法', () => {
  assert.equal(normalizeDate('2026-09-30'), '2026-09-30')
  assert.equal(normalizeDate('2026/9/30'), '2026-09-30')
  assert.equal(normalizeDate('115/09/30'), '2026-09-30')
  assert.equal(normalizeDate('115/9/3'), '2026-09-03')
  assert.equal(normalizeDate(' 2026.9.30 '), '2026-09-30')
  assert.equal(normalizeDate('20260930'), '2026-09-30')
})

test('normalizeDate 擋下無效日期', () => {
  assert.equal(normalizeDate(''), null)
  assert.equal(normalizeDate(null), null)
  assert.equal(normalizeDate('2026/2/30'), null)
  assert.equal(normalizeDate('2026/13/1'), null)
  assert.equal(normalizeDate('abc'), null)
  assert.equal(normalizeDate('9/30'), null)
})

test('normalizeAmount 去掉逗號、$ 和空白', () => {
  assert.equal(normalizeAmount('1,000'), 1000)
  assert.equal(normalizeAmount('$ 500'), 500)
  assert.equal(normalizeAmount(' 12.5 '), 12.5)
  assert.equal(normalizeAmount(300), 300)
  assert.equal(normalizeAmount(''), null)
  assert.equal(normalizeAmount('-5'), null)
  assert.equal(normalizeAmount('abc'), null)
})

test('validateAmount 邊界', () => {
  assert.match(validateAmount('0'), /大於 0/)
  assert.equal(validateAmount('1'), null)
  assert.equal(validateAmount('10000'), null)
  assert.equal(validateAmount('10,000'), null)
  assert.match(validateAmount('10001'), /請款單/)
  assert.match(validateAmount('12.5'), /整數/)
  assert.match(validateAmount(''), /請輸入/)
})

test('fmtMoney 千分位', () => {
  assert.equal(fmtMoney(1234567), '1,234,567')
  assert.equal(fmtMoney(''), '')
})

test('fmtTaipei 用台北時區，跨日正確', () => {
  assert.equal(fmtTaipei('2026-09-30T16:05:09Z'), '2026/10/01 00:05:09')
  assert.equal(fmtTaipei('2026-09-30T03:00:00+00:00'), '2026/09/30 11:00:00')
  assert.equal(fmtTaipei(null), '')
  assert.equal(todayTaipei(new Date('2026-09-30T16:30:00Z')), '2026-10-01')
})

test('核准／送出字樣', () => {
  assert.equal(approvedText('陳大文', '2026-10-30T01:02:03Z'), '陳大文 已於 2026/10/30 09:02:03 核准')
  assert.equal(submittedText('王小明', '2026-10-29T23:59:59Z'), '王小明 已於 2026/10/30 07:59:59 送出')
  assert.equal(approvedText('陳大文', null), '')
})

test('狀態轉換依角色', () => {
  assert.ok(canTransition('pending', 'approved', 'approver'))
  assert.ok(canTransition('pending', 'rejected', 'approver'))
  assert.ok(!canTransition('approved', 'printed', 'approver'))
  assert.ok(!canTransition('pending', 'approved', 'admin'))
  assert.ok(canTransition('approved', 'printed', 'admin'))
  assert.ok(canTransition('printed', 'printed', 'admin'))
  assert.ok(canTransition('printed', 'booked', 'admin'))
  assert.ok(canTransition('approved', 'returned', 'admin'))
  assert.ok(!canTransition('booked', 'returned', 'admin'))
  assert.ok(!canTransition('pending', 'approved', 'applicant'))
})

test('入帳前可以補憑證', () => {
  assert.ok(canAddVouchers({ status: 'pending' }))
  assert.ok(canAddVouchers({ status: 'approved' }))
  assert.ok(canAddVouchers({ status: 'printed' }))
  assert.ok(!canAddVouchers({ status: 'booked' }))
  assert.ok(!canAddVouchers({ status: 'rejected' }))
  assert.ok(!canAddVouchers({ status: 'returned' }))
  assert.ok(!canAddVouchers({ status: 'printed', archived_at: '2027-01-01T00:00:00Z' }))
})

test('只有主管能核准，包含自己的申請', () => {
  assert.ok(canApprove({ status: 'pending' }, 'approver'))
  assert.ok(!canApprove({ status: 'pending' }, 'admin'))
  assert.ok(!canApprove({ status: 'pending' }, 'applicant'))
  assert.ok(!canApprove({ status: 'approved' }, 'approver'))
})

test('憑證 key 與同筆重複', () => {
  assert.equal(voucherKey('115/9/30', '$1,200'), '2026-09-30|1200')
  assert.equal(voucherKey('bad', '100'), null)
  const dup = findLocalDuplicates([
    { date: '2026-09-30', amount: '1200' },
    { date: '115/09/30', amount: '1,200' },
    { date: '2026-09-30', amount: '1201' },
  ])
  assert.deepEqual(dup, ['2026-09-30|1200'])
  assert.deepEqual(voucherPairs([{ date: '115/9/30', amount: '$ 50' }, { date: 'x', amount: 1 }]),
    [{ date: '2026-09-30', amount: 50 }])
})

test('列印欄位對應', () => {
  const f = printFields({
    fill_date: '2026-10-29',
    applicant_name: '王小明',
    applicant_unit: '',
    reason: '買文具',
    amount: 1500,
    note: null,
    disbursed_date: '2026-10-31',
    approver_name: '陳大文',
    approved_at: '2026-10-30T02:00:00Z',
    submitted_at: '2026-10-29T08:30:15Z',
  }, '林美華')
  assert.deepEqual(f, {
    fillDate: '2026/10/29',
    applicant: '王小明',
    unit: '',
    reason: '買文具',
    amount: '$1,500',
    keeper: '林美華',
    disbursedDate: '2026/10/31',
    note: '',
    approver: '陳大文 已於 2026/10/30 10:00:00 核准',
    payee: '',
    submitter: '王小明 已於 2026/10/29 16:30:15 送出',
  })
})

test('addMonths 月底對齊', () => {
  assert.equal(addMonths('2026-10-31T05:00:00Z', 4).toISOString(), '2027-02-28T05:00:00.000Z')
  assert.equal(addMonths('2026-01-15T00:00:00Z', 4).toISOString(), '2026-05-15T00:00:00.000Z')
  assert.equal(addMonths('2027-10-31T00:00:00Z', 4).toISOString(), '2028-02-29T00:00:00.000Z')
})

test('申請結束：已入帳滿 4 個月或已退回', () => {
  const r = { status: 'booked', booked_at: '2026-06-30T02:00:00Z' }
  assert.ok(!requestFinished(r, '2026-10-30T01:59:59Z'))
  assert.ok(requestFinished(r, '2026-10-30T02:00:00Z'))
  assert.ok(requestFinished({ status: 'returned' }, '2026-01-01T00:00:00Z'))
  assert.ok(requestFinished({ status: 'rejected' }, '2026-01-01T00:00:00Z'))
  assert.ok(!requestFinished({ status: 'printed' }, '2027-01-01T00:00:00Z'))
})

test('申請編號月份與 zip 命名', () => {
  assert.equal(requestMonth('P2026110001'), '202611')
  assert.equal(requestMonth('PC00001'), null)
  assert.equal(archiveZipName('202611'), '聲智零用金憑證_2026-11.zip')
  assert.equal(archivePhotoPath('P2026110001', 1), 'P2026110001/憑證2.jpg')
})

test('整月封存：每筆都結束才可以', () => {
  const now = '2027-04-01T00:00:00Z'
  const months = archiveMonths([
    { request_no: 'P2026110001', status: 'booked', booked_at: '2026-11-20T00:00:00Z' },
    { request_no: 'P2026110002', status: 'returned' },
    { request_no: 'P2026120001', status: 'booked', booked_at: '2026-12-20T00:00:00Z' },
    { request_no: 'P2026120002', status: 'printed' },
    { request_no: 'P2026100001', status: 'booked', booked_at: '2026-10-20T00:00:00Z', archived_at: '2027-03-01T00:00:00Z' },
  ], now)
  assert.deepEqual(months, [
    { month: '202612', total: 2, open: 2, pending: 2, ready: false },
    { month: '202611', total: 2, open: 0, pending: 2, ready: true },
    { month: '202610', total: 1, open: 0, pending: 0, ready: false },
  ])
})

test('toLoginEmail 補網域並轉小寫', () => {
  assert.equal(toLoginEmail(' Alice '), 'alice@parttrail.local')
  assert.equal(toLoginEmail('someone@example.com'), 'someone@example.com')
})
