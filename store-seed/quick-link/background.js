// A background script runs once when Satellite starts, with no page open.
// It has the `satellite` API; "permissions": ["ui"] in the manifest allows the sidebar calls.

async function apply() {
  const { enabled, title, url, section } = await satellite.settings.getAll();
  const lists = { apps: satellite.ui.apps, assistants: satellite.ui.assistants };

  // Take the item out of every list we don't want it in (removing a missing item is fine).
  for (const [name, list] of Object.entries(lists)) {
    if (!enabled || name !== section) await list.remove('link');
  }
  if (!enabled) return;

  try {
    // Adding with the same id again replaces the item, so this is safe to repeat.
    await lists[section].add({ id: 'link', name: title, url, symbol: 'link' });
  } catch (error) {
    console.error('Quick Link:', error.message); // for example, an address that isn't http(s)
  }
}

satellite.settings.onChange(apply); // runs when the user edits a setting
await apply();
