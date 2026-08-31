// Cloudflare Deploy Engine —— UI 骨架（M2 功能清单的一部分）
// 引擎通信：Neutralino os.spawnProcess → powershell.exe（引擎脚本），
// stdout 逐行解析 LOG| / RESULT| 协议（见 scripts/utils.ps1）。

let engineDir = '';
let running = false;

function pathJoin(...parts) {
  return parts.join('\\');
}

async function init() {
  await Neutralino.init();
  const exePath = await Neutralino.os.getPath('exe');
  engineDir = exePath.substring(0, exePath.lastIndexOf('\\'));
  setStatus('就绪 · ' + engineDir);
  wire();
}

function setStatus(text) {
  document.getElementById('status').textContent = text;
}

function appendLog(line) {
  const log = document.getElementById('log');
  const div = document.createElement('div');
  const m = line.match(/^LOG\|[^|]*\|(\w+)\|(.*)$/s);
  if (m) {
    div.className = m[1];
    div.textContent = m[2];
  } else {
    div.textContent = line;
  }
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
  return div;
}

function showResult(obj) {
  document.getElementById('result').textContent = JSON.stringify(obj, null, 2);
}

function parseResultLine(line) {
  const idx = line.indexOf('|');
  if (idx < 0) return null;
  try { return JSON.parse(line.substring(idx + 1)); } catch (e) { return null; }
}

// 执行引擎命令：args = 引擎脚本名 + 参数数组
function runEngine(args) {
  return new Promise((resolve, reject) => {
    if (running) { reject(new Error('已有任务在运行')); return; }
    running = true;
    setStatus('运行中…（可点击取消）');
    const script = args.shift();
    const fullArgs = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', pathJoin(engineDir, 'scripts', script), ...args
    ];
    Neutralino.os.spawnProcess('powershell.exe', fullArgs).then((proc) => {
      let finalResult = null;
      const onEvent = (evt) => {
        if (evt.detail.id !== proc.id) return;
        const d = evt.detail;
        if (d.action === 'stdOut') {
          const text = String(d.data).replace(/\r?\n$/, '');
          if (!text) return;
          const parsed = text.startsWith('RESULT|') ? parseResultLine(text) : null;
          if (parsed) {
            finalResult = parsed;
            showResult(parsed);
          } else {
            appendLog(text);
          }
        } else if (d.action === 'stdErr') {
          appendLog('[stderr] ' + d.data);
        } else if (d.action === 'exit') {
          Neutralino.events.off('spawnedProcess', onEvent);
          running = false;
          setStatus('完成 · exit=' + d.data);
          resolve(finalResult);
        }
      };
      Neutralino.events.on('spawnedProcess', onEvent);
    }).catch((e) => {
      running = false;
      setStatus('启动失败');
      reject(e);
    });
  });
}

function getConfigPath() {
  return pathJoin(engineDir, 'data', 'config.enc.json');
}

// ---------- 交互 ----------
function wire() {
  document.getElementById('btnSaveCred').onclick = async () => {
    const fields = { accountId: 'accountId', email: 'email', apiToken: 'apiToken' };
    for (const [id, field] of Object.entries(fields)) {
      const v = document.getElementById(id).value.trim();
      if (v) await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'set', '-Field', field, '-Value', v]);
    }
    appendLog('LOG|---|INFO|凭证已加密保存');
  };

  document.getElementById('btnLoadCred').onclick = async () => {
    const r = await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'get']);
    if (r && !r.error) {
      document.getElementById('accountId').value = r.secrets.accountId || '';
      document.getElementById('email').value = r.secrets.email || '';
      document.getElementById('apiToken').value = r.secrets.apiToken || '';
    }
  };

  document.getElementById('btnClearCred').onclick = async () => {
    await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'clear']);
  };

  const collectParams = () => ({
    site_title: document.getElementById('siteTitle').value.trim() || '我的站点',
    site_tagline: document.getElementById('siteTagline').value.trim() || '由 Cloudflare Deploy Engine 部署',
  });

  document.getElementById('btnDeploy').onclick = async () => {
    const params = JSON.stringify(collectParams());
    await runEngine(['deploy-core.ps1', '-ConfigPath', getConfigPath(),
      '-TemplateId', document.getElementById('templateId').value,
      '-ParamsJson', params]);
  };

  document.getElementById('btnDryRun').onclick = async () => {
    const params = JSON.stringify(collectParams());
    await runEngine(['deploy-core.ps1', '-ConfigPath', getConfigPath(),
      '-TemplateId', document.getElementById('templateId').value,
      '-ParamsJson', params, '-DryRun']);
  };

  document.getElementById('btnDestroy').onclick = async () => {
    if (!confirm('确认删除 Pages 项目？此操作不可撤销。')) return;
    await runEngine(['destroy.ps1', '-ConfigPath', getConfigPath(), '-Force']);
  };

  document.getElementById('btnAi').onclick = async () => {
    const req = document.getElementById('aiRequest').value.trim();
    if (!req) { alert('请先输入需求描述'); return; }
    const r = await runEngine(['ai-bridge.ps1', '-ConfigPath', getConfigPath(), '-Request', req]);
    if (r && !r.error) {
      document.getElementById('aiHint').textContent = '✨ ' + r.explanation + '（已回填，可手动修改后部署）';
      if (r.parameters && r.parameters.site_title) document.getElementById('siteTitle').value = r.parameters.site_title;
      if (r.parameters && r.parameters.site_tagline) document.getElementById('siteTagline').value = r.parameters.site_tagline;
      document.getElementById('templateId').value = r.template;
    }
  };

  document.getElementById('btnAiSettings').onclick = async () => {
    const baseUrl = prompt('AI BaseUrl（OpenAI 兼容）', 'https://api.openai.com/v1');
    const model = prompt('模型', 'gpt-4o-mini');
    const apiKey = prompt('API Key');
    if (!baseUrl || !model || !apiKey) return;
    // M2 精化：baseUrl/model 持久化到配置（当前引擎仅持久化 apiKey 与 CF 凭证）
    await runEngine(['config-manager.ps1', '-ConfigPath', getConfigPath(), '-Verb', 'set', '-Field', 'aiApiKey', '-Value', apiKey]);
    alert('AI Key 已加密保存。baseUrl/model 持久化在 M2 精化版中补全。');
  };

  document.getElementById('btnListPlugins').onclick = async () => {
    await runEngine(['deploy-core.ps1', '-ListPlugins']);
  };

  document.getElementById('btnListTemplates').onclick = async () => {
    await runEngine(['deploy-core.ps1', '-ListTemplates']);
  };
}

Neutralino.init().then(init).catch((e) => {
  document.getElementById('log').textContent = '初始化失败：' + e + '\n请确认已执行 neu update（scripts/dev/bootstrap.ps1）。';
});