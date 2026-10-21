/**
 * Phones: the device API logic (7XEN Stream app), live state from heartbeats (memory only), snapshot requests riding
 * on heartbeat replies, and DeviceRow for the web app.
 */
import { randomUUID } from "node:crypto";
import {
  DEVICE_KEY_PREFIX,
  DEVICE_ONLINE_WINDOW_MS,
  type DeviceHealth,
  type DeviceHeartbeatResponse,
  type DeviceHelloResponse,
  type DeviceRow,
  type DeviceStreamStartResponse,
  type deviceHeartbeatSchema,
  type deviceHelloSchema,
} from "../shared/types.js";
import type { z } from "zod";
import { HttpError, notFound } from "./http.js";
import { devicePath, type Media } from "./media.js";
import { newDeviceKey, newId, sha256, type Store, type StoredDevice } from "./store.js";
import type { Tokens } from "./tokens.js";

export const MAX_DEVICES = 50;
const SNAPSHOT_TTL_MS = 20_000;
export const DEVICE_KEY_INVALID_MESSAGE = "This key doesn't work. Add the phone again in 7XEN Studio → Phones.";

interface Live {
  lastSeenAt: number;
  state: "IDLE" | "LIVE";
  streamingSince: number | null;
  health: DeviceHealth | null;
}

interface PendingSnapshot {
  id: string;
  deviceId: string;
  at: number;
  sent: boolean;
  resolve: (png: Buffer | null) => void;
}

export interface DevicesDeps {
  store: Store;
  tokens: Tokens;
  media: Pick<Media, "pathReady" | "kick">;
  studioName: () => string;
  lanHost: string;
  rtmpPort: number;
  now?: () => number;
}

export class Devices {
  private live = new Map<string, Live>();
  private snapshots = new Map<string, PendingSnapshot>();
  private readonly now: () => number;

  constructor(private readonly d: DevicesDeps) {
    this.now = d.now ?? Date.now;
  }

  // ---------------------------------------------------------------- phone

  fromKey(key: string | undefined): StoredDevice {
    const k = key?.trim();
    const dev = k && k.startsWith(DEVICE_KEY_PREFIX) && k.length <= 100 ? this.d.store.deviceByKey(k) : undefined;
    if (!dev) throw new HttpError(401, "DEVICE_KEY_INVALID", DEVICE_KEY_INVALID_MESSAGE);
    return dev;
  }

  private touch(id: string): Live {
    let l = this.live.get(id);
    if (!l) {
      l = { lastSeenAt: 0, state: "IDLE", streamingSince: null, health: null };
      this.live.set(id, l);
    }
    l.lastSeenAt = this.now();
    return l;
  }

  hello(dev: StoredDevice, input: z.infer<typeof deviceHelloSchema>): DeviceHelloResponse {
    this.touch(dev.id);
    dev.model = input.deviceModel ?? dev.model;
    dev.osVersion = input.osVersion ?? dev.osVersion;
    dev.appVersion = input.appVersion ?? dev.appVersion;
    dev.lastHelloAt = new Date(this.now()).toISOString();
    this.d.store.save();
    const name = this.d.studioName();
    return { device: { id: dev.id, name: dev.name }, manager: { name }, studio: { name }, assignedMatch: null };
  }

  heartbeat(dev: StoredDevice, input: z.infer<typeof deviceHeartbeatSchema>): DeviceHeartbeatResponse {
    const prev = this.live.get(dev.id);
    const now = this.now();
    const wasLive = !!prev && prev.state === "LIVE" && now - prev.lastSeenAt <= DEVICE_ONLINE_WINDOW_MS;
    const l = this.touch(dev.id);
    const state = input.state ?? l.state;
    l.state = state;
    l.streamingSince = state === "LIVE" ? (wasLive ? (prev?.streamingSince ?? now) : now) : null;
    const h: DeviceHealth = {};
    for (const k of ["state", "quality", "autoDowngraded", "battery", "charging", "thermal", "cpuPct", "memMB", "fps", "bitrateKbps", "width", "height", "network"] as const) {
      if (input[k] !== undefined) (h as Record<string, unknown>)[k] = input[k];
    }
    l.health = h;
    return { assignedMatch: null, snapshotRequests: this.takeSnapshotRequests(dev.id) };
  }

  streamStart(dev: StoredDevice): DeviceStreamStartResponse {
    this.touch(dev.id);
    const { token, expiresAt } = this.d.tokens.publishToken(dev.id, dev.keyHash, this.now());
    return {
      rtmpUrl: `rtmp://${this.d.lanHost}:${this.d.rtmpPort}/live`,
      streamName: `dev_${dev.id}?token=${token}`,
      expiresAt: expiresAt.toISOString(),
    };
  }

