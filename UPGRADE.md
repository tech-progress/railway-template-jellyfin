# Upgrades

1. Back up the `/data` volume. `jellyfin/` holds the database and settings; `media/` holds your files.
2. Read the [Jellyfin release notes](https://github.com/jellyfin/jellyfin/releases) for migration notes.
3. Update the Jellyfin tag and digest together in `Dockerfile` (and the dufs pin if needed), bump `VERSION` and `CHANGELOG.md`.
4. Run `./scripts/verify.sh` and `./scripts/local-check.sh`, then run `SMOKE_PHASE=restart ./scripts/smoke.sh` against a copy of an existing volume to check the migration.
5. Tag the release, fast-forward `release-v1`, and let Railway rebuild the Jellyfin service.

Jellyfin migrates its database on start and cannot be downgraded in place; restore the volume backup to roll back. The first-boot setup only runs on an empty volume, so upgrades never touch the administrator or libraries.
