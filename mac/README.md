# 7XEN Studio for macOS

Native SwiftUI rewrite of the 7XEN Studio console: phones stream in over the LAN (MediaMTX / HLS), a Metal compositor
mixes scenes at 1080p60, and a VideoToolbox pipeline records and streams to YouTube / Facebook / custom RTMP.

Requires macOS 14+, Swift 6.x command line tools (no Xcode needed).

## Build & run

    swift build            # debug
    swift run Studio       # run unbundled (no camera/mic permission prompts)
    scripts/bundle.sh      # release build -> dist/7XEN Studio.app (ad-hoc signed)
    open "dist/7XEN Studio.app"

`bundle.sh` copies `mediamtx` and `ffmpeg` from `/opt/homebrew/bin` into `Contents/Resources` when present
(`brew install mediamtx ffmpeg`).

## Layout

- `Sources/Studio/Core` – store, device HTTP API, interfaces shared between modules
- `Sources/Studio/Ingest` – HTTP server, MediaMTX supervisor, phone frame sources
- `Sources/Studio/Engine` – Metal compositor (`StudioEngine`)
- `Sources/Studio/Output` – VideoToolbox/ffmpeg output pipeline
- `Sources/Studio/UI` – SwiftUI app. The UI only talks to `StudioServices` (`UI/Services.swift`);
  `MockServices` runs standalone, `RealServices` wires the real modules.

## Using it

- **Add a phone**: Add in the Phones panel, name it, scan the QR with the 7XEN Stream app (or type the pairing code).
- **Scenes**: `1`-`9` select a scene into Preview, `Space` (or TAKE) sends Preview to Program, double-click a scene to cut to it.
- **Go Live**: pick outputs (record / stream keys), press Go Live and confirm. The health strip shows fps, bitrate, dropped frames.
- Menu `Show` has all commands; `Settings` (Cmd+,) holds the studio name and stream keys.

## Team Status board (live esports overlay)

A first-class layer (`LayerKind.teamBoard`, `Core/TeamBoard.swift`, art in `Engine/TeamBoardArt.swift`), drawn after the
"AirBattleground Gold Esports Leaderboard" art: AB monogram | gold divider | AIRBATTLEGROUND wordmark (the built-in logo assets),
a slanted social strip (Instagram / YouTube / web + handle) that cross-fades with `{{matchTitle}}` every 5 s, a gold table head
`# | TEAM | FIN. | TOT. PTS. | STATUS` and one row per team (1-32): rank, logo, name, finishes, total points and 4 player bars
(gold alive, red knocked, grey eliminated). Rows keep the reference height (22 fill the art); fewer teams give a shorter, still
closed panel, more than 22 shrink the rows. A team with status 0 stays visible, greyed out. "Sort by points" (Inspector, off by
default) orders rows by TOT. PTS. then FIN. with # = position; otherwise rows follow `slot` and # = slot.
Add it from the scene editor library (Props or Sources → "Team Status Board") or New scene → "Team status board".
The board is rasterised off the render thread only when its data changes (cross-faded on air); the carousel blends two cached sprites.

Data sources (Inspector → Team status board):

- **AirBattleground match** (default): the match picked in the app, over the existing Studio Link (host + `X-Studio-Key`),
  polled every 3 s with `If-None-Match`. Read-only: team status is maintained by the match manager on AirBattleground's Match Center.
  On errors the last good data stays; a small orange dot shows after 15 s without a good answer.
- **Manual**: team names, FIN., PTS. and status (0-4) edited in the Inspector, saved with the scene.
- **Custom JSON URL**: any URL + interval + optional header (`Name: value`) + field mapping (dot paths).
- **Mock**: 1-32 sample teams whose statuses change every few seconds.

Expected JSON (`GET <host>/api/studio-link/matches/{matchId}/live` - TODO: not live on AirBattleground yet):

    { "version": 42, "updatedAt": "2026-10-23T18:00:00Z",
      "match": { "id": "m1", "title": "Grand Finals - Match 3", "state": "scheduled|live|finished", "map": "Erangel" },
      "teams": [ { "id": "t1", "slot": 1, "name": "Team Alpha", "logo": "https://…/alpha.png", "status": 3,
                   "kills": 7, "totalPoints": 19,
                   "players": [ { "name": "P1", "state": "alive" }, { "state": "knocked" }, { "state": "eliminated" }, { "state": "alive" } ] } ],
      "summary": { "teams": [ { "slot": 1, "name": "Team Alpha", "kills": 7, "totalPoints": 19 } ] } }

