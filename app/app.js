// ============================================================
// Cloudflare Deploy Engine —— 前端（M2 全量 + Phase2 历史/重部署/i18n/enum）
// 通信：os.spawnProcess → powershell.exe（引擎脚本），stdout 逐行
// 解析 LOG|ts|LEVEL|msg（实时滚动）与 RESULT|<json>（最终结果）。
// 参数安全通道：JSON/文本一律 Base64(UTF-8) 传递（-ParamsB64 等）。
// ============================================================

let engineDir = '';
let running = false;
let procId = null;
let cancelRequested = false;
let watchdogTimer = null;

let templates = [];          // ListTemplates：{id,name}
let templateMetas = {};      // id → meta（含 parameters）
let plugins = [];            // ListPlugins：{axis,axisKey,id,enabled}
let configState = null;      // config-manager get 的结果
let aiState = { baseUrl: '', model: '', apiKey: '' };
let historyCache = [];       // ListHistory：旧→新
let marketCache = { source: '', plugins: [] };
const BUILTIN_PLUGINS = ['local', 'github', 'gitlab', 'zip', 'plain', 'astro-site', 'openai-compatible', 'pages'];

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- 基础工具 ----------
function pathJoin(...parts) { return parts.join('\\'); }

function b64u8(str) {
  const bytes = new TextEncoder().encode(str);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function pad(n) { return String(n).padStart(2, '0'); }
function stamp() {
  const d = new Date();
  return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' +
    pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
}

async function hasDir(p) {
  try { await Neutralino.filesystem.readDirectory(p); return true; }
  catch (e) { return false; }
}

async function resolveEngineDir() {
  // ① exe 同级（打包目录模式） ② resources 路径（neu run 开发模式）
  try {
    const exePath = await Neutralino.os.getPath('exe');
    const exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
    if (await hasDir(pathJoin(exeDir, 'scripts'))) return exeDir;
    const p = await Neutralino.os.getPath('resources');
    if (p && await hasDir(pathJoin(p, 'scripts'))) return p;
    return exeDir;
  } catch (e) {
    const exePath = await Neutralino.os.getPath('exe');
    return exePath.substring(0, exePath.lastIndexOf('\\'));
  }
}

function getConfigPath() { return pathJoin(engineDir, 'data', 'config.enc.json'); }

// ---------- 状态栏 ----------
function setStatus(text, cls) {
  const el = $('status');
  el.textContent = text;
  el.className = 'status' + (cls ? ' ' + cls : '');
}
function showCancelBtn(show) { $('btnCancel').classList.toggle('hidden', !show); }

function updateDynamicI18n() {
  // i18n.applyLang 回调：重置怠速状态文案
  if (!running) setStatus(t('statusIdle'));
}

// ---------- 日志 ----------
function appendLog(line) {
  const log = $('log');
  const div = document.createElement('div');
  const m = line.match(/^LOG\|[^|]*\|(\w+)\|(.*)$/s);
  if (m) { div.className = m[1]; div.textContent = m[2]; }
  else { div.textContent = line; }
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
  return div;
}

function showResultText(text, cls) {
  const el = $('result');
  el.className = 'result' + (cls ? ' ' + cls : '');
  el.textContent = text;
}

// ---------- 引擎调用（可取消 + 看门狗超时） ----------
const WATCHDOG_MS = 25 * 60 * 1000;

function runEngine(args) {
  return new Promise((resolve, reject) => {
    if (running) { reject(new Error('已有任务在运行，请先等待或取消')); return; }
    running = true;
    cancelRequested = false;
    showCancelBtn(true);
    setStatus(t('running'), 'busy');

    const script = args.shift();
    const fullArgs = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', pathJoin(engineDir, 'scripts', script), ...args
    ];

    Neutralino.os.spawnProcess('powershell.exe', fullArgs).then((proc) => {
      procId = proc ? (proc.id != null ? proc.id : proc.pid) : null;
      let finalResult = null;
      let settled = false;

      const settle = (fn) => {
        if (settled) return;
        settled = true;
        running = false;
        procId = null;
        showCancelBtn(false);
        if (watchdogTimer) { clearTimeout(watchdogTimer); watchdogTimer = null; }
        try { Neutralino.events.off('spawnedProcess', onEvent); } catch (e) { /* noop */ }
        fn();
      };

      const onEvent = (evt) => {
        if (settled) return;
        if (evt.detail.id !== procId) return;
        const d = evt.detail;
        if (d.action === 'stdOut') {
          const text = String(d.data).replace(/\r?\n$/, '');
          if (!text) return;
          const parsed = text.startsWith('RESULT|') ? parseResultLine(text) : null;
          if (parsed) {
            finalResult = parsed;
            renderResult(parsed);
          } else {
            appendLog(text);
          }
        } else if (d.action === 'stdErr') {
          appendLog('[stderr] ' + String(d.data).replace(/\r?\n$/, ''));
        } else if (d.action === 'exit') {
          if (cancelRequested) {
            setStatus(t('cancelled'), 'fail');
            settle(() => reject(new Error('任务已取消')));
          } else if (finalResult) {
            setStatus(t('done'), 'done');
            settle(() => resolve(finalResult));
          } else {
            const code = d.data;
            setStatus(t('failed') + ' · exit=' + code, 'fail');
            settle(() => reject(new Error('引擎异常退出（exit=' + code + '），详见日志')));
          }
        }
      };

      Neutralino.events.on('spawnedProcess', onEvent);
      watchdogTimer = setTimeout(() => {
        if (settled) return;
        appendLog('[watchdog] 任务超过 25 分钟，自动终止');
        cancelRequested = true;
        if (procId != null) { try { Neutralino.os.killProcess(procId); } catch (e) { /* noop */ } }
      }, WATCHDOG_MS);
    }).catch((e) => {
      running = false;
      showCancelBtn(false);
      setStatus(t('failed'), 'fail');
      reject(e);
    });
  });
}

