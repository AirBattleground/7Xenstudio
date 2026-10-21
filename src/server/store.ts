/**
 * The studio's little database: DATA_DIR/store.json (phones, stream keys, shows, props, settings, integration state)
 * and DATA_DIR/secret (generated once; signs tokens and cookies). Writes are atomic (temp file + rename).
 */
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DEVICE_KEY_PREFIX, type DestinationKind, type Show } from "../shared/types.js";

export interface StoredDevice {
  id: string;
  name: string;
  /** sha256 of the key (the key itself is shown once and never stored) */
  keyHash: string;
  createdAt: string;
  model: string | null;
  osVersion: string | null;
  appVersion: string | null;
  lastHelloAt: string | null;
}

export interface StoredDestination {
  id: string;
  name: string;
  kind: DestinationKind;
  url: string;
  /** stored in clear (needed to stream); never returned by the API */
  streamKey: string;
  createdAt: string;
}

export interface StoredProp {
  id: string;
  name: string;
  kind: "video" | "image";
  sizeBytes: number;
  /** file name inside DATA_DIR/props */
  file: string;
  mime: string;
  createdAt: string;
}

export interface StoreDoc {
  devices: StoredDevice[];
  destinations: StoredDestination[];
  shows: Show[];
  props: StoredProp[];
  settings: { name: string | null };
  /** per-integration state (e.g. a connection key), opaque to the core */
  integrations: Record<string, unknown>;
}

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
export const newDeviceKey = () => DEVICE_KEY_PREFIX + randomBytes(24).toString("base64url");
/** 24 lowercase alphanumerics: fits MediaMTX's live/(dev|show)_[A-Za-z0-9]{8,40} paths */
export const newId = (prefix = "s") => prefix + randomBytes(12).toString("hex").slice(0, 23);

export function writeAtomic(file: string, data: string | Buffer, mode?: number) {
  const tmp = `${file}.${process.pid}.${Date.now()}.${randomBytes(3).toString("hex")}.tmp`;
  writeFileSync(tmp, data, mode ? { mode } : undefined);
  renameSync(tmp, file);
}

const empty = (): StoreDoc => ({ devices: [], destinations: [], shows: [], props: [], settings: { name: null }, integrations: {} });

export class Store {
  readonly secret: Buffer;
  readonly doc: StoreDoc;
  readonly propsDir: string;
  readonly recordingsDir: string;
  private readonly file: string;

  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true });
    this.propsDir = path.join(dir, "props");
    this.recordingsDir = path.join(dir, "recordings");
    mkdirSync(this.propsDir, { recursive: true });
    mkdirSync(this.recordingsDir, { recursive: true });
    const secretFile = path.join(dir, "secret");
    if (!existsSync(secretFile)) writeAtomic(secretFile, randomBytes(32).toString("hex"), 0o600);
    this.secret = Buffer.from(readFileSync(secretFile, "utf8").trim(), "hex");
    if (this.secret.length < 16) throw new Error(`${secretFile} is damaged: delete it (phones must then be added again)`);
    this.file = path.join(dir, "store.json");
    const doc = empty();
    if (existsSync(this.file)) {
      const raw = JSON.parse(readFileSync(this.file, "utf8")) as Partial<StoreDoc>;
      for (const k of ["devices", "destinations", "shows", "props"] as const) if (Array.isArray(raw[k])) (doc[k] as unknown[]) = raw[k]!;
      if (raw.settings && typeof raw.settings === "object") doc.settings = { name: raw.settings.name ?? null };
      if (raw.integrations && typeof raw.integrations === "object") doc.integrations = raw.integrations;
    }
    for (const s of doc.shows) s.link ??= null;
    this.doc = doc;
  }

  save() {
    writeAtomic(this.file, JSON.stringify(this.doc, null, 2));
  }

  // ---------------------------------------------------------------- devices

  device(id: string) {
    return this.doc.devices.find((d) => d.id === id);
  }
  deviceByKey(key: string) {
    const h = sha256(key);
    return this.doc.devices.find((d) => d.keyHash === h);
  }
  devices() {
    return [...this.doc.devices].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  // ---------------------------------------------------------------- integrations

  integrationState<T>(id: string): T | null {
    return (this.doc.integrations[id] as T | undefined) ?? null;
  }
  setIntegrationState(id: string, value: unknown) {
    if (value === null || value === undefined) delete this.doc.integrations[id];
    else this.doc.integrations[id] = value;
    this.save();
  }
}
