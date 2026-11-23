# Deploy and Host Jellyfin on Railway

Jellyfin is a free software media server for your movies, shows and music. This template runs Jellyfin 12.4 privately, completes its setup wizard with a generated administrator before anyone can reach it, and adds a password-protected browser upload manager for your media. It is a community template, not an official Jellyfin project release.

## About Hosting Jellyfin

Jellyfin reads media from folders on disk and has no built-in upload, so this template adds [dufs](https://github.com/sigoden/dufs) at `/files/` to upload into the same volume Jellyfin scans. One 5 GB volume at `/data` holds Jellyfin's database and settings, its cache, and the Movies, Shows and Music libraries, so accounts, watch history and files survive restarts and redeploys. Resize the volume as your library grows.

On first boot the Jellyfin container runs the setup wizard itself while Jellyfin listens only on loopback, creates the administrator from `JELLYFIN_ADMIN_USERNAME` and the generated `JELLYFIN_ADMIN_PASSWORD`, and adds the three libraries. The Caddy gateway is the only public service and opens only after the wizard is complete. It asks for its own generated password (`GATEWAY_USERNAME` and `GATEWAY_PASSWORD` on the `Jellyfin Gateway` service) before the upload manager; everything else uses Jellyfin's login, so the web player and the phone and TV apps work normally.

After deploying: sign in with the administrator credentials from the `Jellyfin` service, upload media at `/files/` (one folder per film, for example `movies/Title (Year)/Title (Year).mp4`), then run Scan All Libraries in the dashboard.

Railway has no GPUs, so transcoding is software ffmpeg. Plan on about two vCPU per simultaneous 1080p transcode; direct play needs almost none. Streaming to viewers is billed as Railway egress.

## Why Deploy Jellyfin on Railway

- No first-visit takeover: the setup wizard is finished with a generated administrator before the public port opens.
- Upload movies, shows and music from a browser instead of copying files to a server.
- Pinned image digests for Jellyfin, dufs and Caddy, health checks, and a persistent volume.
- Transcode throttling and segment deletion are on, which limits CPU use and the space long transcodes take.

## Common Use Cases

- A private streaming server for your own films and home videos, for you and your family.
- Listening to your music collection from any browser or Jellyfin app.
- Sharing a small library with friends through their own Jellyfin accounts.

## Dependencies for Jellyfin Hosting

The template uses two services and one Railway volume. No database or external account is needed.

### Deployment Dependencies

- [Jellyfin](https://github.com/jellyfin/jellyfin) ([jellyfin.org](https://jellyfin.org)) provides the media server, users, players and transcoding.
- [dufs](https://github.com/sigoden/dufs) provides the browser upload manager for the media folders.
- [Caddy](https://caddyserver.com) provides the public gateway and Basic Auth on uploads.
- [Railway](https://railway.com) provides builds, private networking, HTTPS and the persistent volume.