function parseResultLine(line) {
  const idx = line.indexOf('|');
  if (idx < 0) return null;
  try { return JSON.parse(line.substring(idx + 1)); } catch (e) { return null; }
}

async function cancelRun() {
  if (!running || procId == null) return;
  cancelRequested = true;
  appendLog('✋ 正在取消…');
  setStatus(t('cancelled') + '…', 'busy');
  try { await Neutralino.os.killProcess(procId); }
  catch (e) { appendLog('[warn] 终止进程失败：' + e); }
}

// ---------- 结果渲染 ----------
function esc(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function td(k, v, cls) {
  if (v === undefined || v === null || v === '') return '';
  return '<tr><td class="k">' + esc(k) + '</td><td class="' + (cls || '') + '">' + esc(v) + '</td></tr>';
}

function renderResult(obj) {
  const el = $('result');
  el.classList.remove('err', 'warn');
  if (!obj) { el.innerHTML = '—'; return; }
  if (obj.error) {
    el.classList.add('err');
    el.innerHTML = '<div class="err">❌ ' + esc(obj.error) + '</div>';
    setStatus(t('failed'), 'fail');
    return;
  }
  let html = '<table>';
  if (obj.url) {
    html += '<tr><td class="k">' + (obj.dryRun ? 'URL' : '站点 URL') + '</td><td><a href="' + esc(obj.url) + '" target="_blank">' + esc(obj.url) + '</a></td></tr>';
  }
  html += td('项目名', obj.project);
  if (obj.servingOk === true) {
    html += '<tr><td class="k">探针验收</td><td class="ok">✅ 边缘存活（HTTP ' + esc(obj.probeCode) + '）</td></tr>';
  } else if (obj.servingOk === false) {
    html += '<tr><td class="k">探针验收</td><td class="warn">⚠️ 3 次尝试后未在边缘激活（HTTP ' + esc(obj.probeCode) + '）— 平台侧故障窗口，可稍后重试或切 wrangler 后端</td></tr>';
  }
  html += td('部署尝试', obj.attempts ? ('第 ' + obj.attempts + ' 次成功') : '');
  html += td('后端', obj.backend);
  html += td('文件数', obj.files);
  html += td('部署 ID', obj.deploymentId);
  html += td('部署 short_id', obj.deploymentShortId);
  if (obj.meta && obj.meta.template) html += td('模板', obj.meta.template);
  if (obj.meta && obj.meta.source) html += td('来源', obj.meta.source);
  if (obj.dryRun) html += '<tr><td class="k">模式</td><td class="warn">⚪ DryRun 演练（未触碰云端）</td></tr>';
  html += '</table>';
  el.innerHTML = html;
  setStatus(t('done'), 'done');
}

// ---------- 配置装载 / 首启 ----------
async function isFirstRun() {
  try {
    await Neutralino.filesystem.readFile(pathJoin(engineDir, 'data', 'config.enc.json'));
    return false;
  } catch (e) {
    return true;
  }
}

async function loadConfig() {
  if (await isFirstRun()) {
    showFirstRun();
    return null;
  }
  try {
    const r = await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'get']);
    if (r && r.error && r.error.indexOf('配置文件不存在') >= 0) {
      showFirstRun();
      return null;
    }
    configState = r;
    if (r && r.secrets) {
      $('accountId').value = r.secrets.accountId || '';
      $('email').value = r.secrets.email || '';
      $('apiToken').value = r.secrets.apiToken || '';
    }
    if (r && r.settings) {
      if (r.settings.pagesProject) $('projectName').value = r.settings.pagesProject;
      if (r.settings.lastTemplate && templates.some((t) => t.id === r.settings.lastTemplate)) {
        $('templateId').value = r.settings.lastTemplate;
      }
      // A5 参数记忆：上次部署的同模板参数回填
      if (r.settings.lastTemplateParams && r.settings.lastTemplate === $('templateId').value) {
        await renderTemplateParams(r.settings.lastTemplateParams);
      }
    }
    aiState = (r && r.ai) ? {
      baseUrl: r.ai.baseUrl || '', model: r.ai.model || '', apiKey: r.ai.apiKey || ''
    } : { baseUrl: '', model: '', apiKey: '' };
    return r;
  } catch (e) {
    appendLog('[warn] 读取配置失败：' + e.message);
    return null;
  }
}

