// These are artificial scanner fixtures, never application code.
// ruleid: studiquo.javascript.dynamic-code
eval(input);
// ruleid: studiquo.javascript.dynamic-code
new Function(input);
// ok: studiquo.javascript.dynamic-code
JSON.parse(input);
// ruleid: studiquo.javascript.unsafe-html
el.innerHTML = input;
// ruleid: studiquo.javascript.unsafe-html
el.insertAdjacentHTML('beforeend', input);
// ok: studiquo.javascript.unsafe-html
el.textContent = input;
// ruleid: studiquo.javascript.disabled-tls
const unsafe = { rejectUnauthorized: false };
// ok: studiquo.javascript.disabled-tls
const safe = { rejectUnauthorized: true };
// ruleid: studiquo.javascript.credential-log
console.log(accessToken);
// ok: studiquo.javascript.credential-log
console.log(status);
// ruleid: studiquo.javascript.weak-hash
crypto.subtle.digest("SHA-1", data);
// ruleid: studiquo.javascript.weak-hash
createHash("md5");
// ok: studiquo.javascript.weak-hash
crypto.subtle.digest("SHA-256", data);
function unsafeFetch(request) {
  const target = new URL(request.url).searchParams.get('target');
  // ruleid: studiquo.javascript.request-fetch
  fetch(target);
}
function safeFetch(request) {
  // ok: studiquo.javascript.request-fetch
  fetch('https://example.invalid');
}
// ruleid: studiquo.javascript.dynamic-sql
db.prepare('SELECT * FROM fixture WHERE id=' + value);
// ok: studiquo.javascript.dynamic-sql
db.prepare('SELECT * FROM fixture WHERE id=?').bind(value);
