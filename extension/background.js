// background.js — Service Worker
importScripts('shared.js');

chrome.runtime.onInstalled.addListener(() => {
  console.log('随手记 Sui 剪藏扩展已安装');
  chrome.contextMenus.create({
    id: 'sui-clip',
    title: '剪藏到随手记 Sui',
    contexts: ['page', 'selection', 'link'],
  });
});

// 右键菜单：按「上次选择的模式」整页剪藏
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== 'sui-clip') return;
  if (!tab?.id) return;

  const settings = await suiGetSettings();
  if (!settings.serverUrl || !settings.token) {
    chrome.action.openPopup();
    return;
  }

  try {
    // 采集完整 DOM（含懒加载图片）+ 上次选择的模式（默认 article）
    const pageData = await suiCaptureTab(tab.id);
    if (!pageData || !pageData.html) {
      throw new Error('采集页面内容失败');
    }
    const mode = await suiGetLastMode();
    await suiPostClip(settings, pageData, mode);

    setBadge(tab.id, '✓', '#4caf50', 2000);
  } catch (err) {
    console.error('剪藏失败:', err);
    setBadge(tab.id, '!', '#f44336', 3000);
  }
});

function setBadge(tabId, text, color, clearAfterMs) {
  chrome.action.setBadgeText({ text, tabId });
  chrome.action.setBadgeBackgroundColor({ color, tabId });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '', tabId });
  }, clearAfterMs);
}