function showFirstRun() {
  $('firstRun').classList.remove('hidden');
}

// ---------- 模板 / 来源 装载 ----------
async function loadTemplates() {
  const r = await runEngine(['deploy-core.ps1', '-ListTemplates']);
  if (!r || r.error) { appendLog('[warn] 模板清单失败：' + (r ? r.error : '无响应')); return; }
  templates = r.templates || [];
  const sel = $('templateId');
  sel.innerHTML = '';
  for (const t of templates) {
    const opt = document.createElement('option');
    opt.value = t.id;
    opt.textContent = t.name + '（' + t.id + '）';
    sel.appendChild(opt);
  }
  if (sel.options.length && !sel.value) sel.value = sel.options[0].value;
  await renderTemplateParams();
}

async function getTemplateMeta(id) {
  if (templateMetas[id]) return templateMetas[id];
  const r = await runEngine(['template-manager.ps1', id]);
  if (r && !r.error) templateMetas[id] = r;
  return templateMetas[id] || { parameters: [] };
}

function renderParamControl(p, v) {
  // A4：type=enum → select；其余 → text input
  if (p.type === 'enum' && Array.isArray(p.enum)) {
    const sel = document.createElement('select');
    for (const opt of p.enum) {
      const o = document.createElement('option');
      o.value = opt; o.textContent = opt;
      sel.appendChild(o);
    }
    if (v !== undefined && p.enum.indexOf(v) >= 0) sel.value = v;
    else sel.value = p.default !== undefined ? p.default : (p.enum[0] || '');
    return sel;
  }
  const input = document.createElement('input');
  input.dataset.param = p.name;
  input.value = v === undefined ? '' : String(v);
  return input;
}

async function renderTemplateParams(prefill) {
  const id = $('templateId').value;
  if (!id) { $('tplParams').innerHTML = '<p class="hint">暂无可用模板（检查 plugins.json）</p>'; return; }
  const meta = await getTemplateMeta(id);
  const box = $('tplParams');
  box.innerHTML = '';
  for (const p of (meta.parameters || [])) {
    const label = document.createElement('label');
    label.className = 'dyn-field';
    label.textContent = (p.label || p.name) + (p.type ? '（' + p.type + '）' : '');
    const v = (prefill && prefill[p.name] !== undefined) ? prefill[p.name] : p.default;
    const ctl = renderParamControl(p, v);
    ctl.dataset.param = p.name;
    label.appendChild(ctl);
    box.appendChild(label);
  }
}

function collectParams() {
  const out = {};
  document.querySelectorAll('#tplParams input[data-param], #tplParams select[data-param]').forEach((el) => {
    const v = el.value.trim();
    if (v !== '') out[el.dataset.param] = v;
  });
  return out;
}

async function loadPlugins() {
  const r = await runEngine(['deploy-core.ps1', '-ListPlugins']);
  if (!r || r.error) { appendLog('[warn] 插件清单失败：' + (r ? r.error : '无响应')); return; }
  plugins = r.plugins || [];
  populateSourceSelect();
  renderSourceFields();
}

function populateSourceSelect() {
  const sel = $('sourceId');
  sel.innerHTML = '';
  const enabledSources = plugins.filter((p) => p.axisKey === 'sources' && p.enabled);
  if (enabledSources.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '（无已启用来源插件，检查 plugins.json）';
    sel.appendChild(opt);
    return;
  }
  const labels = { local: '📁 本地文件夹', github: '🐙 GitHub 仓库（codeload，零依赖）', gitlab: '🦊 GitLab 仓库', zip: '📦 本地压缩包（zip/tar/tgz）' };
  for (const p of enabledSources) {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = labels[p.id] || p.id;
    sel.appendChild(opt);
  }
  sel.value = sel.options[0].value;
}

