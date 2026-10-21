/**
 * Everything signed with the studio secret:
 *   - phone publish tokens (live/dev_<id>?token=<exp>.<hmac>, tied to the device's key hash so removing a phone voids them)
 *   - the internal MediaMTX credentials (the server's own HLS reads / API calls)
 *   - render tokens (`<showId>.<hmac>`: the renderer's Chrome reads the show's data without the PIN cookie)
 *   - the PIN session cookie (`<exp>.<hmac>`, tied to the PIN, so changing STUDIO_PIN signs everyone out)
 */
import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export const PUBLISH_TOKEN_TTL_MS = 10 * 60_000;
export const SESSION_TTL_MS = 30 * 24 * 3600_000;
export const INTERNAL_USER = "studio";
export const SESSION_COOKIE = "studio_session";

const derive = (secret: Buffer, purpose: string) => createHash("sha256").update(`7xen-studio:${purpose}:`).update(secret).digest();

export function safeEqual(a: string, b: string) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export class Tokens {
  readonly internalPass: string;
  private readonly publishKey: Buffer;
  private readonly renderKey: Buffer;
  private readonly sessionKey: Buffer;

  constructor(secret: Buffer) {
    this.internalPass = derive(secret, "internal").toString("hex").slice(0, 40);
    this.publishKey = derive(secret, "publish");
    this.renderKey = derive(secret, "render");
    this.sessionKey = derive(secret, "session");
  }

  get internalAuthHeader() {
    return `Basic ${Buffer.from(`${INTERNAL_USER}:${this.internalPass}`).toString("base64")}`;
  }

  isInternal(user: string | undefined, password: string | undefined): boolean {
    return user === INTERNAL_USER && !!password && safeEqual(password, this.internalPass);
  }

  // ---------------------------------------------------------------- phones

  private signPublish(deviceId: string, keyHash: string, exp: number) {
    return createHmac("sha256", this.publishKey).update(`${deviceId}.${keyHash}.${exp}`).digest("base64url");
  }

  publishToken(deviceId: string, keyHash: string, now = Date.now()): { token: string; expiresAt: Date } {
    const exp = now + PUBLISH_TOKEN_TTL_MS;
    return { token: `${exp}.${this.signPublish(deviceId, keyHash, exp)}`, expiresAt: new Date(exp) };
  }

  verifyPublishToken(deviceId: string, keyHash: string, token: string, now = Date.now()): boolean {
    const [expStr, sig] = token.split(".");
    const exp = Number(expStr);
    if (!sig || !Number.isFinite(exp) || exp < now) return false;
    return safeEqual(sig, this.signPublish(deviceId, keyHash, exp));
  }

  // ---------------------------------------------------------------- render page

  renderToken(showId: string): string {
    return `${showId}.${createHmac("sha256", this.renderKey).update(showId).digest("base64url").slice(0, 32)}`;
  }

  /** The show id a render token is for (null when it isn't valid). */
  verifyRenderToken(token: string | null | undefined): string | null {
    if (!token || token.length > 120) return null;
    const dot = token.indexOf(".");
    if (dot <= 0) return null;
    const showId = token.slice(0, dot);
    return safeEqual(token, this.renderToken(showId)) ? showId : null;
  }

  // ---------------------------------------------------------------- PIN session

  private signSession(pin: string, exp: number) {
    return createHmac("sha256", this.sessionKey).update(`${createHash("sha256").update(pin).digest("hex")}.${exp}`).digest("base64url");
  }

  sessionCookie(pin: string, now = Date.now()): { value: string; maxAgeSec: number } {
    const exp = now + SESSION_TTL_MS;
    return { value: `${exp}.${this.signSession(pin, exp)}`, maxAgeSec: Math.floor(SESSION_TTL_MS / 1000) };
  }

  verifySession(pin: string, value: string | undefined, now = Date.now()): boolean {
    if (!value) return false;
    const [expStr, sig] = value.split(".");
    const exp = Number(expStr);
    if (!sig || !Number.isFinite(exp) || exp < now) return false;
    return safeEqual(sig, this.signSession(pin, exp));
  }
}
