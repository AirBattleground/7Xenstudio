/**
 * AirBattleground connect links. Accepted forms:
 *   7xen-studio://connect?host=https://airbattleground.com&key=sw_…   (the QR on AirBattleground → Manager → Studio)
 *   https://airbattleground.com/…?key=sw_…                               (host = that origin)
 *   sw_…                                                                  (bare key, default host)
 */
export const DEFAULT_HOST = "https://airbattleground.com";
const KEY_RE = /^sw_[A-Za-z0-9_-]{8,200}$/;

export interface ParsedLink {
  host: string;
  key: string;
}

function cleanHost(raw: string): string | null {
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    return u.origin;
  } catch {
    return null;
  }
}

export function parseConnectLink(input: string): ParsedLink | null {
  const text = input.trim();
  if (KEY_RE.test(text)) return { host: DEFAULT_HOST, key: text };
  // custom scheme: "7xen-studio:" starts with a digit, which WHATWG URL rejects, so read the query by hand
  const custom = /^7xen-studio:\/\/connect\/?\?(.*)$/i.exec(text);
  if (custom) {
    const q = new URLSearchParams(custom[1]);
    const key = q.get("key")?.trim() ?? "";
    const host = cleanHost(q.get("host")?.trim() || DEFAULT_HOST);
    return host && KEY_RE.test(key) ? { host, key } : null;
  }
  if (/^https?:\/\//i.test(text)) {
    try {
      const u = new URL(text);
      const key = u.searchParams.get("key")?.trim() ?? "";
      const host = cleanHost(u.searchParams.get("host")?.trim() || u.origin);
      return host && KEY_RE.test(key) ? { host, key } : null;
    } catch {
      return null;
    }
  }
  return null;
}
