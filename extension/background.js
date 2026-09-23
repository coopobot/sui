// background.js — Service Worker
chrome.runtime.onInstalled.addListener(() => {
  console.log('随手记 Sui 剪藏扩展已安装');
});

// 右键菜单：剪藏页面
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'sui-clip',
    title: '剪藏到随手记 Sui',
    contexts: ['page', 'selection', 'link'],
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== 'sui-clip') return;
  if (!tab?.id) return;

  const settings = await getSettings();
  if (!settings.serverUrl || !settings.token) {
    chrome.action.openPopup();
    return;
  }

  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({
        title: document.title,
        url: location.href,
        html: document.documentElement.outerHTML,
      }),
    });

    const pageData = result.result;
    const resp = await fetch(`${settings.serverUrl.replace(/\/$/, '')}/api/v1/clips`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${settings.token}`,
      },
      body: JSON.stringify({
        url: pageData.url,
        title: pageData.title,
        html: pageData.html,
      }),
    });

    if (resp.ok) {
      chrome.action.setBadgeText({ text: '✓', tabId: tab.id });
      chrome.action.setBadgeBackgroundColor({ color: '#4caf50', tabId: tab.id });
      setTimeout(() => {
        chrome.action.setBadgeText({ text: '', tabId: tab.id });
      }, 2000);
    } else {
      chrome.action.setBadgeText({ text: '!', tabId: tab.id });
      chrome.action.setBadgeBackgroundColor({ color: '#f44336', tabId: tab.id });
    }
  } catch (err) {
    console.error('剪藏失败:', err);
  }
});

async function getSettings() {
  const defaults = { serverUrl: 'http://localhost:8080', token: '' };
  const stored = await chrome.storage.sync.get(['serverUrl', 'token']);
  return { ...defaults, ...stored };
}