// ---------- 来源动态字段 ----------
function renderSourceFields() {
  const id = $('sourceId').value;
  const box = $('srcFields');
  box.innerHTML = '';
  if (id === 'local') {
    box.innerHTML =
      '<label class="dyn-field">文件夹路径' +
      '<span class="src-browse"><input id="srcPath" placeholder="C:\\my-site" autocomplete="off">' +
      '<button id="btnBrowseDir" class="tiny" type="button">浏览…</button></span></label>';
    $('btnBrowseDir').onclick = browseFolder;
  } else if (id === 'github' || id === 'gitlab') {
    box.innerHTML =
      '<label class="dyn-field">仓库地址' +
      '<input id="gitUrl" placeholder="' + (id === 'github' ? 'owner/repo 或 https://github.com/owner/repo' : 'group/project 或 https://gitlab.com/group/project') + '" autocomplete="off"></label>' +
      '<label class="dyn-field">分支 / Tag（留空 = 默认分支）' +
      '<input id="gitRef" placeholder="' + (id === 'github' ? 'main' : 'main') + '" autocomplete="off"></label>';
  } else if (id === 'zip') {
    box.innerHTML =
      '<label class="dyn-field">压缩包路径' +
      '<span class="src-browse"><input id="zipPath" placeholder="C:\\site.zip" autocomplete="off">' +
      '<button id="btnBrowseZip" class="tiny" type="button">浏览…</button></span></label>';
    $('btnBrowseZip').onclick = browseZip;
  }
}

async function browseFolder() {
  try {
    const p = await Neutralino.os.showFolderDialog('选择待部署文件夹');
    if (p) $('srcPath').value = String(p).replace(/\\+$/, '') + '\\';
  } catch (e) {
    appendLog('[warn] 无法打开文件夹选择器（' + e + '），请手动输入路径');
  }
}

async function browseZip() {
  try {
    const p = await Neutralino.os.showOpenDialog({
      title: '选择压缩包（zip/tar/tgz）',
      multiSelections: false,
      filters: [{ name: '压缩包', extensions: ['zip', 'tar', 'gz', 'tgz'] }]
    });
    if (p) $('zipPath').value = Array.isArray(p) ? p[0] : String(p);
  } catch (e) {
    appendLog('[warn] 无法打开文件选择器（' + e + '），请手动输入路径');
  }
}

function collectSourceArgs() {
  const id = $('sourceId').value;
  if (id === 'local') {
    const p = $('srcPath').value.trim();
    if (!p) throw new Error('请填写本地文件夹路径');
    return { Path: p };
  }
  if (id === 'github' || id === 'gitlab') {
    const u = $('gitUrl').value.trim();
    if (!u) throw new Error('请填写仓库地址');
    const args = { Url: u };
    const ref = $('gitRef').value.trim();
    if (ref) args.Ref = ref;
    return args;
  }
  const p = $('zipPath').value.trim();
  if (!p) throw new Error('请填写压缩包路径');
  return { Path: p };
}

// ---------- 凭证 ----------
function wireCredential() {
  $('btnSaveCred').onclick = async () => {
    const fields = [
      ['accountId', $('accountId').value.trim()],
      ['email', $('email').value.trim()],
      ['apiToken', $('apiToken').value.trim()]
    ];
    for (const [f, v] of fields) {
      if (!v) continue;
      await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'set', '-Field', f, '-ValueB64', b64u8(v)]);
    }
    appendLog('LOG|---|INFO|凭证已加密保存（DPAPI）');
  };

  $('btnLoadCred').onclick = async () => {
    await loadConfig();
    appendLog('LOG|---|INFO|已从本地配置解密回填');
  };

  $('btnClearCred').onclick = async () => {
    if (!confirm('确认清除全部本地配置（凭证 + AI 设置 + 项目记忆）？')) return;
    await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'clear']);
    configState = null;
    $('accountId').value = ''; $('email').value = ''; $('apiToken').value = '';
    showResultText('配置已清除', 'warn');
  };

  $('btnToggleToken').onclick = () => {
    const el = $('apiToken');
    el.type = (el.type === 'password') ? 'text' : 'password';
  };
}

// ---------- 导出 / 导入 ----------
function openExport() {
  openModal('📤 导出配置（换机迁移，ADR-003）',
    '<label>导出文件路径（默认 data 目录）<input id="expFile" value="' + pathJoin(engineDir, 'data', 'cde-export-' + stamp() + '.json') + '"></label>' +
    '<label>加密口令（≥8 字符，请牢记）<input id="expPw" type="password" placeholder="用于新机器解密"></label>' +
    '<label>确认口令<input id="expPw2" type="password"></label>' +
    '<p class="hint">导出文件用口令加密（PBKDF2+AES-256），不含任何可还原的明文凭证；凭据不落明文磁盘。</p>',
    async (okBtn) => {
      const f = $('expFile').value.trim();
      const pw = $('expPw').value;
      const pw2 = $('expPw2').value;
      if (!f) { alert('请填写导出路径'); return; }
      if (pw.length < 8) { alert('口令至少 8 个字符'); return; }
      if (pw !== pw2) { alert('两次口令不一致'); return; }
      okBtn.disabled = true;
      const r = await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'export', '-Passphrase', pw, '-OutFile', f]);
      if (r && r.error) alert('导出失败：' + r.error);
      else { appendLog('LOG|---|INFO|导出完成：' + f); closeModal(); }
      okBtn.disabled = false;
    });
}

