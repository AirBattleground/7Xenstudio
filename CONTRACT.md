# 7XEN Studio: standalone app contract

A self-contained live-production studio for a venue PC. Phones (the 7XEN Stream iOS app) connect over the local Wi-Fi.
The manager builds scenes in the browser, and the app renders and encodes the show on this PC. The finished show is
recorded to disk and/or streamed to any RTMP destination (YouTube, Facebook, custom) using stream keys stored locally.

**Independence rule:** this folder has **no code connection to AirBattleground**: no imports from `@7xen/*` or
`../apps|packages|services`, no calls to airbattleground.com, and no AirBattleground concepts (matches, teams, scrims).
It has its own `package.json` and lockfile, and is NOT part of the root pnpm workspace (it has its own
`pnpm-workspace.yaml`, so pnpm treats it as its own root). Code may be **copied** from the 7xen repo and adapted
(mixer engine, UI components, worker pipeline, device API); copies must not import anything outside `studio-app/`.

## Layout

```text
studio-app/
  package.json  pnpm-workspace.yaml (packages: [])  tsconfig.json  vite.config.ts  index.html
  .env.example  README.md  docker-compose.yml  mediamtx.yml
  src/shared/      types + zod schemas shared by server and web (types.ts = this contract in code)
  src/server/      Node 24 + TypeScript (run with tsx): HTTP API, device API, MediaMTX auth, store, SSE, static web
  src/server/pipeline/   renderer: headless Chrome on /render/:showId → MediaRecorder chunks → ffmpeg → outputs
  src/web/         React 18 + Vite + Tailwind v4 + copied shadcn/ui components; console, phones, recordings, settings
  data/            (gitignored) store.json, secret, props/, recordings/
```

Scripts: `pnpm dev` (server with tsx watch + vite dev server proxying /api, /box-less), `pnpm build` (vite build → dist/web),
`pnpm start` (production: server serves dist/web), `pnpm typecheck`, `pnpm test` (vitest).

## Runtime

- One server process, default **port 4400** (`PORT`), listening on 0.0.0.0 (LAN).
  - Serves the web app (`dist/web`, SPA fallback) and everything below.
- **MediaMTX** (docker compose, host network). Phones publish here.
  - Defaults RTMP `:1940` (LAN), HLS `127.0.0.1:8893`, API `127.0.0.1:9994`. All configurable: `MEDIA_RTMP_PORT`, `MEDIA_HLS_URL`, `MEDIA_API_URL`.
  - Auth hook → `http://127.0.0.1:<PORT>/internal/media/auth`.
