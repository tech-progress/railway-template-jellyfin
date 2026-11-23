# Publishing

The current template release is `v1.0.0`. The `Jellyfin` service builds `tech-progress/railway-template-jellyfin` from `release-v1` with root directory `/`; the gateway runs the pinned Caddy image.

1. `bun install --frozen-lockfile` and `./scripts/verify.sh`.
2. Clean local build and smoke: `./scripts/local-check.sh`.
3. Sync the public distribution repository (everything except `FINDINGS.md` and `node_modules`), run `./scripts/check-standalone.sh <checkout>`, tag `v<version>`, and fast-forward `release-v1`.
4. Create a project named `jellyfin-media-server`, link it, and run `JELLYFIN_SOURCE_GATEWAY_PASSWORD=<fresh random value> JELLYFIN_SOURCE_ADMIN_PASSWORD=<fresh random value> railway config apply --yes`. Do not attach a domain to the source project.
5. `railway templates create --project <PROJECT_ID> --environment <ENVIRONMENT_ID> --json` (switch the Jellyfin service to the upstream image as a seed if the generator rejects the repository source), then `./scripts/restore-template-draft.sh <TEMPLATE_ID> <WORKSPACE_ID>` and `./scripts/audit-template.sh <TEMPLATE_ID>`.
6. Deploy the stored `serializedConfig` with `templateDeployV2` into a disposable project. Read `GATEWAY_PASSWORD` and `JELLYFIN_ADMIN_PASSWORD` from the deployed services into a 0600 file, then run both smoke phases with `BASE_URL=https://<gateway domain>` around a Jellyfin redeploy. Check replicas, metrics, and that no credential appears in the logs.
7. Publish:

```bash
railway templates publish <TEMPLATE_ID> \
  --category Other \
  --description "Jellyfin media server with browser uploads and no open setup wizard" \
  --readme-file MARKETPLACE.md \
  --json
```

8. `./scripts/audit-template.sh <TEMPLATE_ID> PUBLISHED`, then from the repository root `scripts/sync-template-marketplace.sh jellyfin-media-server` and `scripts/audit-template-marketplace.sh jellyfin-media-server`.
9. Stop and delete the source and verification projects, prove zero running instances, and tag `jellyfin-media-server-v<version>` in the monorepo.
