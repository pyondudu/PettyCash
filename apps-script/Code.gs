/**
 * 零用金 → Google 試算表 自動登記
 *
 * 網頁按「標已登記」後，這支程式每 1 分鐘向資料庫要「已登記、還沒寫入」的申請，
 * 寫到與核發日期同年份的分頁（「2026年」或「2026」）最後一筆資料的下一列，寫完再回報資料庫，不會重複寫。
 *
 * 安裝（每份試算表做一次；正式試算表為雲端硬碟「聲智零用金管理」裡的「零用金明細表」）：
 *   1. 試算表 → 擴充功能 → Apps Script，把這整份貼上（取代原本內容），按儲存。
 *   2. 左側齒輪「專案設定」→ 最下面「指令碼屬性」新增三個：
 *        SUPABASE_URL       網頁用的 Supabase 網址（https://xxxx.supabase.co）
 *        SUPABASE_ANON_KEY  網頁用的 anon key
 *        SHEET_SECRET       和資料庫 petty_secrets 裡 sheet_secret 相同的密碼
 *   3. 回到編輯器，上方函式選 installTrigger → 執行 → 依畫面授權。
 *   4. 重新整理試算表，選單會多出「零用金」，可「立即同步」或「測試連線」。
 *
 * 欄位以標題列的文字對應（前 5 列內找含「日期」「類別」「收據編號」的那一列），欄位順序可以調整。
 * 執行失敗時 Google 會寄信通知安裝的人；下一分鐘會自動重試。
 */

var HEADERS = {
  date: '日期',
  category: '類別',
  receipts: '收據編號',
  description: '說明',
  amount: '支出金額',
  applicant: '申請者',
  payee: '領收者',
  approver: '核准者',
  note: '備註',
};

function onOpen() {
  SpreadsheetApp.getUi().createMenu('零用金')
    .addItem('立即同步', 'syncNow')
    .addItem('測試連線', 'testConnection')
    .addToUi();
}

/** 建立每 1 分鐘自動同步（重複執行只會留一個） */
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'sync') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('sync').timeBased().everyMinutes(1).create();
  Logger.log('已建立每 1 分鐘自動同步');
}

/** 選單：立即同步 */
function syncNow() {
  var n = sync();
  SpreadsheetApp.getUi().alert(n ? '已寫入 ' + n + ' 筆。' : '目前沒有待寫入的申請。');
}

/** 選單：只讀取，不寫入 */
function testConnection() {
  var rows = rpc_('petty_sheet_pending', {});
  SpreadsheetApp.getUi().alert('連線成功，目前有 ' + rows.length + ' 筆待寫入。');
}

/** 自動同步（時間觸發）；回傳寫入筆數 */
function sync() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) return 0;   // 另一次同步還在跑
  try {
    var rows = rpc_('petty_sheet_pending', {});
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var written = 0;
    var errors = [];
    rows.forEach(function (r) {
      var sheet = ss.getSheetByName(r.year + '年') || ss.getSheetByName(r.year);
      if (!sheet) {
        errors.push(r.request_no + '：找不到分頁「' + r.year + '年」，請先建立該年度分頁');
        return;
      }
      appendRow_(sheet, r);
      SpreadsheetApp.flush();
      rpc_('petty_sheet_done', { p_ids: [r.id] });   // 一筆寫完就回報，避免中斷時重複寫入
      written++;
    });
    if (errors.length) throw new Error(errors.join('\n'));
    return written;
  } finally {
    lock.releaseLock();
  }
}