- **Renderer** (pipeline), started by the server when a show goes live:
  - Real Google Chrome (playwright-core `channel: "chrome"` or `CHROME_PATH`), headless, opening `http://127.0.0.1:<PORT>/render/<showId>?t=<render token>`.
  - It exposes `window.__swChunk(base64)` and `window.__swStatus({fps, recording, error})` before load.
  - ffmpeg (`FFMPEG_PATH`) reads the WebM chunks from stdin and encodes H.264 720p at the show's fps (GPU encoder when available: nvenc/qsv/amf/videotoolbox, else libx264).
  - Output goes through the tee muxer to every target:
    - recording file `data/recordings/<YYYY-MM-DD_HH-mm-ss>_<slug>_<showId>.mp4` (fragmented MP4: `movflags=+frag_keyframe+empty_moov+default_base_moof`)
    - each enabled RTMP destination (`onfail=ignore`)
    - the local MediaMTX path `live/show_<showId>` (the console's "Program out" preview).
  - Restart rules: ffmpeg and Chrome always restart together (the WebM header is only in the first chunk). No chunk for 15 s → restart, with backoff.
- Data: `DATA_DIR` (default `./data`). JSON store written atomically. Secrets (`data/secret`) are created on first run.
- Access: LAN only. Optional `STUDIO_PIN`: when set, the web asks for the PIN once.
  - `POST /api/session { pin }` sets an httpOnly cookie. Every `/api/*` route except `/api/session`, `/api/device/*` and the render token routes requires it.
  - Without `STUDIO_PIN`, everything is open on the LAN.

## Data model (src/shared/types.ts)

```ts
type Id = string;
interface Device { id; name; createdAt; model|null; osVersion|null; appVersion|null; lastSeenAt|null }   // key stored as sha256 only
interface DeviceRow extends Device { online; streaming; videoReady; streamingSince|null; health: DeviceHealth|null; hlsUrl /* /api/devices/:id/live/index.m3u8 */ }
interface Destination { id; name; kind: "YOUTUBE"|"FACEBOOK"|"CUSTOM"; url; keyHint /* last 4 */ }   // key stored in data/store.json, never returned
type SourceRef = {kind:"device"; id} | {kind:"camera"} | {kind:"prop"; id} | {kind:"slate"} | {kind:"image"; id} | {kind:"web"; url}
type LayoutKind = "full"|"side"|"pip"|"desk"|"trio"
interface Scene { id; name; layout: LayoutKind; slots: (SourceRef|null)[] }
interface Overlays { liveBug; lowerThird; lowerTitle; lowerSubtitle; ticker; tickerText;
                     logo: { on; propId|null; corner: "tl"|"tr"|"bl"|"br" };   // image prop
                     web: { on; url };                                        // transparent page drawn full-frame (e.g. a scoreboard URL)
                     slateText }                                              // text on the slate scene
interface ShowConfig { v: 1; scenes: Scene[]; overlays: Overlays; transition: "cut"|"fade"; introPropId|null }
interface Show { id; title; createdAt; updatedAt; config: ShowConfig;
                 outputs: { record: boolean; destinationIds: Id[] };          // what Go live does
                 fps: 30|60; videoKbps: number;                                // default 60 / 6000
                 state: "IDLE"|"LIVE"; liveSince|null }
interface Control { version: number; programId|null; takeSeq: number }       // live switching state
interface ShowStatus { state; liveSince; renderer: { state: "idle"|"starting"|"live"|"error"; fps|null; encoder|null; bitrateKbps|null; error|null };
                       outputs: { id; name; kind: "record"|"rtmp"|"preview"; ok: boolean; error|null }[]; recordingFile|null }
interface Prop { id; name; kind: "video"|"image"; sizeBytes; url /* /api/props/:id/file */ }
interface Recording { file; title; showId|null; sizeBytes; startedAt; updatedAt; recording: boolean }
interface Recordings { items: Recording[]; disk: { freeBytes; totalBytes } }
interface StudioInfo { name; lanUrl; version; mediaRtmp: string /* rtmp://<lan>:<port>/live */; encoder|null; pinRequired: boolean; authed: boolean }
```

## HTTP API (JSON; errors `{ error: { code, message, fields? } }`, plain English)

| Method & path | Body → Response |
|---|---|
| GET `/api/info` | → StudioInfo (no auth) |
| POST `/api/session` | `{pin}` → 204 + cookie (only when STUDIO_PIN) |
| PATCH `/api/settings` | `{name?}` → StudioInfo |
| GET/POST `/api/devices` | → `{items: DeviceRow[]}` / `{name}` → `{device: DeviceRow, key, pairUrl}` (201; key shown once) |
| PATCH/DELETE `/api/devices/:id` | `{name}` → DeviceRow / 204 |
| GET `/api/devices/:id/live/<hls file>` | the phone's HLS from MediaMTX (same origin) |
| GET `/api/devices/:id/snapshot.png` | native screenshot via the phone's next heartbeat (504 after 5 s) |
| GET/POST `/api/destinations` | → `{items}` / `{kind,name,url,streamKey}` → Destination |
| PATCH/DELETE `/api/destinations/:id` | partial → Destination / 204 |
| GET/POST `/api/shows` | → `{items: Show[]}` / `{title}` → Show (default config: Starting soon / Phone / Host / Break scenes) |
| GET/PATCH/DELETE `/api/shows/:id` | → Show / `{title?, config?, outputs?, fps?, videoKbps?}` → Show / 204 (not while live) |
| GET `/api/shows/:id/control?since=N` | long-poll ≤ 25 s → `Control & { config, title, state, liveSince }` |
| PATCH `/api/shows/:id/control` | `{programId, takeSeq}` → `{version}` |
| POST `/api/shows/:id/start` | → ShowStatus (409 if another show is live: one show at a time) |
| POST `/api/shows/:id/stop` | → ShowStatus |
| GET `/api/shows/:id/status` | → ShowStatus |
| GET `/api/shows/:id/live/<hls file>` | the finished show (Program out preview) from MediaMTX |
| GET/POST `/api/props` | → `{items: Prop[]}` / multipart `file` (video ≤ 500 MB, image ≤ 10 MB) + `name` → Prop |
| GET `/api/props/:id/file` · DELETE `/api/props/:id` | the file (Range) / 204 |
| GET `/api/recordings` | → Recordings |
| GET/DELETE `/api/recordings/:file` | MP4 with Range (`?download=1` = attachment) / 204 (409 while recording) |
| POST `/internal/media/auth` | MediaMTX hook (127.0.0.1 only) |

The render page uses the same `/api/shows/:id`, `/control`, `/api/devices`, `/api/props/:id/file` routes. When a PIN is set,
it authenticates with `?t=<render token>` (HMAC of showId), which the server accepts as a cookie substitute for GETs.

## Device API for the 7XEN Stream app (unchanged contract)

Header `X-Device-Key`, under `/api/device/`:
- `POST hello` `{deviceModel, osVersion, appVersion}` → `{device:{id,name}, manager:{name: studioName}, studio:{name}, assignedMatch:null}`
- `POST stream/start` `{quality, fps?}` → `{rtmpUrl: rtmp://<lan>:<rtmp port>/live, streamName: "dev_<id>?token=<t>", expiresAt}`
- `POST heartbeat` (health) → `{assignedMatch:null, snapshotRequests:[{id}]}`
- `POST snapshots/:requestId` (multipart `image` PNG) → 204
- `POST stream/stop` → 204
- `401 {error:{code:"DEVICE_KEY_INVALID"}}` for a bad key.
- QR: `7xen://pair?host=<lanUrl>&key=<key>&name=<studio name>`. See `docs/phase8/IOS_APP_STUDIO_BOX_BRIEF.md` in the 7xen repo, the same app contract.

## Web UI (plain English, big readable controls, light/dark theme, mobile-friendly lists)

- **Shows** (home): list and create. Each card: title, LIVE/REC badge, Open.
- **Console** (`/shows/:id`), ported from the 7xen Studio console without match features:
  - Monitors and switching: Program and Preview monitors (the browser runs its own StudioMixer for preview; the server's renderer produces the actual output), scenes grid with TAKE, cut/fade, keys 1–9.
  - Sources panel: phones (from `/api/devices`, with Add phone + QR), webcam, props upload (video/image), slate.
  - Overlays panel: LIVE bug, lower third, ticker, logo, web overlay URL.
  - **Outputs** panel: **Record on this PC** switch plus a destination switch per stream key, with Add stream key.
  - Main button: **Go live** / **Start recording** (record only) / **End show**. Status bar: renderer fps, encoder (GPU/CPU), bitrate, per-output health.
  - Scene editor dialog.
- **Phones** (`/phones`): list (online/streaming, battery, temperature, fps), Add phone (QR + key once + 3 steps), rename/remove, live preview.
- **Recordings** (`/recordings`): play (dialog `<video>`), download, delete, free disk.
- **Settings** (`/settings`): studio name, stream keys, PIN status, media RTMP address, encoder.
- Render page (`/render/:showId`): no chrome. The mixer is driven by control state. It records with MediaRecorder at 12 Mbps (prefer `video/webm;codecs=h264,opus`, else vp8) in 500 ms chunks, sent in order through `__swChunk`. A silent audio source keeps the audio track alive.

## Known pitfalls carried over from the 7xen Studio (must keep)

- AudioContext `resume()` can hang in headless Chrome: never await it unbounded (race with 500 ms).
- MediaRecorder emits nothing if the audio track has no samples: feed a silent ConstantSource into the mix.
- Base64 of a Blob via `readAsDataURL`: cut after `;base64,` (the MIME type `codecs=vp8,opus` contains a comma).
- Keyframes by time: `-force_key_frames expr:gte(t,n_forced*2)`. tee needs `-flags +global_header` and explicit `-map`.
- Create the mixer inside `useEffect` (StrictMode double-mount).

## Extensions (connections): optional, isolated

The core knows only a generic **integration** interface. An integration can provide:
- **events**: things to link a show to (for AirBattleground, matches);
- **outputs**: extra destinations offered at go-live (Live page, a YouTube channel, stream keys). They come back as ready RTMP targets when the show starts;
- **capture**: an upload of a still of the program (e.g. a team list or results to a match).

Core code under `src/server` / `src/web` must not import an integration directly. It goes through
`src/server/integrations/registry.ts` and `src/web/integrations/registry.tsx` only. Each integration lives in its own folder:
`src/server/integrations/<id>/` and `src/web/integrations/<id>/`. Delete the folder and its registry line, and the app still builds and works.

### Generic integration API (studio server)

| Method & path | Body → Response |
|---|---|
| GET `/api/integrations` | → `{items: IntegrationInfo[]}` |
| POST `/api/integrations/:id/connect` | `{link}` (scanned QR text or pasted link/key) → IntegrationInfo |
| DELETE `/api/integrations/:id` | → 204 (disconnect; forgets the key) |
| GET `/api/integrations/:id/events` | → `{items: StudioEvent[]}` |
| GET `/api/integrations/:id/outputs` | → `{items: IntegrationOutput[]}` |
| POST `/api/integrations/:id/events/:eventId/capture` | multipart `file` (PNG) + `kind` → `{ok: true}` |

`Show.link` (additive): `{ integration: string; eventId: string|null; eventTitle: string|null; outputIds: string[] } | null`.
- On start, the server calls `integration.startBroadcast(show)` → `{ broadcastId, targets: {id,name,url}[] }`. The targets join the tee next to the recording and the local stream keys.
- While live, it calls `heartbeat(broadcastId, status)` every 10 s. If the answer is `{stop: true}`, the show ends.
- On end, it calls `stopBroadcast(broadcastId)`.
- If the integration fails at start, the show still starts with the local outputs, and the status shows the integration error.

```ts
interface IntegrationInfo { id: string; name: string; connected: boolean; account: { name: string; org: string|null } | null; host: string|null; error: string|null }
interface StudioEvent { id: string; title: string; subtitle: string; startsAt: string|null; status: "upcoming"|"live"|"done" }
interface IntegrationOutput { id: string; name: string; kind: "live-page"|"youtube"|"rtmp"; defaultOn: boolean }
```

### The AirBattleground integration (`id: "airbattleground"`)

- **Connect by scanner:** AirBattleground → Manager → Studio → "Connect a studio" shows a QR with
  `7xen-studio://connect?host=https://airbattleground.com&key=sw_…`.
  - The Studio's "Connect AirBattleground" dialog scans it with the PC's webcam (BarcodeDetector in Chrome) or takes a pasted link or key.
  - The key is stored in `data/store.json` and is only sent to `host`.
- It talks to AirBattleground's **studio-link API** with header `X-Studio-Key: <key>`:

| AirBattleground endpoint | → |
|---|---|
| GET `/api/studio-link/me` | `{manager:{name}, org:{name}|null}` |
| GET `/api/studio-link/matches` | `{items: [{id, title, subtitle, startsAt, status}]}` (the manager's matches, recent + upcoming) |
| GET `/api/studio-link/outputs` | `{livePage: true, siteYoutube: {channelTitle}|null, destinations: [{id, name, kind}]}` |
| POST `/api/studio-link/broadcasts` | `{matchId|null, title, livePage, siteYoutube, destinationIds}` → `{id, targets: [{id,name,url}], watchUrl|null}` |
| POST `/api/studio-link/broadcasts/:id/heartbeat` | `{state, fps, bitrateKbps}` → `{stop: boolean}` |
| POST `/api/studio-link/broadcasts/:id/stop` | → 204 |
| POST `/api/studio-link/matches/:id/screenshots` | multipart `files` + `kind` (`SLOT_LIST`/`RESULTS`) → `{count}` |

- Its outputs map to `IntegrationOutput` ids: `abg:live-page`, `abg:youtube`, `abg:key:<destinationId>`.
- When YouTube is on, the Live page embeds the YouTube video. Otherwise the Live page gets its own copy (a target pointing at AirBattleground's media server).
- Console UI when connected:
  - a **Match** picker (events);
  - in Outputs, an "AirBattleground" group with a switch per output;
  - in the program bar, **Team list / Results** capture buttons that upload a still of the program to the linked match.
