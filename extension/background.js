// background.js — Service Worker
importScripts('shared.js');

chrome.runtime.onInstalled.addListener(() => {
  console.log('随手记 Sui 剪藏扩展已安装');
  chrome.contextMenus.create({
    id: 'sui-clip',
    title: '剪藏到随手记 Sui',
    contexts: ['page', 'selection', 'link'],
  });
  chrome.contextMenus.create({
    id: 'sui-clip-selection',
    title: '选择正文区域剪藏到随手记 Sui',
    contexts: ['page'],
  });
});

// 右键菜单：按「上次选择的模式」整页剪藏
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === 'sui-clip-selection') {
    await startSelectionClip(tab?.id);
    return;
  }
  if (info.menuItemId !== 'sui-clip') return;
  if (!tab?.id) return;

  // M12 修订 / FR-57：判据改为「已登录会话」（地址 + 刷新令牌），不再是手填 Token。
  if (!(await suiIsLoggedIn())) {
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
    await suiPostClip(pageData, mode);

    setBadge(tab.id, '✓', '#4caf50', 2000);
  } catch (err) {
    console.error('剪藏失败:', err);
    setBadge(tab.id, '!', '#f44336', 3000);
  }
});

 // ---------------------------------------------------------------------------
 // 选择正文区域剪藏（v0.16.2 / FR-90）
 // ---------------------------------------------------------------------------

// 弹窗 / 右键菜单 → 注入页面选择器；选择器点选后把结果消息发回本 worker。
async function startSelectionClip(tabId) {
  if (!tabId) return;
  if (!(await suiIsLoggedIn())) {
    chrome.action.openPopup();
    return;
  }
  try {
    const [res] = await chrome.scripting.executeScript({
      target: { tabId },
      func: suiPickContentInPage,
    });
    if (!res?.result?.started) {
      // 选择器已在该页开启；不重复注入，也不打断用户。
      setBadge(tabId, '…', '#667eea', 1500);
    } else {
      setBadge(tabId, '…', '#667eea', 1500);
    }
  } catch (err) {
    console.error('启动正文选择器失败:', err);
    setBadge(tabId, '!', '#f44336', 3000);
  }
}

// 页面选择器回传结果 → 按 snapshot 模式剪藏（保留选中容器的布局）。
async function handleSelectionResult(tabId, pageData) {
  if (!tabId || !pageData?.html) return;
  try {
    const data = await suiPostClip(pageData, 'snapshot');
    setBadge(tabId, '✓', '#4caf50', 2000);
    await showToast(tabId, '✓ ' + suiBuildResultMessage(data));
  } catch (err) {
    console.error('选择正文剪藏失败:', err);
    setBadge(tabId, '!', '#f44336', 3000);
    await showToast(tabId, `剪藏失败：${err.message}`);
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.type === 'sui-start-selection-clip') {
    startSelectionClip(msg.tabId);
    return false;
  }
  if (msg?.type === 'sui-selection-result') {
    handleSelectionResult(sender.tab?.id, msg.pageData);
    return false;
  }
  if (msg?.type === 'sui-selection-cancel') {
    const tabId = sender.tab?.id;
    if (tabId) setBadge(tabId, '', '#000000', 0);
    return false;
  }
  return false;
});

async function showToast(tabId, message) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: suiToastInPage,
      args: [message],
    });
  } catch (_) {
    // 页面已关闭 / 无法注入：徽标已给出结果，忽略。
  }
}