function openImport() {
  openModal('📥 导入配置（新机器重新 DPAPI 加密）',
    '<label>导入文件路径<input id="impFile" placeholder="C:\\cde-export.json"></label>' +
    '<label>加密口令<input id="impPw" type="password"></label>' +
    '<p class="hint">导入会在本机重新加密（DPAPI CurrentUser 绑定），原文仅存在于内存。</p>',
    async (okBtn) => {
      const f = $('impFile').value.trim();
      const pw = $('impPw').value;
      if (!f || !pw) { alert('请填写文件路径与口令'); return; }
      okBtn.disabled = true;
      const r = await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'import', '-Passphrase', pw, '-InFile', f]);
      if (r && r.error) alert('导入失败：' + r.error);
      else {
        appendLog('LOG|---|INFO|导入完成并重新加密');
        closeModal();
        await loadConfig();
      }
      okBtn.disabled = false;
    });
}

// ---------- 部署 / 销毁 ----------
function buildDeployArgs(dryRun) {
  const proj = $('projectName').value.trim();
  const backend = $('backendSel').value;
  const tplMode = $('segTemplate').classList.contains('active');
  const args = ['deploy-core.ps1', '-ConfigPath', getConfigPath(), '-Backend', backend];
  if (proj) args.push('-Project', proj);
  if (tplMode) {
    const id = $('templateId').value;
    if (!id) throw new Error('请选择模板');
    args.push('-TemplateId', id, '-ParamsB64', b64u8(JSON.stringify(collectParams())));
  } else {
    const sid = $('sourceId').value;
    args.push('-SourceId', sid, '-SourceArgsB64', b64u8(JSON.stringify(collectSourceArgs())));
  }
  if (dryRun) args.push('-DryRun');
  return args;
}

function wireDeploy() {
  $('btnDeploy').onclick = async () => {
    try {
      await runEngine(buildDeployArgs(false));
      await loadHistory();
    } catch (e) {
      showResultText('❌ ' + e.message, 'err');
    }
  };

  $('btnDryRun').onclick = async () => {
    try {
      await runEngine(buildDeployArgs(true));
    } catch (e) {
      showResultText('❌ ' + e.message, 'err');
    }
  };

  $('btnDestroy').onclick = async () => {
    const proj = $('projectName').value.trim() || (configState && configState.settings ? configState.settings.pagesProject : '');
    if (!proj) { alert('未找到项目名：请先填写项目名或先部署一次'); return; }
    if (!confirm('确认删除 Pages 项目「' + proj + '」？此操作不可撤销，站点将下线。')) return;
    await runEngine(['destroy.ps1', '-ConfigPath', getConfigPath(), '-Project', proj, '-Force']);
    await loadHistory();
  };
}

// ---------- 历史（蓝图 §4.2 + A9 回滚务实版） ----------
async function loadHistory() {
  const r = await runEngine(['deploy-core.ps1', '-ListHistory']);
  if (!r || r.error) { appendLog('[warn] 历史读取失败：' + (r ? r.error : '无响应')); return; }
  historyCache = r.history || [];
  renderHistory();
}

function renderHistory() {
  const box = $('historyList');
  box.innerHTML = '';
  if (historyCache.length === 0) { box.textContent = '—'; return; }
  const last = historyCache.length - 1;
  historyCache.slice().reverse().forEach((rec, ri) => {
    const idx = last - ri;   // 数组下标（0=最新，与 -FromHistory 语义一致）
    const row = document.createElement('div');
    row.className = 'hist-row' + (rec.status === 'failed' ? ' failed' : '');
    const info = document.createElement('span');
    info.className = 'hist-main';
    let badge = '';
    if (rec.servingOk === true) badge = ' <span class="ok">✅</span>';
    else if (rec.status === 'failed') badge = ' <span class="err">✗</span>';
    info.innerHTML = '<b>' + esc(rec.project || '?') + '</b> · ' +
      esc(rec.template || rec.source || '') + ' · ' + esc(rec.timestamp) + badge;
    const actions = document.createElement('span');
    actions.className = 'hist-actions';
    const bLog = document.createElement('button');
    bLog.className = 'tiny ghost';
    bLog.textContent = t('viewLog');
    bLog.onclick = () => showLogModal(rec);
    const bRed = document.createElement('button');
    bRed.className = 'tiny ghost';
    bRed.textContent = t('btnRedeploy');
    bRed.onclick = () => redeployFromHistory(rec, idx);
    actions.appendChild(bLog);
    actions.appendChild(bRed);
    row.appendChild(info);
    row.appendChild(actions);
    box.appendChild(row);
  });
}

