// Shared Utilities 1.0.0: small DOM helpers for Satellite extensions.
// From a dependent extension:  const { waitFor, h, toast } = require('shared-utils');

// Resolves with the first element matching `selector`, waiting for it to appear.
function waitFor(selector, { root = document, timeout = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const existing = root.querySelector(selector);
    if (existing) return resolve(existing);

    const timer = setTimeout(() => {
      observer.disconnect();
      reject(new Error('Timed out waiting for ' + selector));
    }, timeout);
    const observer = new MutationObserver(() => {
      const found = root.querySelector(selector);
      if (!found) return;
      clearTimeout(timer);
      observer.disconnect();
      resolve(found);
    });
    observer.observe(root === document ? document.documentElement : root, { childList: true, subtree: true });
  });
}

// h('div', { style: { color: 'red' }, onClick: fn }, 'text', childElement)
function h(tag, props = {}, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === 'style' && typeof value === 'object') Object.assign(element.style, value);
    else if (key.startsWith('on') && typeof value === 'function') element.addEventListener(key.slice(2).toLowerCase(), value);
    else element.setAttribute(key, value);
  }
  element.append(...children);
  return element;
}

// A small message in the corner of the page that removes itself.
function toast(text, { duration = 3000 } = {}) {
  const element = h('div', {
    style: {
      position: 'fixed', right: '12px', bottom: '12px', zIndex: 2147483647,
      padding: '8px 12px', borderRadius: '8px', background: '#222', color: '#fff',
      font: '13px -apple-system, sans-serif', boxShadow: '0 2px 10px rgba(0,0,0,.3)',
    },
  }, text);
  document.body.appendChild(element);
  setTimeout(() => element.remove(), duration);
  return element;
}

module.exports = { waitFor, h, toast };