// 注入页面的选择器：自包含（不得引用 background 其它函数）。
function suiPickContentInPage() {
  if (window.__suiContentPickerActive) return { started: false };
  window.__suiContentPickerActive = true;

  const overlay = document.createElement('div');
  overlay.setAttribute('data-sui-picker', 'overlay');
  overlay.style.cssText = [
    'position:fixed', 'z-index:2147483647', 'pointer-events:none',
    'border:2px solid #667eea', 'background:rgba(102,126,234,0.14)',
    'border-radius:3px', 'display:none', 'box-sizing:border-box',
  ].join(';');
  const bar = document.createElement('div');
  bar.setAttribute('data-sui-picker', 'bar');
  bar.textContent = '点击选择正文区域 · Esc 取消';
  bar.style.cssText = [
    'position:fixed', 'top:0', 'left:0', 'right:0', 'height:38px',
    'z-index:2147483647', 'pointer-events:none', 'display:flex',
    'align-items:center', 'padding:0 14px', 'background:#222',
    'color:#fff', 'font:13px/38px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
    'box-shadow:0 2px 8px rgba(0,0,0,0.25)',
  ].join(';');
  document.documentElement.appendChild(overlay);
  document.documentElement.appendChild(bar);

  let hovered = null;

  const onOver = (e) => {
    const t = e.target;
    if (!(t instanceof Element) || t.closest('[data-sui-picker]')) return;
    hovered = t;
    const r = t.getBoundingClientRect();
    overlay.style.display = 'block';
    overlay.style.top = Math.max(0, r.top) + 'px';
    overlay.style.left = Math.max(0, r.left) + 'px';
    overlay.style.width = Math.max(0, r.width) + 'px';
    overlay.style.height = Math.max(0, r.height) + 'px';
    bar.textContent = `点击选择 <${t.tagName.toLowerCase()}> · Esc 取消`;
  };

  const cleanup = () => {
    document.removeEventListener('mouseover', onOver, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKey, true);
    overlay.remove();
    bar.remove();
    window.__suiContentPickerActive = false;
  };

  const buildPageData = (el) => {
    // 选中区域里的懒加载图片：把 data-* 地址回填到 src，并绝对化，避免剪藏后是空图。
    el.querySelectorAll('img').forEach((img) => {
      img.loading = 'eager';
      const lazy = img.getAttribute('data-src') ||
        img.getAttribute('data-original') ||
        img.getAttribute('data-lazy-src');
      if (lazy && (!img.getAttribute('src') || img.getAttribute('src') === location.href)) {
        try {
          img.setAttribute('src', new URL(lazy, location.href).href);
        } catch (_) {
          img.setAttribute('src', lazy);
        }
      }
    });

    // 保留“body → 选中元素”的祖先链（class/id/布局上下文），删除每一级的兄弟节点
    // （页头 / 页脚 / 侧栏通常就是这些兄弟节点）。
    const path = [];
    let n = el;
    while (n && n !== document.body) {
      const p = n.parentElement;
      if (!p) break;
      path.unshift(Array.prototype.indexOf.call(p.children, n));
      n = p;
    }

    const clone = document.documentElement.cloneNode(true);
    clone.querySelectorAll('[data-sui-picker]').forEach((x) => x.remove());
    const clonedBody = clone.querySelector('body');
    if (clonedBody && el !== document.body) {
      let cur = clonedBody;
      for (const idx of path) {
        const next = cur.children[idx];
        if (!next) break;
        for (const child of Array.from(cur.children)) {
          if (child !== next) child.remove();
        }
        cur = next;
      }
    }

    // 脚本 / 表单控件由服务端再收口；这里先剔除，减少载荷。
    clone.querySelectorAll('script,noscript,iframe,object,embed,form,input,button,select,textarea')
      .forEach((x) => x.remove());
    clone.querySelectorAll('*').forEach((node) => {
      for (const attr of Array.from(node.attributes || [])) {
        const name = String(attr.name || '').toLowerCase();
        if (name.startsWith('on')) node.removeAttribute(attr.name);
        if ((name === 'href' || name === 'src') &&
            /^\s*(javascript:|vbscript:|data:text\/html)/i.test(attr.value || '')) {
          node.removeAttribute(attr.name);
        }
      }
    });

    return {
      title: document.title,
      url: location.href,
      html: '<!DOCTYPE html>\n' + clone.outerHTML,
    };
  };

  const finish = (el) => {
    const pageData = el ? buildPageData(el) : null;
    cleanup();
    try {
      chrome.runtime.sendMessage({
        type: el ? 'sui-selection-result' : 'sui-selection-cancel',
        pageData,
      });
    } catch (_) {
      // 扩展被重载 / 上下文失效：选择器已清理，静默结束。
    }
  };

  const onClick = (e) => {
    const t = e.target;
    if (!(t instanceof Element) || t.closest('[data-sui-picker]')) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    finish(t);
  };

  const onKey = (e) => {
    if (e.key !== 'Escape') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    finish(null);
  };

  document.addEventListener('mouseover', onOver, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKey, true);
  return { started: true };
}

// 页面内轻提示（剪藏成功 / 失败）。自包含。
function suiToastInPage(message) {
  const el = document.createElement('div');
  el.setAttribute('data-sui-toast', '1');
  el.textContent = message;
  el.style.cssText = [
    'position:fixed', 'right:20px', 'bottom:20px', 'z-index:2147483647',
    'max-width:420px', 'padding:10px 14px', 'border-radius:8px',
    'background:#222', 'color:#fff', 'font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
    'box-shadow:0 4px 16px rgba(0,0,0,0.3)',
  ].join(';');
  document.documentElement.appendChild(el);
  setTimeout(() => el.remove(), 3500);
}

function setBadge(tabId, text, color, clearAfterMs) {
  chrome.action.setBadgeText({ text, tabId });
  chrome.action.setBadgeBackgroundColor({ color, tabId });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '', tabId });
  }, clearAfterMs);
}