async function showLogModal(rec) {
  let body = '<p class="hint">' + esc(rec.logFile || '无日志文件') + '</p>';
  if (rec.logFile) {
    try {
      const text = await Neutralino.filesystem.readFile(rec.logFile);
      body = '<pre class="log" style="max-height:40vh;min-height:200px">' + esc(text) + '</pre>';
    } catch (e) {
      body = '<p class="err">日志读取失败：' + esc(e) + '</p>';
    }
  }
  openModal('📄 ' + esc(rec.project) + ' · ' + esc(rec.timestamp), body, null, t('modalOk'));
}

function redeployFromHistory(rec, idx) {
  if (!confirm('重新部署该版本（' + rec.project + '）？部署成功后将成为最新版本。')) return;
  runEngine(['deploy-core.ps1', '-ConfigPath', getConfigPath(), '-FromHistory', String(idx), '-Backend', $('backendSel').value])
    .then(() => loadHistory())
    .catch((e) => showResultText('❌ ' + e.message, 'err'));
}

// ---------- AI ----------
function wireAi() {
  $('btnAi').onclick = async () => {
    const req = $('aiRequest').value.trim();
    if (!req) { alert('请先输入需求描述'); return; }
    appendLog('LOG|---|INFO|AI 生成方案中…（永不自动部署）');
    const r = await runEngine(['ai-bridge.ps1', '-ConfigPath', getConfigPath(), '-RequestB64', b64u8(req)]);
    if (!r || r.error) {
      appendLog('LOG|---|WARN|AI 方案失败：' + (r ? r.error : '无响应') + '（可手动填写后部署）');
      return;
    }
    $('aiExplanation').textContent = r.explanation || '';
    $('aiMeta').textContent = '模板：' + r.template + (r.projectName ? ' ｜ 建议项目名：' + r.projectName : '') + ' ｜ 模型：' + (r.model || '');
    $('aiSuggestion').classList.remove('hidden');
    if (templates.some((t) => t.id === r.template)) {
      $('templateId').value = r.template;
      await renderTemplateParams(r.parameters || {});
      if (r.projectName) $('projectName').value = r.projectName;
      appendLog('LOG|---|INFO|方案已回填表单（请检查修改后再部署）');
    } else {
      appendLog('LOG|---|WARN|AI 选择了未注册模板：' + r.template);
    }
  };

  $('btnAiClear').onclick = () => $('aiSuggestion').classList.add('hidden');

  $('btnAiSettings').onclick = () => {
    openModal('⚙ AI 设置（OpenAI 兼容协议，Key 走 DPAPI 加密）',
      '<label>BaseUrl<input id="aiBaseUrl" placeholder="https://api.openai.com/v1" value="' + esc(aiState.baseUrl) + '"></label>' +
      '<label>模型<input id="aiModel" placeholder="gpt-4o-mini / deepseek-chat / qwen-plus" value="' + esc(aiState.model) + '"></label>' +
      '<label>API Key<input id="aiApiKey" type="password" placeholder="sk-..." value=""></label>' +
      '<p class="hint">支持任何 OpenAI 兼容端点（OpenAI / DeepSeek / Ollama / vLLM 等）。Key 已保存时置空表示保持不变。</p>',
      async (okBtn) => {
        const baseUrl = $('aiBaseUrl').value.trim();
        const model = $('aiModel').value.trim();
        const apiKey = $('aiApiKey').value.trim();
        if (!baseUrl || !model) { alert('BaseUrl 与模型必填'); return; }
        aiState = { baseUrl: baseUrl, model: model, apiKey: apiKey };
        okBtn.disabled = true;
        const ops = [['aiBaseUrl', baseUrl], ['aiModel', model]];
        if (apiKey) ops.push(['aiApiKey', apiKey]);
        for (const [f, v] of ops) {
          await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'set', '-Field', f, '-ValueB64', b64u8(v)]);
        }
        appendLog('LOG|---|INFO|AI 设置已保存（apiKey 加密存储）');
        closeModal();
        okBtn.disabled = false;
      });
  };
}

