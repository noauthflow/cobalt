// pin/unpin the active tab — chrome has no native keyboard shortcut for this.
// default: Ctrl+Shift+P (Cmd+Shift+P on mac), rebindable at
// chrome://extensions/shortcuts. if the default key is taken by another
// extension, chrome silently leaves it unbound — check there.
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "pin-tab") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) chrome.tabs.update(tab.id, { pinned: !tab.pinned });
});