# License review

- [Jellyfin](https://github.com/jellyfin/jellyfin) is licensed under GPL-2.0 (the repository's `LICENSE` file), which permits redistribution, including commercial distribution, provided the license and source availability are preserved. The template runs the official `jellyfin/jellyfin:12.4` image by digest without modifying Jellyfin; its source is published upstream.
- Jellyfin's [branding rules](https://jellyfin.org/docs/general/contributing/branding/) reserve the name for the project and its official clients and forbid implying affiliation. This template deploys unmodified Jellyfin, names it only to say what it deploys, states that it is a community template, and uses the project's icon only to identify that software in the listing.
- [dufs](https://github.com/sigoden/dufs) is dual-licensed under MIT and Apache-2.0. The template copies the unmodified binary from the official `sigoden/dufs:v0.47.0` image by digest.
- [Caddy](https://github.com/caddyserver/caddy) is licensed under Apache-2.0 and runs from the official image by digest.
- The wrapper files in this repository (Dockerfile, entrypoint, scripts, and documentation) add no license restrictions.
