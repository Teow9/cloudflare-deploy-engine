// ============================================================
// i18n.js —— 界面文案词典（中/英，B5）
// 用法：元素加 data-i18n="key"；JS 动态文案用 t('key')。
// 引擎日志保持中文（说明见 docs）；界面框架双语。
// ============================================================

const I18N = {
  zh: {
    brand: '⚡ Cloudflare Deploy Engine',
    statusIdle: '就绪',
    cancelTask: '■ 取消任务',
    credTitle: '🔑 Cloudflare 凭证',
    lblAccountId: 'Account ID',
    lblEmail: 'Email',
    lblApiToken: 'API Token',
    btnSaveCred: '💾 加密保存',
    btnLoadCred: '加载',
    btnClearCred: '清除',
    btnExport: '📤 导出（换机迁移）',
    btnImport: '📥 导入',
    btnTokenGuide: '🔒 Token 权限指引',
    credHint: '凭证经 Windows DPAPI 加密存于本机 data/config.enc.json，仅当前用户可解；删除文件夹即完全卸载。',
    deployTitle: '🚀 部署',
    segTemplate: '内置模板',
    segSource: '自定义来源',
    lblTemplate: '模板',
    lblSourceType: '来源类型',
    lblProject: '项目名（决定 *.pages.dev 域名，留空自动派生）',
    btnDeploy: '🚀 部署',
    btnDryRun: '演练 DryRun',
    btnDestroy: '🗑 销毁项目',
    lblBackend: '部署后端',
    deployHint: '首次部署建议先「演练 DryRun」验证配置，全程不触碰云端。',
    aiTitle: '✨ AI 智能部署（只回填，永不自动部署）',
    lblAiRequest: '用一句话描述需求',
    btnAi: '✨ 生成方案并回填',
    btnAiSettings: '⚙ AI 设置',
    logTitle: '📝 实时日志',
    resultTitle: '📦 部署结果',
    historyTitle: '🗂 部署历史',
    btnRefreshHistory: '刷新',
    btnRedeploy: '↻ 重部署',
    viewLog: '日志',
    modalOk: '确定',
    modalCancel: '取消',
    running: '运行中…（可取消）',
    done: '完成',
    failed: '失败',
    cancelled: '已取消'
  },
  en: {
    brand: '⚡ Cloudflare Deploy Engine',
    statusIdle: 'Ready',
    cancelTask: '■ Cancel',
    credTitle: '🔑 Cloudflare Credentials',
    lblAccountId: 'Account ID',
    lblEmail: 'Email',
    lblApiToken: 'API Token',
    btnSaveCred: '💾 Save encrypted',
    btnLoadCred: 'Load',
    btnClearCred: 'Clear',
    btnExport: '📤 Export (migration)',
    btnImport: '📥 Import',
    btnTokenGuide: '🔒 Token guide',
    credHint: 'Credentials are DPAPI-encrypted in local data/config.enc.json, readable by current user only; delete folder = full uninstall.',
    deployTitle: '🚀 Deploy',
    segTemplate: 'Built-in template',
    segSource: 'Custom source',
    lblTemplate: 'Template',
    lblSourceType: 'Source type',
    lblProject: 'Project name (sets *.pages.dev domain; blank = auto derive)',
    btnDeploy: '🚀 Deploy',
    btnDryRun: 'DryRun',
    btnDestroy: '🗑 Destroy project',
    lblBackend: 'Backend',
    deployHint: 'Run DryRun first to validate config without touching the cloud.',
    aiTitle: '✨ AI Assistant (suggest only, never auto-deploy)',
    lblAiRequest: 'Describe your need in one sentence',
    btnAi: '✨ Generate & fill',
    btnAiSettings: '⚙ AI settings',
    logTitle: '📝 Live log',
    resultTitle: '📦 Result',
    historyTitle: '🗂 History',
    btnRefreshHistory: 'Refresh',
    btnRedeploy: '↻ Redeploy',
    viewLog: 'Log',
    modalOk: 'OK',
    modalCancel: 'Cancel',
    running: 'Running… (cancel available)',
    done: 'Done',
    failed: 'Failed',
    cancelled: 'Cancelled'
  }
};

let curLang = localStorage.getItem('cde_lang') || 'zh';

function t(key) {
  const dict = I18N[curLang] || I18N.zh;
  return (dict && dict[key]) || I18N.zh[key] || key;
}

function applyLang() {
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  if (window.updateDynamicI18n) updateDynamicI18n();
}

function setLang(l) {
  curLang = (I18N[l] ? l : 'zh');
  localStorage.setItem('cde_lang', curLang);
  applyLang();
}