function appendRow_(sheet, r) {
  var head = findHeader_(sheet);
  var dateCol = head.cols.date;
  var last = lastDataRow_(sheet, dateCol, head.row);
  var target = last + 1;

  // 下一列有其他內容（例如合計）就插入新列，不覆蓋
  var width = sheet.getLastColumn();
  if (target > sheet.getMaxRows()) {
    sheet.insertRowAfter(last);
  } else if (sheet.getRange(target, 1, 1, width).getValues()[0].some(function (v) { return v !== ''; })) {
    sheet.insertRowAfter(last);
  }

  // 複製上一列的格式與下拉選單（第一筆資料時上一列是標題，就不複製）
  if (last > head.row) {
    var src = sheet.getRange(last, 1, 1, width);
    var dst = sheet.getRange(target, 1, 1, width);
    src.copyTo(dst, SpreadsheetApp.CopyPasteType.PASTE_FORMAT, false);
    src.copyTo(dst, SpreadsheetApp.CopyPasteType.PASTE_DATA_VALIDATION, false);
  }

  // 用試算表的時區轉日期（Apps Script 預設是美國時區，直接 new Date 會差一天）
  var tz = sheet.getParent().getSpreadsheetTimeZone();
  var values = {
    date: Utilities.parseDate(r.date, tz, 'yyyy/MM/dd'),
    category: r.category,
    receipts: r.receipts,
    description: r.description,
    amount: Number(r.amount),
    applicant: r.applicant,
    payee: r.payee,
    approver: r.approver,
    note: r.note,
  };
  Object.keys(values).forEach(function (k) {
    if (head.cols[k]) sheet.getRange(target, head.cols[k]).setValue(values[k]);
  });

  // 原本手填時「核准者」多半空白、沒設對齊：照「申請者」欄的對齊方式
  if (head.cols.approver && head.cols.applicant) {
    var ref = sheet.getRange(target, head.cols.applicant);
    sheet.getRange(target, head.cols.approver)
      .setHorizontalAlignment(ref.getHorizontalAlignment())
      .setVerticalAlignment(ref.getVerticalAlignment());
  }
}

/** 找標題列與各欄位置（欄號從 1 起算） */
function findHeader_(sheet) {
  var top = sheet.getRange(1, 1, Math.min(5, sheet.getMaxRows()), sheet.getLastColumn()).getValues();
  for (var i = 0; i < top.length; i++) {
    var line = top[i].map(function (v) { return String(v).replace(/\s/g, ''); });
    if (line.indexOf(HEADERS.date) >= 0 && line.indexOf(HEADERS.category) >= 0) {
      var cols = {};
      Object.keys(HEADERS).forEach(function (k) {
        var c = line.indexOf(HEADERS[k]);
        if (c >= 0) cols[k] = c + 1;
      });
      return { row: i + 1, cols: cols };
    }
  }
  throw new Error('分頁「' + sheet.getName() + '」前 5 列找不到含「日期」「類別」的標題列');
}

/** 「日期」欄最後一筆有值的列 */
function lastDataRow_(sheet, col, headerRow) {
  var n = sheet.getLastRow();
  if (n <= headerRow) return headerRow;
  var vals = sheet.getRange(headerRow + 1, col, n - headerRow, 1).getValues();
  for (var i = vals.length - 1; i >= 0; i--) {
    if (vals[i][0] !== '') return headerRow + 1 + i;
  }
  return headerRow;
}

function rpc_(name, body) {
  var props = PropertiesService.getScriptProperties();
  var url = props.getProperty('SUPABASE_URL');
  var key = props.getProperty('SUPABASE_ANON_KEY');
  var secret = props.getProperty('SHEET_SECRET');
  if (!url || !key || !secret) throw new Error('請先在「專案設定 → 指令碼屬性」填 SUPABASE_URL、SUPABASE_ANON_KEY、SHEET_SECRET');
  body.p_secret = secret;
  var res = UrlFetchApp.fetch(url.replace(/\/$/, '') + '/rest/v1/rpc/' + name, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: key, Authorization: 'Bearer ' + key },
    payload: JSON.stringify(body),
    muteHttpExceptions: true,
  });
  var text = res.getContentText();
  if (res.getResponseCode() >= 300) {
    var m = text;
    try { m = JSON.parse(text).message || text; } catch (e) {}
    throw new Error(name + ' 失敗：' + m);
  }
  return text ? JSON.parse(text) : null;
}