// ---------- Token 权限指引（ADR-006） ----------
function openTokenGuide() {
  openModal('🔒 Token 权限指引（ADR-006）',
    '<p>Cloudflare Dashboard → <b>My Profile → API Tokens → Create Token</b>：</p>' +
    '<ul>' +
    '<li>推荐模板：<b>Edit Cloudflare Workers</b> 或自定义，但<b>最小权限</b>只需勾选 <b>Cloudflare Pages — Edit</b>（本工具只做静态站直传部署，不需要 Workers/KV 权限，除非模板声明需要 KV）。</li>' +
    '<li>建议选择 <b>Account Resources → 只用你的账号</b>；不要使用账户级全局密钥。</li>' +
    '<li>创建后只在本工具内使用；Token 泄露请立即到 Dashboard 注销重建。</li>' +
    '<li>本工具部署的产物<b>默认不注入任何凭证</b>（ADR-001），可放心公开站点。</li>' +
    '</ul>' +
    '<p class="hint">注意：Cloudflare 服务条款禁止将 Pages 用于代理/优选 IP 等用途；本项目定位为部署自有合规静态内容。</p>',
    null, '我知道了');
}

// ---------- 插件市场（B1） ----------
function wireMarket() {
  $('btnMarket').onclick = openMarket;
}

async function openMarket() {
  const savedUrl = (configState && configState.settings) ? (configState.settings.marketUrl || '') : '';
  openModal('🧩 插件市场',
    '<label>市场清单 URL（JSON）' +
    '<span class="src-browse"><input id="marketUrl" value="' + esc(savedUrl) +
    '" placeholder="https://…/market.json 或本地路径">' +
    '<button id="btnLoadMarket" class="tiny">' + t('btnLoadMarket') + '</button>' +
    '<button id="btnSaveMarketUrl" class="tiny">' + t('btnSaveMarketUrl') + '</button></span></label>' +
    '<label>搜索 <input id="marketSearch" placeholder="' + t('marketSearchPh') + '"></label>' +
    '<div id="marketList" class="history" style="max-height:30vh">' + t('marketLoading') + '…</div>' +
    '<p class="hint" style="margin-top:10px"><b>' + t('marketInstalled') + '</b></p>' +
    '<div id="marketInstalled" class="history" style="max-height:16vh">' + t('marketNoInstalled') + '</div>',
    null, t('modalOk'));
  $('btnLoadMarket').onclick = () => loadMarket($('marketUrl').value.trim());
  $('btnSaveMarketUrl').onclick = async () => {
    const v = $('marketUrl').value.trim();
    await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'set', '-Field', 'marketUrl', '-ValueB64', b64u8(v)]);
    configState = null;
    appendLog('LOG|---|INFO|市场 URL 已保存');
    alert('✓ 已保存');
  };
  $('marketSearch').oninput = () => renderMarket($('marketSearch').value.trim());
  renderInstalled();
  await loadMarket(savedUrl);
}

