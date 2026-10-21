/** Pure helpers for the AirBattleground connect link (unit-tested). */

export interface ConnectLink {
  /** https://airbattleground.com (null when only a key was pasted: the server uses its default host) */
  host: string | null;
  key: string;
}

const KEY_RE = /^sw_[A-Za-z0-9_-]{8,}$/;

/**
 * Read what the manager scanned or pasted: the `7xen-studio://connect?host=…&key=sw_…` link from AirBattleground →
 * Manager → Studio → "Connect a studio", or just the `sw_…` key. Returns null when it's neither.
 */
export function parseConnectLink(raw: string): ConnectLink | null {
  const text = raw.trim();
  if (!text) return null;
  if (KEY_RE.test(text)) return { host: null, key: text };
  const m = /^7xen-studio:\/\/connect\/?\?(.*)$/i.exec(text);
  if (!m) return null;
  const params = new URLSearchParams(m[1]);
  const key = params.get("key")?.trim() ?? "";
  if (!KEY_RE.test(key)) return null;
  const hostRaw = params.get("host")?.trim() ?? "";
  let host: string | null = null;
  if (hostRaw) {
    try {
      const u = new URL(hostRaw);
      if (u.protocol !== "https:" && u.protocol !== "http:") return null;
      host = u.origin;
    } catch {
      return null;
    }
  }
  return { host, key };
}

/** "sw_abcd…wxyz" — enough to recognise a key without showing it. */
export function maskKey(key: string): string {
  return key.length <= 10 ? key : `${key.slice(0, 7)}…${key.slice(-4)}`;
}
