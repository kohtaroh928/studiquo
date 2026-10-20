// The dashboard's moderation section: chat reports (read, warn, remove the
// message, suspend chat or the account), people currently suspended, and the
// record of operator actions. Everything shown came from outside (a person's
// message, a reason they typed), so it only ever reaches the page through
// textContent, never as markup. Same constraints as admin-inbox-ui.js: it is
// embedded in a JS template literal, so no backtick, dollar-brace or backslash.
export const MODERATION_HTML = `
<h2 id="moderation">通報と措置</h2>
<div class="tabs" role="tablist">
  <button id="mtab-reports" role="tab" type="button">チャットの通報</button>
  <button id="mtab-suspended" role="tab" type="button">停止中</button>
  <button id="mtab-audit" role="tab" type="button">操作記録</button>
</div>
<div class="toolbar">
  <label id="mod-status-label">状態
    <select id="mod-status">
      <option value="open">未対応</option>
      <option value="in_progress">対応中</option>
      <option value="resolved">対応済み</option>
      <option value="dismissed">却下</option>
      <option value="all">すべて</option>
    </select>
  </label>
  <span id="mod-message"></span>
</div>
<div id="mod-list"></div>
`;

export const MODERATION_SCRIPT = `
(function () {
  var STATUS = { open: '未対応', in_progress: '対応中', resolved: '対応済み', dismissed: '却下' };
  var state = { tab: 'reports' };

  function el(tag, text, className) {
    var node = document.createElement(tag);
    if (text != null) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function when(ms) { return new Date(ms).toLocaleString('ja-JP'); }
  function message(text) { document.getElementById('mod-message').textContent = text || ''; }
  function api(method, path, body) {
    return fetch(path, {
      method: method,
      headers: body === undefined ? {} : { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body)
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (data) {
        if (!r.ok) throw new Error(data.error || 'bad response');
        return data;
      });
    });
  }
  function button(label, onClick) {
    var b = el('button', label);
    b.type = 'button';
    b.addEventListener('click', function () { b.disabled = true; onClick(b); });
    return b;
  }
  // Runs an action after the operator confirms it, then reloads.
  function act(b, question, run, done) {
    if (!window.confirm(question)) { b.disabled = false; return; }
    run().then(function () { message(done); load(); }).catch(function (e) {
      message('失敗しました: ' + e.message);
      b.disabled = false;
    });
  }

  function messagesBox(report) {
    var box = el('div', null, 'body');
    api('GET', '/api/admin/chat-reports/' + report.id).then(function (detail) {
      detail.messages.forEach(function (m) {
        var line = el('div', (m.reported ? '▶ ' : '　') + (m.fromReported ? '[通報された人] ' : '[相手] ') + (m.isCanceled ? '(削除済み)' : m.text));
        if (m.reported) line.style.fontWeight = '600';
        box.appendChild(line);
      });
    }).catch(function () { box.textContent = '本文を読み込めませんでした'; });
    return box;
  }

  function reportItem(report) {
    var item = el('div', null, 'item');
    var meta = el('div', null, 'meta');
    [when(report.createdAt), STATUS[report.status], 'ルーム ' + report.roomID.slice(0, 8)].forEach(function (t) { meta.appendChild(el('span', t)); });
    item.appendChild(meta);
    item.appendChild(el('div', '理由: ' + (report.reason || '(なし)'), 'body'));
    var box = el('div');
    item.appendChild(button('本文を開く(閲覧は記録されます)', function (b) { box.appendChild(messagesBox(report)); b.remove(); }));
    item.appendChild(box);
    var path = '/api/admin/chat-reports/' + report.id;
    var controls = el('div', null, 'controls');
    var select = el('select');
    Object.keys(STATUS).forEach(function (value) {
      var option = el('option', STATUS[value]); option.value = value;
      if (value === report.status) option.selected = true;
      select.appendChild(option);
    });
    var note = el('textarea'); note.placeholder = 'メモ'; note.value = report.note || '';
    controls.appendChild(select);
    controls.appendChild(note);
    controls.appendChild(button('保存', function (b) {
      api('POST', path, { status: select.value, note: note.value }).then(function () { message('保存しました'); load(); })
        .catch(function () { message('保存に失敗しました'); b.disabled = false; });
    }));
    item.appendChild(controls);
    var actions = el('div', null, 'controls');
    actions.appendChild(button('注意を送る', function (b) { act(b, '注意の通知を送ります。よろしいですか?', function () { return api('POST', path + '/warn', {}); }, '注意を送りました'); }));
    actions.appendChild(button('メッセージを削除', function (b) { act(b, 'このメッセージを双方の画面から消します。よろしいですか?', function () { return api('POST', path + '/remove-message', {}); }, 'メッセージを削除しました'); }));
    actions.appendChild(button('チャットを停止', function (b) { act(b, '通報された人のチャットを停止します。よろしいですか?', function () { return api('POST', '/api/admin/accounts/suspend', { reportID: report.id, scope: 'chat' }); }, 'チャットを停止しました'); }));
    actions.appendChild(button('アカウントを停止', function (b) { act(b, '通報された人のアカウントを停止します(退会は可能)。よろしいですか?', function () { return api('POST', '/api/admin/accounts/suspend', { reportID: report.id, scope: 'account' }); }, 'アカウントを停止しました'); }));
    item.appendChild(actions);
    return item;
  }

  function suspendedItem(entry) {
    var item = el('div', null, 'item');
    var meta = el('div', null, 'meta');
    [entry.scope === 'chat' ? 'チャット停止' : 'アカウント停止', entry.at ? when(entry.at) : '', entry.suspensionID.slice(0, 12)].filter(Boolean)
      .forEach(function (t) { meta.appendChild(el('span', t)); });
    item.appendChild(meta);
    var controls = el('div', null, 'controls');
    controls.appendChild(button('解除', function (b) {
      act(b, '停止を解除します。よろしいですか?', function () { return api('POST', '/api/admin/accounts/unsuspend', { suspensionID: entry.suspensionID, scope: entry.scope }); }, '解除しました');
    }));
    item.appendChild(controls);
    return item;
  }

  function auditItem(row) {
    var item = el('div', null, 'item');
    var meta = el('div', null, 'meta');
    [when(row.at), row.actor, row.action, row.target, row.detail].filter(Boolean).forEach(function (t) { meta.appendChild(el('span', t)); });
    item.appendChild(meta);
    return item;
  }

  function load() {
    var list = document.getElementById('mod-list');
    var status = document.getElementById('mod-status').value;
    var request = state.tab === 'reports' ? api('GET', '/api/admin/chat-reports?status=' + encodeURIComponent(status))
      : state.tab === 'suspended' ? api('GET', '/api/admin/accounts/suspended')
      : api('GET', '/api/admin/audit-log');
    var asked = state.tab;
    request.then(function (data) {
      if (asked !== state.tab) return; // an answer for a tab the operator has left
      list.textContent = '';
      var rows = state.tab === 'reports' ? data.reports : state.tab === 'suspended' ? data.suspended : data.entries;
      if (!rows.length) list.appendChild(el('div', '該当するものはありません。', 'empty'));
      rows.forEach(function (row) {
        list.appendChild(state.tab === 'reports' ? reportItem(row) : state.tab === 'suspended' ? suspendedItem(row) : auditItem(row));
      });
    }).catch(function () { message('読み込みに失敗しました'); });
  }

  function select(tab) {
    state.tab = tab;
    ['reports', 'suspended', 'audit'].forEach(function (name) {
      document.getElementById('mtab-' + name).setAttribute('aria-selected', name === tab);
    });
    document.getElementById('mod-status-label').style.display = tab === 'reports' ? '' : 'none';
    message('');
    load();
  }
  ['reports', 'suspended', 'audit'].forEach(function (name) {
    document.getElementById('mtab-' + name).addEventListener('click', function () { select(name); });
  });
  document.getElementById('mod-status').addEventListener('change', load);
  select('reports');
})();
`;
