/** The base64 payload of a data: URL. Cut after ";base64," — the MIME type itself can contain commas (codecs=vp8,opus). */
export function dataUrlToBase64(dataUrl: string): string {
  const marker = ";base64,";
  const i = dataUrl.indexOf(marker);
  return i >= 0 ? dataUrl.slice(i + marker.length) : "";
}

/** A Blob as base64 (via readAsDataURL, which is fast and native). */
export function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(dataUrlToBase64(String(r.result)));
    r.onerror = () => reject(r.error ?? new Error("Couldn't read the video chunk"));
    r.readAsDataURL(blob);
  });
}
