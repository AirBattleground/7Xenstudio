# 7XEN Studio

Live production on a venue PC. Phones running the 7XEN Stream app connect over the local Wi-Fi. You build scenes in
the browser, and this PC renders, records and streams the show to YouTube, Facebook or any RTMP server.
It runs on its own and needs no online account. The spec is in [CONTRACT.md](CONTRACT.md).

## Run it

Requirements: Node 24, pnpm, Docker (for the media server), ffmpeg, and Google Chrome (for the renderer).

```bash
cp .env.example .env          # optional: everything has defaults
docker compose up -d          # MediaMTX: RTMP :1940 (phones), HLS 127.0.0.1:8893, API 127.0.0.1:9994
pnpm install
pnpm build && pnpm start      # http://<this PC's LAN IP>:4400
# or, while developing:
pnpm dev                      # server (tsx watch, :4400) + vite (http://localhost:5180, proxies /api)
```

Open TCP **1940** (phones' RTMP) and **4400** (web app + phone API) in the PC's firewall for the venue Wi-Fi.

## Settings (.env)

| Variable | Default | |
|---|---|---|
| `PORT` | 4400 | web app + API |
| `LAN_HOST` / `LAN_URL` | first private IPv4 | the address phones and other PCs use |
| `STUDIO_NAME` | 7XEN Studio | Settings can change it |
| `STUDIO_PIN` | (none) | when set, each browser enters the PIN once |
| `DATA_DIR` | ./data | `store.json`, `secret`, `props/`, `recordings/` |
| `MEDIA_RTMP_PORT`, `MEDIA_HLS_URL`, `MEDIA_API_URL` | 1940, http://127.0.0.1:8893, http://127.0.0.1:9994 | must match docker-compose (`MEDIA_HLS_PORT`, `MEDIA_API_PORT`) |
| `WEB_DIST` | ./dist/web | the built web app |
| `FFMPEG_PATH`, `CHROME_PATH`, `ENCODER`, `CHROME_ARGS` | auto | renderer |

## How the server works (src/server)

- **One process** (`index.ts` → `app.ts`, plain `node:http`): the web app (SPA), the studio API under `/api`, the phone
  API under `/api/device/*`, and the MediaMTX auth hook `/internal/media/auth` (127.0.0.1 only).
- **Store** (`store.ts`): `data/store.json`, written atomically (temp file + rename). It holds phones (key hash only),
  stream keys, shows, props, settings and integration state. `data/secret` is created once and signs every token.
- **Phones** (`devices.ts`): the key is shown once and stored as sha256. `stream/start` returns a 10-minute signed
  publish token for `live/dev_<id>`. Online means a heartbeat in the last 30 s. Streaming and video-ready come from
  MediaMTX (`/v3/paths/get`). The server proxies HLS same-origin at `/api/devices/:id/live/*`. Snapshot requests ride on heartbeats.
- **Media auth** (`media.ts`): phones may publish only their own path with a valid token. Publishing `live/show_<id>`
  (the renderer's preview) and all reads are allowed only from this PC. The server's own calls use internal credentials
  derived from the secret.
- **Shows** (`shows.ts`): CRUD, a control long-poll (≤ 25 s, woken on any change), and one live show at a time.
  Go live builds the pipeline targets: the recording directory (the pipeline names a file per restart:
  `<YYYY-MM-DD_HH-mm-ss>_<slug>_<showId>.mp4`), each enabled stream key (`url/key`), the local preview
  `rtmp://127.0.0.1:<rtmp>/live/show_<id>`, and any integration targets. It then starts the renderer
  (`pipeline/types.ts` is the interface) on `/render/<id>?t=<render token>`. A show that was live when the server
  stopped comes back idle.
- **Access**: without `STUDIO_PIN` everything is open on the LAN. With a PIN, `POST /api/session {pin}` sets an
  httpOnly cookie, and every `/api/*` route needs it except `/api/info`, `/api/session` and `/api/device/*`. The render
  page instead sends its render token (`?t=` or the `X-Render-Token` header), which opens only the GETs it needs:
  its own show, control and status, plus devices (and their HLS) and props.
- **Props / recordings**: uploads stream to disk (video ≤ 500 MB, image ≤ 10 MB). Files are served with HTTP Range.
  A recording written in the last 10 s counts as still recording and can't be deleted.
- **Integrations** (`integrations/registry.ts`): optional connections behind a generic interface (events, extra
  outputs, captures). Each one lives in its own folder; remove the folder and its registry line, and the studio still works.

## Web UI (src/web)

React 19 + Vite + Tailwind v4, with shadcn/ui components copied into `src/web/components/ui` (light/dark theme
tokens in `src/web/styles/globals.css`; theme saved per browser). Dev server: `pnpm dev:web` on :5180, proxying
`/api` to :4400. Build: `pnpm build` → `dist/web`.

- **Pages**: Shows (`/`), Console (`/shows/:id`), Phones (`/phones`), Recordings (`/recordings`), Settings
  (`/settings`). A PIN screen appears when the studio has a PIN and this browser hasn't entered it.
- **Mixer** (`engine/mixer.ts`): draws scenes and overlays on a 1280×720 canvas, with a Web Worker clock so it keeps
  running in background tabs. Phones play their same-origin HLS through hls.js. Props (videos/images) come from
  `/api/props/:id/file`. **Web sources and the web overlay are image URLs that update** (for example a scoreboard PNG
  endpoint): they reload every 2 s. A web *page* can't be drawn on a canvas. Images from other sites must allow CORS,
  or the slot shows a note instead.
- **Console**: the browser runs its own mixer for the Program and Preview monitors. Every take is sent with
  `PATCH /api/shows/:id/control`, and config changes autosave after 300 ms. The main button reads **Start recording**
  when only "Record on this PC" is on, **Go live** when any stream output is on, and **End show** while live. While
  live, status is polled every 2 s (renderer fps, GPU/CPU encoder, bitrate, per-output health, recording file).
- **Render page** (`/render/:showId?t=<token>`): this is what the renderer's headless Chrome opens. It sends the token
  as `X-Render-Token` on every fetch and hls.js request, and as `?t=` on `<video>`/`<img>` URLs. It long-polls control
  (from `since=-1`) and waits for the first take. If `window.__swChunk` exists, it records at 12 Mbps
  (`video/webm;codecs=h264,opus`, else VP8) in 500 ms chunks and hands them over in order as base64.
  `window.__swStatus` is called every second. Webcam slots show the slate here. Prop videos with sound need Chrome's
  `--autoplay-policy=no-user-gesture-required`.
- **Integrations**: `src/web/integrations/registry.tsx` is the only place core UI touches them. An integration module
  can provide a `ConnectPanel` (Settings → Connections), an `EventPicker` (console top bar), an `OutputsGroup`
  (console Outputs) and `ProgramActions` (under the program monitor). Remove `integrations/<id>/` and its registry
  line, and the app still builds.
- Tests: `tests/web*.test.ts` cover the pure helpers: config defaults, scene resolving, go-live mode, base64, token
  URLs and the connect-link parser.

## Tests

`pnpm test` (vitest): `tests/server*.test.ts` cover the phone API, media auth, show targets and the one-show rule,
the control long-poll, PIN and render token, uploads and Range, and the integration against a fake HTTP server.
