// ============================================================
// deploy-flow.mjs —— Cloudflare Deploy Engine GUI 端到端部署流（CDP 驱动）
// 流程：首启遮罩 → 保存凭证 → 模板选择 → DryRun → 真实部署（验证 URL/探针）
//       → 历史记录 → 销毁项目。所有产物写入 CDE_E2E_BASE。
// 凭证经环境变量传入（不落盘、不写日志原文）。
// ============================================================
import fs from 'node:fs';

const BASE = process.env.CDE_E2E_BASE || 'E:/Personal Development Project/Cloudflare Deploy Engine/_ui-e2e';
const PORT = Number(process.env.CDE_E2E_CDP_PORT || 9345);
const TOKEN = process.env.CDE_E2E_TOKEN || '';
const ACCOUNT = process.env.CDE_E2E_ACCOUNT || '';
const EMAIL = process.env.CDE_E2E_EMAIL || 'tester@cde.local';
const PROJECT = process.env.CDE_E2E_PROJECT || ('cde-e2e-ui' + Date.now().toString().slice(-6));
const NO_DESTROY = process.env.CDE_E2E_NO_DESTROY === '1';
const QUICK = process.env.CDE_E2E_QUICK === '1';
const LOG = BASE + '/driver.log';
const RES = BASE + '/results.json';
const SHOTS = BASE + '/shots';

const results = { steps: [], env: { base: BASE, project: PROJECT, accountMasked: ACCOUNT ? ACCOUNT.slice(0, 4) + '…' : '', tokenLen: TOKEN.length, email: EMAIL } };
const log = (...a) => { try { fs.appendFileSync(LOG, new Date().toISOString() + ' ' + a.join(' ') + '\n'); } catch (e) {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let api = null;   // CDP 连接（模块级，step/waitSettled 闭包共用）

fs.mkdirSync(SHOTS, { recursive: true });
fs.rmSync(BASE + '/app/data', { recursive: true, force: true });

async function jsonOk(url) {
  try { const r = await fetch(url, { signal: AbortSignal.timeout(3000) }); if (!r.ok) return null; return await r.json(); } catch (e) { return null; }
}
function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0;
    const pending = new Map();
    const api = {
      send(method, params = {}) { return new Promise((res, rej) => { const mid = ++id; pending.set(mid, { res, rej }); ws.send(JSON.stringify({ id: mid, method, params })); }); },
      close() { try { ws.close(); } catch (e) {} }
    };
    ws.onopen = () => resolve(api);
    ws.onerror = () => reject(new Error('ws error'));
    ws.onmessage = (ev) => {
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); }
    };
  });
}
async function evalJs(api, expr) {
  const r = await api.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) return { __exc: (r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text };
  return r.result ? r.result.value : undefined;
}
async function step(name, expr, opts) {
  const waitMs = (opts && opts.wait) || 0;
  const v = await evalJs(api, expr);
  if (waitMs) await sleep(waitMs);
  results.steps.push({ step: name, value: v });
  log('STEP ' + name + ' => ' + JSON.stringify(v).slice(0, 400));
  return v;
}
async function shot(api, name) {
  try {
    const r = await api.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(SHOTS + '/' + name + '.png', Buffer.from(r.data, 'base64'));
    log('SHOT ' + name + '.png');
  } catch (e) { log('shot fail ' + name + ': ' + e.message); }
}
// 等待引擎任务收尾：status 离开"运行中…（可取消）"或超时
async function waitSettled(api, label, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const s = await evalJs(api, `document.getElementById('status').textContent`);
    if (s && s.indexOf('运行中') < 0) return s;
    await sleep(2000);
  }
  return 'TIMEOUT_WAIT_' + label;
}