`version` doubles as the ETag (304 = unchanged). Rows are ordered by `slot`; `status` = players alive (0 = eliminated row);
without `players` the board draws `status` gold bars and the rest grey. FIN. = `teams[].kills` (alias `finishes`), TOT. PTS. =
`teams[].totalPoints` (alias `points`); when a team has neither, the `summary.teams` entry with the same `slot` (else `name`) is
used; unknown values show a subtle "-".

## Studio presets and the match journey

A **preset** is a named set of scenes (its own list and order) plus a match-journey mapping (stage → scene) and optional
default overlays (`Core/Presets.swift`, stored in `store.json` as `presets` / `activePresetId`). The **active preset** is what you
stream with: the Studio strip, ⌘1-9 and New Scene work within it. Pick it from the preset switcher at the top of the Studio page
(and the Scenes page); its menu creates (empty / duplicate), renames, deletes (never the last one), chooses scenes and order
("Choose scenes…"), stores default overlays and, for "OPUS Advanced Studio", reinstalls the built-in scenes. A scene can be in
several presets; right-click a scene card → Presets. Built in: **OPUS Studio Default** (on first launch every existing scene is
migrated into it and it becomes active) and **OPUS Advanced Studio** (its scenes from `Props/AdvancedStudio` are inserted once;
never re-seeded after you delete them).

**Deleting scenes**: trash icon on hover or right-click → "Delete scene…" (Studio strip and Scenes page), with confirmation. A scene
on Program can't simply be deleted: the dialog offers "Cut to black & delete". Deleting removes the scene from every preset;
"Remove from <preset>" only takes it out of the active preset.

**Match journey** (Studio page, under the transition bar): Match starts in → Gameplay → Match summary → Winner, each showing its
scene. Click = Preview, Shift-click or ▶ = take to Program, ▾ = choose the scene (or "Use current Preview scene"). With
**Auto-follow match** on, the studio follows the picked AirBattleground match and takes the stage's scene to Program (with the scene's
transition) after a 3-second "Switching to …" toast you can cancel. The state must hold for 2 s first (no flapping); a manual take
pauses auto-follow until the match state changes again.

Stage = `control.state` when the server sends it (`locked`/`ready` → starts in, `live` → gameplay, `ended` → summary,
`published` → winner; also taken from the match picker / start / stop answers), else `match.state`
(`scheduled` → starts in, `live` → gameplay, `summary` → summary, `finished` → winner).

### Match data (`Core/MatchData.swift`)

One shared poller of `GET <host>/api/studio-link/matches/{matchId}/live` (3 s, ETag / 304, last good data kept on errors) feeds the
Team Status board AND the scene variables below. The "Match data" chip (top right of the Studio page) shows the connection, the
match state and the last update; its **Simulate** menu (scheduled / live / summary / finished with `MatchKeys.sample` values)
rehearses the journey without a server. Expected additions to the JSON above (all optional):

    { "match": { "state": "scheduled|live|summary|finished", "startsAt": "2026-10-23T18:00:00Z",
                 "round": "Grand Finals", "matchNumber": 3, "liveAt": "2026-10-23T18:02:10Z" },
      "control": { "state": "locked|ready|live|ended|published", "unlocksAt": "2026-10-23T17:55:00Z" },
      "summary": { "teams": [ { "slot": 1, "name": "SOUL", "logo": "https://…", "kills": 12, "placement": 1,
                                "placementPoints": 15, "killPoints": 12, "totalPoints": 27 } ],
                   "mvp": { "name": "MORTAL", "team": "SOUL", "kills": 9, "damage": 1284, "photo": "https://…" } },
      "winner": { "slot": 1, "name": "SOUL", "logo": "https://…", "kills": 18, "totalPoints": 33,
                  "players": [ { "name": "MORTAL", "kills": 9, "damage": 1284 } ] } }

Scene variables (`{{key}}`, `MatchKeys` in `Core/MatchJourney.swift`): `matchTitle`, `map`, `round`, `matchNumber`, `startsAt`,
`matchState`, `countdown` (MM:SS to `control.unlocksAt` while locked, else to `match.startsAt`, recomputed every second; empty when
past), `elapsed` (since the match went live), `teamCount`, `aliveTeams` (teams with status > 0), `rank1Name` … `rank16Name` with
`…Logo`, `…Kills`, `…PlacePts`, `…Total` (summary.teams sorted by totalPoints, then kills), `mvpName`, `mvpTeam`, `mvpKills`,
`mvpDamage` (1,284), `mvpPhoto`, `winnerName`, `winnerLogo`, `winnerKills`, `winnerTotal`, `winnerPlayer1…4` (+ `Kills`, `Damage`).
Without `winner`, a finished match uses the top of the standings. Keys the server doesn't send are left to the scene's defaults.
