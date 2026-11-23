# Jellyfin media server on Railway

The current template release is `v1.0.0`. It runs [Jellyfin](https://github.com/jellyfin/jellyfin) `12.4` ([jellyfin.org](https://jellyfin.org)) with the [dufs](https://github.com/sigoden/dufs) `0.47.0` upload manager behind a [Caddy](https://caddyserver.com) `2.11.9` gateway, all pinned by image digest. This is a community template; it is not made or endorsed by the Jellyfin project.

Jellyfin is a free software media server for movies, shows and music, with a web player, apps for phones and TVs, multiple users, and on-the-fly transcoding. It reads media from folders on disk and has no upload feature of its own, so this template adds a browser upload manager that writes into the same Railway volume Jellyfin scans.

## Topology

| Service | Public | Source | Purpose |
| --- | --- | --- | --- |
| `Jellyfin Gateway` | yes, port 8080 | `caddy:2.11.9-alpine` by digest | Only public entry. Requires the generated gateway password for the upload manager (`/files/`); every other request goes to Jellyfin, which uses its own login. Waits until Jellyfin reports a completed startup wizard before it opens its port. |
| `Jellyfin` | no | this repository, `release-v1` branch, `Dockerfile` | Official `jellyfin/jellyfin:12.4` image by digest plus the dufs binary. Jellyfin listens on 8096 and dufs on 5001, both reachable only over Railway private networking. |

One 5 GB volume is mounted at `/data` on the Jellyfin service:

- `/data/jellyfin` holds Jellyfin's database, settings, users, metadata, plugins and logs.
- `/data/cache` holds the image cache and transcode segments.
- `/data/media/movies`, `/data/media/shows` and `/data/media/music` are the three libraries. Everything you upload at `/files/` lands under `/data/media`.

### No open setup wizard

A fresh Jellyfin lets whoever opens it first run the setup wizard and create the administrator. In this template the Jellyfin container runs the wizard itself on first boot, while Jellyfin listens only on `127.0.0.1:18096` inside the container. It creates the administrator `JELLYFIN_ADMIN_USERNAME` with the generated `JELLYFIN_ADMIN_PASSWORD`, adds the Movies, Shows and Music libraries, turns on transcode throttling and segment deletion, and marks the wizard complete. Only then does Jellyfin listen on port 8096, and the gateway opens only after Jellyfin reports the completed wizard. After that, Jellyfin's setup API requires an administrator login. If the container stops partway through, a marker on the volume makes the next boot resume the same steps on loopback, signed in as the generated administrator, before port 8096 opens.

## Deploy on Railway

1. Deploy the template. Nothing needs to be filled in: Railway generates `JELLYFIN_ADMIN_PASSWORD` and `GATEWAY_PASSWORD`.
2. Copy `JELLYFIN_ADMIN_USERNAME` (default `admin`) and `JELLYFIN_ADMIN_PASSWORD` from the `Jellyfin` service variables. Open the gateway's domain and sign in to Jellyfin with them. Change the password under your profile if you like; the variable is only read on first boot.
3. Copy `GATEWAY_USERNAME` (default `media-admin`) and `GATEWAY_PASSWORD` from the `Jellyfin Gateway` service variables, open `https://<your-domain>/files/`, and sign in with them.
4. Upload media into the matching folder, one folder per film or show, for example `movies/Big Buck Bunny (2008)/Big Buck Bunny (2008).mp4` or `shows/Series Name/Season 01/Series Name S01E01.mkv`. See Jellyfin's [naming guide](https://jellyfin.org/docs/general/server/media/movies).
5. In Jellyfin, open Dashboard, Libraries and choose Scan All Libraries (real-time monitoring may also pick up new files). The upload appears in its library once the scan finishes.

Jellyfin apps for phones, TVs and desktops connect to `https://<your-domain>` with the same Jellyfin accounts.

## Environment variables

`Jellyfin`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8096` | Jellyfin listener used by Railway health checks (`/health`). Must stay 8096. |
| `UPLOAD_PORT` | `5001` | Private dufs listener. |
| `JELLYFIN_ADMIN_USERNAME` | `admin` | Administrator created on first boot. Letters, digits, `.`, `-`, `_`, `@`. |
| `JELLYFIN_ADMIN_PASSWORD` | `${{secret(32)}}` | Generated first-boot administrator password, at least 16 characters. Removed from the environment before Jellyfin starts; editing it later has no effect. |

`Jellyfin Gateway`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Public gateway listener. |
| `GATEWAY_USERNAME` | `media-admin` | Username for `/files/`. Letters, digits, `.`, `-`, `_`. |
| `GATEWAY_PASSWORD` | `${{secret(32)}}` | Generated password for `/files/`. The gateway refuses to start unless it has 16 to 72 bytes. |
| `JELLYFIN_UPSTREAM` | `${{Jellyfin.RAILWAY_PRIVATE_DOMAIN}}:8096` | Private Jellyfin endpoint. |
| `UPLOAD_UPSTREAM` | `${{Jellyfin.RAILWAY_PRIVATE_DOMAIN}}:5001` | Private upload endpoint. |
| `GATEWAY_CONFIG` | pinned Caddyfile | Routing and authentication policy. Changing it changes the security boundary. |

No other values are required. Metadata providers, users, plugins and remote access settings are configured in Jellyfin's dashboard.

## Transcoding, CPU and memory

Railway has no GPUs, so every transcode is software ffmpeg on the Jellyfin service's CPUs. Direct play (the client supports the file's codecs and the bitrate fits) costs almost no CPU; transcoding is what needs resources.

- A 1080p to 720p H.264 transcode of a synthetic test clip ran at 1.5 times real time on one CPU and 3.6 times on two (`libx264 veryfast`, the same ffmpeg build). Real films are harder to encode than test patterns, so plan on about two vCPU per simultaneous 1080p transcode.
- 4K and HEVC sources, HDR tone mapping and burned-in subtitles cost several times more. Prefer direct play, or keep 1080p H.264 copies, for those.
- Jellyfin itself used 216 to 426 MB on Railway around the smoke test. Each ffmpeg transcode adds its own memory: a 1080p H.264 encode peaked at about 470 MB with eight encoder threads (ffmpeg's choice for the 8 vCPU Railway shows) and about 300 MB with two. Library scans of large collections use extra CPU and memory while they run.
- The image sets `DOTNET_gcServer=0` (workstation garbage collection) so the .NET runtime does not size its heap to the 8 vCPU and 8 GB Railway shows every container.
- The first boot turns on transcode throttling (ffmpeg pauses once the player has enough buffer) and segment deletion (Jellyfin removes already-played segments of long HLS transcodes). Transcodes still write temporary segments to `/data/cache/transcodes`, so leave free space on the volume.

To cap cost, set Railway's CPU and memory limits on the `Jellyfin` service, and in Jellyfin's Dashboard, Playback, Transcoding set a thread count and in each user's settings a maximum streaming bitrate. Every byte streamed to viewers is Railway egress, which is billed by the GB, and direct-play streams of large files add up quickly.

## Persistence and limits

The `/data` volume holds the database, settings and your media, so restarts and redeploys keep accounts, watch history, libraries and files. Railway attaches one volume per service, which is why everything shares it. Video files are large: resize the volume in Railway before it fills (plan limits apply).

Uploads go through Railway's HTTP edge in one request each, so very large files can take long enough to be cut off on slow connections; split big collections into several uploads. The upload manager can also delete files under `/data/media`; anyone with the gateway password can manage the library.

This is a single-instance deployment for individuals, families and small groups, not a high-availability setup. UDP features (DLNA and local network discovery) do not work on Railway; apps connect by URL instead. Back up the whole volume before upgrades.

Jellyfin sees each visitor's real address: the gateway passes the address Railway's edge reports, and Jellyfin trusts forwarded headers only from Railway's private ranges. A service you add to the same Railway project could forge that address.

## Local verification

```bash
bun install --frozen-lockfile
./scripts/verify.sh
./scripts/local-check.sh
```

`local-check.sh` generates passwords into a private file, builds the image without cache, starts Compose from an empty volume, proves the wizard ran on loopback before Jellyfin listened on the network, runs `SMOKE_PHASE=initial ./scripts/smoke.sh`, restarts and recreates Jellyfin and restarts the gateway with `SMOKE_PHASE=restart` after each, injects a crash after the wizard completed and requires the next boot to resume provisioning, checks that the gateway's error log redacts tokens, scans logs, stored files and process environments (the wrapper's PID 1 included) for the passwords, runs `scripts/interrupted-boot-check.sh` (an administrator created, then the container killed before provisioning finished), and removes everything it created. Without a Docker daemon it starts a private podman API socket for the run.

The smoke test checks that the wizard is closed and Jellyfin's private APIs refuse anonymous calls, that `/files/` refuses anonymous and wrong-password requests, signs in with the generated administrator, uploads a short video through `/files/`, runs a library scan until the video appears as a movie, compares direct play byte for byte with the upload, and transcodes it to 320-pixel H.264. Set `BASE_URL`, `GATEWAY_PASSWORD` and `JELLYFIN_ADMIN_PASSWORD` to run it against a Railway deployment; over HTTPS it also requires that Jellyfin sees the visitor's public address. It needs `curl`, `jq`, `ffmpeg` and `ffprobe`.

## Source and forks

The Railway template builds the `Jellyfin` service from `tech-progress/railway-template-jellyfin` on the `release-v1` branch with root directory `/`. To run your own fork, change the repository in `.railway/railway.ts`, create a `release-v1` branch, and authorize Railway's GitHub App for it.

## Upstream projects

- [Jellyfin](https://github.com/jellyfin/jellyfin) and its [documentation](https://jellyfin.org/docs/), GPL-2.0.
- [dufs](https://github.com/sigoden/dufs), MIT or Apache-2.0.
- [Caddy](https://github.com/caddyserver/caddy), Apache-2.0.

The Jellyfin name and logo belong to the Jellyfin project and are used here only to say what this template deploys.
