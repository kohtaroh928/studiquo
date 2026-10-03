// The dashboard's inbox: the "ユーザー報告" and "自動エラー" tabs. Plain DOM
// code that ends up inside admin.js's page. Everything in these lists came
// from outside — a person's free text, an app's crash symbols — so it is
// only ever put on the page through textContent, never as markup.
//
// This is embedded in a JS template literal, so it must not contain a
// backtick, a dollar-brace sequence or a backslash.
export const INBOX_CSS = `
  .tabs { display: flex; gap: 0.5rem; margin: 2rem 0 0.75rem; }
  .tabs button { font: inherit; padding: 0.4rem 0.9rem; border-radius: 8px; cursor: pointer;
    border: 1px solid color-mix(in srgb, currentColor 25%, transparent); background: transparent; color: inherit; }
  .tabs button[aria-selected="true"] { background: #2a54a0; color: #fff; border-color: #2a54a0; }
  .toolbar { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; margin-bottom: 0.75rem; color: #888; font-size: 0.9rem; }
  .item { border: 1px solid color-mix(in srgb, currentColor 15%, transparent); border-radius: 10px; padding: 0.9rem 1rem; margin-bottom: 0.75rem; }
  .item .meta { color: #888; font-size: 0.82rem; display: flex; gap: 0.6rem; flex-wrap: wrap; }
  .item .body { white-space: pre-wrap; word-break: break-word; margin: 0.4rem 0; }
  .item .title { font-weight: 600; word-break: break-word; margin: 0.3rem 0; }
  .item pre { white-space: pre-wrap; word-break: break-all; font-size: 0.78rem; max-height: 16rem; overflow: auto; }
  .item .controls { display: flex; gap: 0.5rem; align-items: flex-start; flex-wrap: wrap; margin-top: 0.5rem; }
  .item textarea { flex: 1; min-width: 12rem; font: inherit; min-height: 2.4rem; }
  .badge { border-radius: 6px; padding: 0 0.4rem; background: color-mix(in srgb, currentColor 12%, transparent); }
  .empty { color: #888; padding: 1rem 0; }
`;

export const INBOX_HTML = `
<h2 id="inbox">受信箱</h2>
<div class="tabs" role="tablist">
  <button id="tab-reports" role="tab" type="button">ユーザー報告</button>
  <button id="tab-errors" role="tab" type="button">自動エラー</button>
</div>
<div class="toolbar">
  <label>状態
    <select id="inbox-status">
      <option value="open">未対応</option>
      <option value="in_progress">対応中</option>
      <option value="resolved">対応済み</option>
      <option value="all">すべて</option>
    </select>
  </label>
  <label id="sort-label">並び順
    <select id="inbox-sort">
      <option value="recent">新しい順</option>
      <option value="count">発生回数順</option>
    </select>
  </label>
  <button id="import-legacy" type="button">過去の報告を取り込む</button>
  <span id="inbox-message"></span>
</div>
<div id="inbox-list"></div>
`;

