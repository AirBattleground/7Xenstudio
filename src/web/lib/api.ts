import type { ApiErrorBody } from "@shared/types";

/** A failed API call: `code` + plain-English `message` (+ per-field messages for forms). */
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public fields?: Record<string, string>,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/** Called when the server says the PIN is needed (the app shows the PIN screen). */
let onPinRequired: (() => void) | null = null;
export function setPinRequiredHandler(fn: (() => void) | null) {
  onPinRequired = fn;
}

/** Extra headers on every request (the render page adds its render token). */
const extraHeaders: Record<string, string> = {};
export function setApiHeader(name: string, value: string | null) {
  if (value === null) delete extraHeaders[name];
  else extraHeaders[name] = value;
}
export const apiHeaders = () => ({ ...extraHeaders });

export async function toApiError(res: Response): Promise<ApiError> {
  const body = (await res.json().catch(() => null)) as Partial<ApiErrorBody> | null;
  const e = body?.error;
  const fallback = res.status === 413 ? "That file is too big." : res.status >= 500 ? "Something went wrong on the studio PC. Try again." : `Request failed (${res.status}).`;
  return new ApiError(res.status, e?.code ?? `HTTP_${res.status}`, e?.message ?? fallback, e?.fields);
}

async function request<T>(method: string, path: string, body?: unknown, init?: RequestInit): Promise<T> {
  const isForm = typeof FormData !== "undefined" && body instanceof FormData;
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "include",
      ...init,
      headers: { ...(body !== undefined && !isForm ? { "Content-Type": "application/json" } : {}), ...extraHeaders, ...(init?.headers as Record<string, string> | undefined) },
      body: body === undefined ? undefined : isForm ? body : JSON.stringify(body),
    });
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") throw e;
    throw new ApiError(0, "NETWORK", "Can't reach the studio PC. Check that 7XEN Studio is running.");
  }
  if (!res.ok) {
    const err = await toApiError(res);
    if (res.status === 401 && (err.code === "PIN_REQUIRED" || err.code === "UNAUTHENTICATED")) onPinRequired?.();
    throw err;
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

export const api = {
  get: <T>(path: string, init?: RequestInit) => request<T>("GET", path, undefined, init),
  post: <T>(path: string, body?: unknown, init?: RequestInit) => request<T>("POST", path, body, init),
  patch: <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
  put: <T>(path: string, body?: unknown) => request<T>("PUT", path, body),
  del: <T = void>(path: string) => request<T>("DELETE", path),
};

/** The message to show for any thrown error. */
export function errorMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message;
  if (e instanceof Error) return e.message;
  return "Something went wrong.";
}