  streamStop(dev: StoredDevice) {
    const l = this.touch(dev.id);
    l.state = "IDLE";
    l.streamingSince = null;
  }

  // ---------------------------------------------------------------- snapshots

  private sweep() {
    const now = this.now();
    for (const p of this.snapshots.values()) {
      if (now - p.at > SNAPSHOT_TTL_MS) {
        this.snapshots.delete(p.id);
        p.resolve(null);
      }
    }
  }

  takeSnapshotRequests(deviceId: string): { id: string }[] {
    this.sweep();
    const out: { id: string }[] = [];
    for (const p of this.snapshots.values()) {
      if (p.deviceId === deviceId && !p.sent) {
        p.sent = true;
        out.push({ id: p.id });
      }
    }
    return out;
  }

  /** The phone uploaded the PNG for a request. False when unknown / expired / another device's. */
  fulfilSnapshot(deviceId: string, requestId: string, png: Buffer): boolean {
    const p = this.snapshots.get(requestId);
    if (!p || p.deviceId !== deviceId) return false;
    this.snapshots.delete(requestId);
    p.resolve(png);
    return true;
  }

  /** Ask the phone for a full-quality screenshot (rides on its next heartbeat reply); null after `waitMs`. */
  requestSnapshot(deviceId: string, waitMs = 5_000): Promise<Buffer | null> {
    return new Promise((resolve) => {
      const id = randomUUID();
      const timer = setTimeout(() => {
        this.snapshots.delete(id);
        resolve(null);
      }, waitMs);
      this.snapshots.set(id, {
        id,
        deviceId,
        at: this.now(),
        sent: false,
        resolve: (png) => {
          clearTimeout(timer);
          resolve(png);
        },
      });
    });
  }

  // ---------------------------------------------------------------- web app

  async row(dev: StoredDevice): Promise<DeviceRow> {
    const video = await this.d.media.pathReady(devicePath(dev.id));
    const l = this.live.get(dev.id);
    const now = this.now();
    const online = !!l && now - l.lastSeenAt <= DEVICE_ONLINE_WINDOW_MS;
    // video arriving wins over the phone's own state (the app's heartbeat can say IDLE while its extension streams)
    const streaming = !!video || (online && l?.state === "LIVE");
    const since = l?.state === "LIVE" && l.streamingSince ? new Date(l.streamingSince) : (video?.readySince ?? null);
    return {
      id: dev.id,
      name: dev.name,
      createdAt: dev.createdAt,
      model: dev.model,
      osVersion: dev.osVersion,
      appVersion: dev.appVersion,
      lastSeenAt: l?.lastSeenAt ? new Date(l.lastSeenAt).toISOString() : dev.lastHelloAt,
      online,
      streaming,
      videoReady: !!video,
      streamingSince: streaming && since ? since.toISOString() : null,
      health: online ? (l?.health ?? null) : null,
      hlsUrl: `/api/devices/${dev.id}/live/index.m3u8`,
    };
  }

  rows(): Promise<DeviceRow[]> {
    return Promise.all(this.d.store.devices().map((dev) => this.row(dev)));
  }

  create(name: string): { device: StoredDevice; key: string } {
    if (this.d.store.doc.devices.length >= MAX_DEVICES) throw new HttpError(409, "CONFLICT", `You can add up to ${MAX_DEVICES} phones. Remove one first.`);
    const key = newDeviceKey();
    const device: StoredDevice = {
      id: newId("d"),
      name,
      keyHash: sha256(key),
      createdAt: new Date(this.now()).toISOString(),
      model: null,
      osVersion: null,
      appVersion: null,
      lastHelloAt: null,
    };
    this.d.store.doc.devices.push(device);
    this.d.store.save();
    return { device, key };
  }

  rename(id: string, name: string): StoredDevice {
    const dev = this.d.store.device(id);
    if (!dev) throw notFound("Phone not found");
    dev.name = name;
    this.d.store.save();
    return dev;
  }

  async remove(id: string) {
    const doc = this.d.store.doc;
    const before = doc.devices.length;
    doc.devices = doc.devices.filter((d) => d.id !== id);
    if (doc.devices.length === before) throw notFound("Phone not found");
    this.d.store.save();
    this.live.delete(id);
    await this.d.media.kick(devicePath(id));
  }
}
