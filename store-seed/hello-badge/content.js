// Isolated world: full DOM access plus the `satellite` API (allowed by "permissions" in the manifest).
// Libraries listed under "dependencies" are available through require().
const { h, toast } = require('shared-utils');

if (window.top === window) {
  const visits = ((await satellite.storage.get('visits')) || 0) + 1;
  await satellite.storage.set('visits', visits);

  document.body.appendChild(h('div', {
    style: {
      position: 'fixed', left: '8px', bottom: '8px', zIndex: 2147483647,
      padding: '4px 8px', borderRadius: '6px', background: '#0b5cab', color: '#fff',
      font: '12px -apple-system, sans-serif', opacity: '.85',
    },
  }, 'Hello from Satellite · visit ' + visits));

  toast('Hello Badge is active');
}
