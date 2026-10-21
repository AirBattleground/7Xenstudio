export { RENDER_TOKEN_HEADER, RENDER_TOKEN_PARAM } from "@shared/types";
import { RENDER_TOKEN_PARAM } from "@shared/types";

/**
 * A media URL (<video>/<img> can't send headers) with the render token as `?t=`, which the server accepts for GETs.
 * Absolute URLs to other hosts are left alone (never leak the token).
 */
export function withToken(url: string, token: string | null): string {
  if (!token || !url.startsWith("/") || url.startsWith("//")) return url;
  return `${url}${url.includes("?") ? "&" : "?"}${RENDER_TOKEN_PARAM}=${encodeURIComponent(token)}`;
}