export const INBOX_SCRIPT = `
(function () {
  var STATUS_LABELS = { open: '未対応', in_progress: '対応中', resolved: '対応済み' };
  var KIND_LABELS = { crash: 'クラッシュ', hang: 'フリーズ', cpu: 'CPU過負荷', disk: 'ディスク書き込み過多', error: 'エラー' };
  var state = { tab: location.hash === '#errors' ? 'errors' : 'reports' };

  function el(tag, text, className) {
    var node = document.createElement(tag);
    if (text != null) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function when(ms) { return new Date(ms).toLocaleString('ja-JP'); }
  function message(text) { document.getElementById('inbox-message').textContent = text || ''; }

  function post(path, body) {
    return fetch(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (r) {
      if (!r.ok) throw new Error('bad response');
      return r.json();
    });
  }

  function controls(item, path) {
    var box = el('div', null, 'controls');
    var select = el('select');
    Object.keys(STATUS_LABELS).forEach(function (value) {
      var option = el('option', STATUS_LABELS[value]);
      option.value = value;
      if (value === item.status) option.selected = true;
      select.appendChild(option);
    });
    var note = el('textarea');
    note.placeholder = 'メモ';
    note.value = item.note || '';
    var save = el('button', '保存');
    save.type = 'button';
    save.addEventListener('click', function () {
      save.disabled = true;
      post(path, { status: select.value, note: note.value }).then(function () {
        message('保存しました');
        loadInbox();
        loadStatsCounts();
      }).catch(function () {
        message('保存に失敗しました');
        save.disabled = false;
      });
    });
    box.appendChild(select);
    box.appendChild(note);
    box.appendChild(save);
    return box;
  }

  function reportItem(report) {
    var item = el('div', null, 'item');
    var meta = el('div', null, 'meta');
    [when(report.createdAt), STATUS_LABELS[report.status], report.appVersion && ('v' + report.appVersion),
      report.osVersion && ('iOS ' + report.osVersion), report.deviceModel, report.language
    ].filter(Boolean).forEach(function (text) { meta.appendChild(el('span', text)); });
    item.appendChild(meta);
    item.appendChild(el('div', report.description, 'body'));
    if (report.screenshotURL) {
      var link = el('a', 'スクリーンショットを開く');
      link.href = report.screenshotURL;
      link.target = '_blank';
      link.rel = 'noopener';
      item.appendChild(link);
    }
    item.appendChild(controls(report, '/api/admin/issue-reports/' + report.id));
    return item;
  }

  function errorItem(error) {
    var item = el('div', null, 'item');
    var meta = el('div', null, 'meta');
    meta.appendChild(el('span', KIND_LABELS[error.kind] || 'エラー', 'badge'));
    [STATUS_LABELS[error.status], error.occurrences + '回', error.affectedUsers + '人',
      '初回 ' + when(error.firstSeenAt), '最終 ' + when(error.lastSeenAt),
      error.lastAppVersion && ('v' + error.lastAppVersion), error.lastOSVersion && ('iOS ' + error.lastOSVersion),
      error.lastDeviceModel
    ].filter(Boolean).forEach(function (text) { meta.appendChild(el('span', text)); });
    item.appendChild(meta);
    item.appendChild(el('div', error.title, 'title'));
    if (error.detail) {
      var details = el('details');
      details.appendChild(el('summary', '詳細'));
      details.appendChild(el('pre', error.detail));
      item.appendChild(details);
    }
    item.appendChild(controls(error, '/api/admin/app-errors/' + error.fingerprint));
    return item;
  }

  function loadInbox() {
    var status = document.getElementById('inbox-status').value;
    var isErrors = state.tab === 'errors';
    var query = '?status=' + encodeURIComponent(status) + (isErrors ? '&sort=' + document.getElementById('inbox-sort').value : '');
    fetch('/api/admin/' + (isErrors ? 'app-errors' : 'issue-reports') + query).then(function (r) {
      if (!r.ok) throw new Error('bad response');
      return r.json();
    }).then(function (data) {
      var list = document.getElementById('inbox-list');
      list.textContent = '';
      var rows = isErrors ? data.errors : data.reports;
      if (!rows.length) list.appendChild(el('div', '該当するものはありません。', 'empty'));
      rows.forEach(function (row) { list.appendChild(isErrors ? errorItem(row) : reportItem(row)); });
    }).catch(function () { message('読み込みに失敗しました'); });
  }

  function loadStatsCounts() {
    fetch('/api/admin/stats').then(function (r) { return r.json(); }).then(function (stats) {
      var reports = document.getElementById('count-reports');
      var errors = document.getElementById('count-errors');
      if (reports) reports.textContent = stats.issueReportCount;
      if (errors) errors.textContent = stats.appErrorCount;
    }).catch(function () {});
  }

  function select(tab) {
    state.tab = tab;
    document.getElementById('tab-reports').setAttribute('aria-selected', tab === 'reports');
    document.getElementById('tab-errors').setAttribute('aria-selected', tab === 'errors');
    document.getElementById('sort-label').style.display = tab === 'errors' ? '' : 'none';
    document.getElementById('import-legacy').style.display = tab === 'reports' ? '' : 'none';
    message('');
    loadInbox();
  }

  document.getElementById('tab-reports').addEventListener('click', function () { select('reports'); });
  document.getElementById('tab-errors').addEventListener('click', function () { select('errors'); });
  document.getElementById('inbox-status').addEventListener('change', loadInbox);
  document.getElementById('inbox-sort').addEventListener('change', loadInbox);
  document.getElementById('import-legacy').addEventListener('click', function () {
    post('/api/admin/issue-reports/import-legacy').then(function (result) {
      message(result.imported + '件を取り込みました(' + result.skipped + '件は取り込み済み)');
      loadInbox();
      loadStatsCounts();
    }).catch(function () { message('取り込みに失敗しました'); });
  });
  window.addEventListener('hashchange', function () { select(location.hash === '#errors' ? 'errors' : 'reports'); });
  select(state.tab);
})();
`;
