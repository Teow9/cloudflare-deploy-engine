// ============================================================
// Cloudflare Deploy Engine —— 前端（M2 桌面 UI 全量版）
// 通信：os.spawnProcess → powershell.exe（引擎脚本），stdout 逐行
// 解析 LOG|ts|LEVEL|msg（实时滚动）与 RESULT|<json>（最终结果）。
// 参数安全通道：JSON/文本一律 Base64(UTF-8) 传递（-ParamsB64 等），
// 免疫 Windows 命令行引号剥离与编码问题。
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

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- 基础工具 ----------
function pathJoin(...parts) { return parts.join('\\'); }

function b64u8(str) {
  // UTF-8 安全 Base64 编码（TextEncoder → btoa）
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
  // 用只读目录探测确认引擎根（filesystem.readDirectory 仅列目录，不读内容）
  try { await Neutralino.filesystem.readDirectory(p); return true; }
  catch (e) { return false; }
}

async function resolveEngineDir() {
  // 引擎根解析优先级：
  //  ① exe 同级（打包目录模式：exe + scripts/ 真实文件） ② resources 路径（neu run 开发模式）
  try {
    const exePath = await Neutralino.os.getPath('exe');
    const exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
    if (await hasDir(pathJoin(exeDir, 'scripts'))) return exeDir;
    const p = await Neutralino.os.getPath('resources');
    if (p && await hasDir(pathJoin(p, 'scripts'))) return p;
    return exeDir; // 兜底：exe 同级
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
const WATCHDOG_MS = 25 * 60 * 1000; // 25 分钟无结果自动终止

function runEngine(args) {
  return new Promise((resolve, reject) => {
    if (running) { reject(new Error('已有任务在运行，请先等待或取消')); return; }
    running = true;
    cancelRequested = false;
    showCancelBtn(true);
    setStatus('运行中…（可取消）', 'busy');

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
            renderResult(parsed); // 结果先上屏，exit 后再 settle
          } else {
            appendLog(text);
          }
        } else if (d.action === 'stdErr') {
          appendLog('[stderr] ' + String(d.data).replace(/\r?\n$/, ''));
        } else if (d.action === 'exit') {
          if (cancelRequested) {
            setStatus('已取消', 'fail');
            settle(() => reject(new Error('任务已取消')));
          } else if (finalResult) {
            setStatus('完成', 'done');
            settle(() => resolve(finalResult));
          } else {
            const code = d.data;
            setStatus('异常退出 · exit=' + code, 'fail');
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
      setStatus('启动失败', 'fail');
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
  setStatus('取消中…', 'busy');
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
    setStatus('失败', 'fail');
    return;
  }
  let html = '<table>';
  if (obj.url) {
    html += '<tr><td class="k">站点 URL</td><td><a href="' + esc(obj.url) + '" target="_blank">' + esc(obj.url) + '</a></td></tr>';
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
  setStatus('完成', 'done');
}

// ---------- 配置装载 / 首启 ----------
async function isFirstRun() {
  // 配置文件不存在 = 首次启动（首启遮罩：免责 + 条款）；存在 = 正常启动
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

async function renderTemplateParams(prefill) {
  const id = $('templateId').value;
  if (!id) { $('tplParams').innerHTML = '<p class="hint">暂无可用模板（检查 plugins.json）</p>'; return; }
  const meta = await getTemplateMeta(id);
  const box = $('tplParams');
  box.innerHTML = '';
  for (const p of (meta.parameters || [])) {
    const wrap = document.createElement('label');
    wrap.className = 'dyn-field';
    wrap.textContent = (p.label || p.name) + (p.type ? '（' + p.type + '）' : '');
    const input = document.createElement('input');
    input.dataset.param = p.name;
    const v = (prefill && prefill[p.name] !== undefined) ? prefill[p.name] : p.default;
    input.value = v === undefined ? '' : String(v);
    wrap.appendChild(input);
    box.appendChild(wrap);
  }
}

function collectParams() {
  const out = {};
  document.querySelectorAll('#tplParams input[data-param]').forEach((el) => {
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
  // 来源下拉从插件注册表动态生成（只列已启用的 sources，禁用即不可选）
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
  const labels = { local: '📁 本地文件夹', github: '🐙 GitHub 仓库（codeload，零依赖）', zip: '📦 本地压缩包（zip/tar/tgz）' };
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
  } else if (id === 'github') {
    box.innerHTML =
      '<label class="dyn-field">仓库地址' +
      '<input id="gitUrl" placeholder="owner/repo 或 https://github.com/owner/repo" autocomplete="off"></label>' +
      '<label class="dyn-field">分支 / Tag（留空 = main）' +
      '<input id="gitRef" placeholder="main" autocomplete="off"></label>';
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
  if (id === 'github') {
    const u = $('gitUrl').value.trim();
    if (!u) throw new Error('请填写 GitHub 仓库地址');
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
    setStatus('凭证已保存', 'done');
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
      const args = buildDeployArgs(false);
      await runEngine(args);
    } catch (e) {
      showResultText('❌ ' + e.message, 'err');
    }
  };

  $('btnDryRun').onclick = async () => {
    try {
      const args = buildDeployArgs(true);
      await runEngine(args);
    } catch (e) {
      showResultText('❌ ' + e.message, 'err');
    }
  };

  $('btnDestroy').onclick = async () => {
    const proj = $('projectName').value.trim() || (configState && configState.settings ? configState.settings.pagesProject : '');
    if (!proj) { alert('未找到项目名：请先填写项目名或先部署一次'); return; }
    if (!confirm('确认删除 Pages 项目「' + proj + '」？此操作不可撤销，站点将下线。')) return;
    await runEngine(['destroy.ps1', '-ConfigPath', getConfigPath(), '-Project', proj, '-Force']);
  };
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
    // 回填（可编辑）
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
        const ops = [
          ['aiBaseUrl', baseUrl], ['aiModel', model]
        ];
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

// ---------- 通用模态 ----------
let modalOkHandler = null;

function openModal(title, bodyHtml, okHandler, okText) {
  $('modalTitle').textContent = title;
  $('modalBody').innerHTML = bodyHtml;
  const ok = $('modalOk');
  ok.textContent = okText || '确定';
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
    closeFirstRunGuard();
    openTokenGuide();
  };
}

// 首启遮罩下打开指引后，先隐藏遮罩（指引在通用模态层）
function closeFirstRunGuard() {
  // 指引关闭后不再强制首启（配置将随后创建）
}

// ---------- 初始化 ----------
async function init() {
  await Neutralino.init();
  engineDir = await resolveEngineDir();
  setStatus('就绪 · 引擎：' + engineDir);

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

  $('modalOk').onclick = async () => {
    if (modalOkHandler) await modalOkHandler($('modalOk'));
    else closeModal();
  };
  $('modalCancel').onclick = closeModal;

  await loadPlugins();
  await loadTemplates();
  await loadConfig(); // 内部判断首启：显示遮罩或装载配置
}

function wire() {
  /* 占位：各功能区在对应 wire* 中完成 */
}

Neutralino.init().then(init).catch((e) => {
  document.getElementById('log').textContent = '初始化失败：' + e + '\n请确认已执行 scripts/dev/bootstrap.ps1（neu update）。';
});