try {
  await sleep(6000);

  // ---- 连接应用页 ----
  let realPage = null;
  for (let i = 0; i < 30; i++) {
    const ts = await jsonOk('http://127.0.0.1:' + PORT + '/json/list');
    if (ts) { realPage = ts.find((t) => t.type === 'page' && t.url && t.url.indexOf('127.0.0.1') >= 0); if (realPage) break; }
    await sleep(1000);
  }
  if (!realPage) { results.fatal = 'no-real-page'; fs.writeFileSync(RES, JSON.stringify(results, null, 2)); process.exit(2); }
  const api2 = await connect(realPage.webSocketDebuggerUrl);
  api = api2;
  await api.send('Runtime.enable');
  await api.send('Page.enable');
  log('connected ' + realPage.url);

  // ---- 就绪等待 + 错误挂钩 ----
  let uiReady = false;
  for (let i = 0; i < 60; i++) {
    const v = await evalJs(api, `!!document.getElementById('status')`);
    if (v === true) { uiReady = true; break; }
    await sleep(500);
  }
  results.uiReady = uiReady;
  await evalJs(api, `window.__errs=[]; window.addEventListener('error',e=>window.__errs.push('ERR:'+e.message)); window.addEventListener('unhandledrejection',e=>window.__errs.push('UNH:'+((e.reason&&(e.reason.message||e.reason))||e.reason))); 'ok'`);

  // ---- 1. 首启遮罩（init 完成后应弹出）----
  let overlayShown = false;
  for (let i = 0; i < 60; i++) {
    const c = await evalJs(api, `document.getElementById('firstRun').className`);
    if (c === 'overlay') { overlayShown = true; break; }
    if (c === 'overlay hidden') break;
    await sleep(1000);
  }
  results.steps.push({ step: 'overlayDetected', value: overlayShown });
  if (overlayShown) {
    await shot(api, '01-firstrun-overlay');
    await evalJs(api, `document.getElementById('btnFirstRunOk').click(); 'clicked'`);
    await sleep(2000);
    results.steps.push({ step: 'overlayAfterOk', value: await evalJs(api, `document.getElementById('firstRun').className`) });
  }

  // ---- 2. 保存凭证（GUI 全链路：表单 → config-manager → DPAPI）----
  await step('fillCred', `document.getElementById('accountId').value=${JSON.stringify(ACCOUNT)}; document.getElementById('email').value=${JSON.stringify(EMAIL)}; document.getElementById('apiToken').value=${JSON.stringify(TOKEN)}; 'filled'`);
  await evalJs(api, `document.getElementById('btnSaveCred').click(); 'clicked'`);
  const saveStatus = await waitSettled(api, 'save', 60000);
  results.steps.push({ step: 'saveCredStatus', value: saveStatus });
  results.steps.push({ step: 'configFileExists', value: fs.existsSync(BASE + '/app/data/config.enc.json') });
  log('configFileExists=' + results.steps[results.steps.length - 1].value);

  // ---- 3. 模板清单已装载 + 项目名 ----
  await step('templatesLoaded', `JSON.stringify({count:document.getElementById('templateId').options.length, first:document.getElementById('templateId').options[0]&&document.getElementById('templateId').options[0].textContent, value:document.getElementById('templateId').value})`);
  await step('setProject', `document.getElementById('projectName').value=${JSON.stringify(PROJECT)}; 'ok'`);

  // ---- 4. DryRun 演练（不触碰云端）----
  await evalJs(api, `document.getElementById('btnDryRun').click(); 'clicked'`);
  const dryStatus = await waitSettled(api, 'dryrun', 120000);
  const dryResult = await evalJs(api, `JSON.stringify({status:document.getElementById('status').textContent, result:(document.getElementById('result').textContent||'').slice(0,600)})`);
  results.steps.push({ step: 'dryRun', value: { status: dryStatus, result: dryResult } });
  log('dryRun => ' + dryResult.slice(0, 400));

  // ---- 5. 真实部署（完整云端流程）----
  await shot(api, '02-before-deploy');
  // 部署前挂载原始事件钩子（抓 RESULT 原文，诊断面板渲染）
  await evalJs(api, `window.__raw=[]; Neutralino.events.on('spawnedProcess',e=>window.__raw.push({a:e.detail.action,d:String(e.detail.data||'').slice(0,9000)})); 'hooked'`);
  await evalJs(api, `document.getElementById('btnDeploy').click(); 'clicked'`);
  const deployStatus = await waitSettled(api, 'deploy', 600000);
  await sleep(3000);   // 渲染宽限（结果面板在 settle 后写入）
  const deployResult = await evalJs(api, `JSON.stringify({status:document.getElementById('status').textContent, result:(document.getElementById('result').textContent||'').slice(0,1200), resultHtml:(document.getElementById('result').innerHTML||'').slice(0,1200), logTail:(document.getElementById('log').textContent||'').slice(-1200)})`);
  const deployRaw = await evalJs(api, `JSON.stringify((window.__raw||[]).filter(e=>e.a==='stdOut'&&e.d.indexOf('RESULT|')>=0))`);
  // 页面侧重放：把全部 stdout 块拼回完整行，验证 RESULT 是否能解析出完整对象
  const replay = await evalJs(api, `(()=>{const s=(window.__raw||[]).map(e=>e.a==='stdOut'?e.d:'').join('');const ls=s.split(/\\r?\\n/);const rl=ls.filter(l=>l.startsWith('RESULT|')&&l.indexOf('deploymentId')>=0);const full=rl[0]||'';let parsed=null,err=null;try{parsed=JSON.parse(full.slice(full.indexOf('|')+1));}catch(e){err=e.message;}let manualRender=null;if(parsed&&!err){try{renderResult(parsed);manualRender=(document.getElementById('result').textContent||'').slice(0,200);}catch(e){manualRender='RENDER-ERR:'+e.message;}}return JSON.stringify({chunks:window.__raw.length, lineLen:full.length, err:err, keys:parsed?Object.keys(parsed):null, url:parsed&&parsed.url, servingOk:parsed&&parsed.servingOk, attempts:parsed&&parsed.attempts, manualRender:manualRender});})()`)
  await shot(api, '03-after-deploy');
  results.steps.push({ step: 'deploy', value: { status: deployStatus, state: deployResult, rawEvents: deployRaw, replay } });
  log('deploy replay => ' + JSON.stringify(replay));
  log('deploy => ' + deployResult.slice(0, 500));

  // ---- 5b. 外部激活验证：轮询 https://<project>.pages.dev 直到 200（最长 10 分钟；QUICK=1 跳过）----
  const siteUrl = 'https://' + PROJECT + '.pages.dev';
  results.steps.push({ step: 'externalSite', value: siteUrl });
  let ext = { ok: false, attempts: 0, first200ms: 0, finalStatus: 0, finalStatusText: '', finalBody: '' };
  if (QUICK) {
    ext.skipped = true;
  } else {
    const tExt0 = Date.now();
    for (let i = 0; i < 120; i++) {
      ext.attempts++;
      const t1 = Date.now();
      try {
        const r = await fetch(siteUrl, { signal: AbortSignal.timeout(10000), redirect: 'follow' });
        ext.finalStatus = r.status;
        ext.finalStatusText = r.statusText;
        if (r.ok) {
          ext.ok = true;
          ext.first200ms = Date.now() - tExt0;
          ext.finalBody = (await r.text()).slice(0, 200);
          break;
        } else {
          ext.finalBody = (await r.text()).slice(0, 120);
        }
      } catch (e) { ext.lastErr = String(e.message).slice(0, 120); }
      await sleep(t1 - Date.now() + 5000);
    }
    if (!ext.ok) ext.elapsedMs = Date.now() - tExt0;
  }
  results.steps.push({ step: 'externalActivation', value: ext });
  log('external => ' + JSON.stringify(ext).slice(0, 400));

  // ---- 6. 历史记录（部署成功后自动刷新）----
  await step('historyList', `(document.getElementById('historyList').textContent||'').slice(0,800)`);

  // ---- 7. 销毁项目（confirm 弹窗由驱动接管；CDE_E2E_NO_DESTROY=1 时保留站点供外部核验）----
  if (!NO_DESTROY) {
    await evalJs(api, `window.confirm=()=>true; 'ok'`);
    await evalJs(api, `document.getElementById('btnDestroy').click(); 'clicked'`);
    const destroyStatus = await waitSettled(api, 'destroy', 240000);
    const destroyResult = await evalJs(api, `JSON.stringify({status:document.getElementById('status').textContent, result:(document.getElementById('result').textContent||'').slice(0,600), logTail:(document.getElementById('log').textContent||'').slice(-600)})`);
    results.steps.push({ step: 'destroy', value: { status: destroyStatus, state: destroyResult } });
    log('destroy => ' + destroyResult.slice(0, 500));
    await shot(api, '04-after-destroy');
  } else {
    results.steps.push({ step: 'destroy', value: 'skipped (NO_DESTROY)' });
  }

  // ---- 8. JS 错误收集 ----
  await step('jsErrors', `JSON.stringify(window.__errs||[])`);
  results.ok = true;
} catch (e) {
  results.ok = false;
  results.fatal = e.message;
  log('FATAL ' + e.message);
} finally {
  fs.writeFileSync(RES, JSON.stringify(results, null, 2));
  log('driver done');
}
process.exit(results.ok ? 0 : 1);