async function loadMarket(url) {
  const list = $('marketList');
  list.textContent = t('marketLoading') + '…';
  const args = ['market.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'registry'];
  if (url) args.push('-MarketUrl', url);
  const r = await runEngine(args);
  if (!r || r.error) { list.textContent = '加载失败：' + (r ? r.error : t('marketEmpty')); return; }
  marketCache = { source: r.source, plugins: r.plugins || [] };
  renderMarket($('marketSearch').value.trim());
}

function renderMarket(kw) {
  const list = $('marketList');
  if (!list) return;
  list.innerHTML = '';
  const installedIds = new Set(plugins.map((p) => p.id));
  const kwl = (kw || '').toLowerCase();
  const hits = marketCache.plugins.filter((p) => !kwl ||
    (String(p.id) + ' ' + String(p.name || '') + ' ' + String(p.description || '')).toLowerCase().indexOf(kwl) >= 0);
  if (!hits.length) { list.textContent = t('marketEmpty'); return; }
  for (const p of hits) {
    const isInst = installedIds.has(p.id);
    const row = document.createElement('div');
    row.className = 'hist-row';
    const info = document.createElement('span');
    info.className = 'hist-main';
    info.innerHTML = '<b>' + esc(p.name || p.id) + '</b> <span class="hint">' +
      esc(p.axis + '/' + p.id + ' v' + (p.version || '?')) + '</span><br>' + esc(p.description || '');
    const act = document.createElement('span');
    act.className = 'hist-actions';
    const btn = document.createElement('button');
    btn.className = 'tiny' + (isInst ? ' danger' : '');
    btn.textContent = isInst ? t('marketInstalled') : t('marketInstall');
    btn.disabled = isInst;
    if (!isInst) {
      btn.onclick = async () => {
        btn.disabled = true;
        const r = await runEngine(['market.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'install', '-Axis', p.axis, '-Id', p.id, '-MarketUrl', marketCache.source]);
        if (r && r.error) { alert('安装失败：' + r.error); btn.disabled = false; }
        else {
          appendLog('LOG|---|INFO|市场安装成功：' + p.axis + '/' + p.id);
          await reloadPlugins();
          renderMarket($('marketSearch').value.trim());
          renderInstalled();
        }
      };
    }
    act.appendChild(btn);
    row.appendChild(info);
    row.appendChild(act);
    list.appendChild(row);
  }
}

function renderInstalled() {
  const box = $('marketInstalled');
  if (!box) return;
  box.innerHTML = '';
  const third = plugins.filter((p) => BUILTIN_PLUGINS.indexOf(p.id) < 0);
  if (!third.length) { box.textContent = t('marketNoInstalled'); return; }
  for (const p of third) {
    const row = document.createElement('div');
    row.className = 'hist-row';
    const info = document.createElement('span');
    info.className = 'hist-main';
    info.innerHTML = '<b>' + esc(p.id) + '</b> <span class="hint">' + esc(p.axisKey + '/' + (p.enabled ? '启用' : '禁用')) + '</span>';
    const act = document.createElement('span');
    act.className = 'hist-actions';
    const btn = document.createElement('button');
    btn.className = 'tiny danger';
    btn.textContent = t('marketUninstall');
    btn.onclick = async () => {
      if (!confirm('卸载插件「' + p.id + '」？将删除文件并注销注册。')) return;
      const r = await runEngine(['market.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'uninstall', '-Id', p.id]);
      if (r && r.error) alert('卸载失败：' + r.error);
      else {
        appendLog('LOG|---|INFO|已卸载：' + p.id);
        await reloadPlugins();
        renderMarket($('marketSearch').value.trim());
        renderInstalled();
      }
    };
    act.appendChild(btn);
    row.appendChild(info);
    row.appendChild(act);
    box.appendChild(row);
  }
}

async function reloadPlugins() {
  const r = await runEngine(['deploy-core.ps1', '-ListPlugins']);
  if (r && !r.error) {
    plugins = r.plugins || [];
    populateSourceSelect();
  }
}

// ---------- 通用模态 ----------
let modalOkHandler = null;

function openModal(title, bodyHtml, okHandler, okText) {
  $('modalTitle').textContent = title;
  $('modalBody').innerHTML = bodyHtml;
  const ok = $('modalOk');
  ok.textContent = okText || t('modalOk');
  modalOkHandler = okHandler;
  $('modal').classList.remove('hidden');
  const first = $('modalBody').querySelector('input, textarea');
  if (first) first.focus();
}

function closeModal() {
  $('modal').classList.add('hidden');
  modalOkHandler = null;
}

// ---------- 模式切换 ----------
function wireSeg() {
  const activate = (which) => {
    $('segTemplate').classList.toggle('active', which === 'template');
    $('segSource').classList.toggle('active', which === 'source');
    $('blockTemplate').classList.toggle('hidden', which !== 'template');
    $('blockSource').classList.toggle('hidden', which !== 'source');
  };
  $('segTemplate').onclick = () => activate('template');
  $('segSource').onclick = () => activate('source');
  $('templateId').onchange = () => renderTemplateParams();
  $('sourceId').onchange = renderSourceFields;
}

// ---------- 首启 ----------
function wireFirstRun() {
  $('btnFirstRunOk').onclick = () => {
    $('firstRun').classList.add('hidden');
    loadConfig().then((r) => {
      if (r) renderResult(null);
    });
  };
  $('firstRunTokenGuide').onclick = (e) => {
    e.preventDefault();
    openTokenGuide();
  };
}

// ---------- 初始化 ----------
async function init() {
  await Neutralino.init();
  engineDir = await resolveEngineDir();
  setStatus(t('statusIdle') + ' · 引擎：' + engineDir);

  wire();
  wireCredential();
  wireSeg();
  wireDeploy();
  wireAi();
  wireFirstRun();

  $('btnExport').onclick = openExport;
  $('btnImport').onclick = openImport;
  $('btnTokenGuide').onclick = openTokenGuide;
  $('btnCancel').onclick = cancelRun;
  $('btnRefreshHistory').onclick = loadHistory;
  $('langSel').value = curLang;
  $('langSel').onchange = () => setLang($('langSel').value);
  wireMarket();

  $('modalOk').onclick = async () => {
    if (modalOkHandler) await modalOkHandler($('modalOk'));
    else closeModal();
  };
  $('modalCancel').onclick = closeModal;

  await loadPlugins();
  await loadTemplates();
  await loadConfig();
  await loadHistory();
}

function wire() {
  /* 占位：各功能区在对应 wire* 中完成 */
}

Neutralino.init().then(init).catch((e) => {
  document.getElementById('log').textContent = '初始化失败：' + e + '\n请确认已执行 scripts/dev/bootstrap.ps1（neu update）。';
});