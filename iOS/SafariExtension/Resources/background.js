// Vigil for Safari: counts seconds on the active tab's domain and hands totals to the app once a minute.
// Only the hostname is used; full URLs, titles and page contents are never read or stored.

const pending = new Map(); // "day|domain" -> seconds
let current = null;        // { domain, since }

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function domainOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    return u.hostname.replace(/^www\./, "").toLowerCase();
  } catch { return null; }
}

function closeCurrent() {
  if (!current) return;
  const seconds = Math.min(3600, (Date.now() - current.since) / 1000);
  if (seconds >= 1) {
    const key = `${today()}|${current.domain}`;
    pending.set(key, (pending.get(key) || 0) + seconds);
  }
  current = null;
}

async function refresh() {
  closeCurrent();
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  const domain = tab && domainOf(tab.url || "");
  if (domain) current = { domain, since: Date.now() };
}

async function flush() {
  if (current) { const d = current.domain; closeCurrent(); current = { domain: d, since: Date.now() }; }
  if (pending.size === 0) return;
  const usage = [...pending].map(([key, seconds]) => {
    const [day, domain] = key.split("|");
    return { day, domain, seconds };
  });
  pending.clear();
  try { await browser.runtime.sendNativeMessage("application.id", { usage }); } catch (e) { /* app unavailable; drop */ }
}

browser.tabs.onActivated.addListener(refresh);
browser.tabs.onUpdated.addListener((_, info) => { if (info.url || info.status === "complete") refresh(); });
browser.windows?.onFocusChanged?.addListener(refresh);
browser.alarms.create("vigil-flush", { periodInMinutes: 1 });
browser.alarms.onAlarm.addListener((a) => { if (a.name === "vigil-flush") flush(); });
refresh();
