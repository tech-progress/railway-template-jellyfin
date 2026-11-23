import { defineRailway, github, group, project, service, volume } from "railway/iac";
import defaults from "../template-defaults.json" with { type: "json" };

const JELLYFIN_SOURCE = github("tech-progress/railway-template-jellyfin", { branch: "release-v1", rootDirectory: "/" });
const CADDY_IMAGE = "caddy:2.11.9-alpine@sha256:0bbb055bda6793c999bde78b1b5ce3e89f829fb031af2cf50056ea1246559fee";

// Same script as compose.yaml: validate the credential, hash it from stdin,
// drop the plaintext, render the pinned policy, wait until Jellyfin reports a
// completed startup wizard, and only then open the public port.
export const GATEWAY_START =
  `/bin/sh -ec 'case "$GATEWAY_USERNAME" in ""|*[!A-Za-z0-9._-]*) echo "GATEWAY_USERNAME must use letters, digits, dot, dash or underscore." >&2; exit 64;; esac; ` +
  `[ "$(printf "%s" "$GATEWAY_PASSWORD" | wc -c)" -ge 16 ] && [ "$(printf "%s" "$GATEWAY_PASSWORD" | wc -c)" -le 72 ] || { echo "GATEWAY_PASSWORD must have 16 to 72 bytes." >&2; exit 64; }; ` +
  `password_hash="$(printf "%s" "$GATEWAY_PASSWORD" | caddy hash-password)"; unset GATEWAY_PASSWORD; ` +
  `printf "%s\\n" "$GATEWAY_CONFIG" | sed -e "s|__USERNAME__|$GATEWAY_USERNAME|g" -e "s|__PASSWORD_HASH__|$password_hash|g" -e "s|__JELLYFIN__|$JELLYFIN_UPSTREAM|g" -e "s|__UPLOADS__|$UPLOAD_UPSTREAM|g" >/tmp/Caddyfile; ` +
  `unset GATEWAY_CONFIG; echo "Waiting for Jellyfin to complete its startup wizard."; ` +
  `until wget -Y off -q -T 5 -O - "http://$JELLYFIN_UPSTREAM/System/Info/Public" 2>/dev/null | grep -q "\\"StartupWizardCompleted\\":true"; do sleep 2; done; ` +
  `exec caddy run --config /tmp/Caddyfile --adapter caddyfile'`;

export default defineRailway((ctx) => {
  // Disposable source projects receive concrete passwords from the publisher
  // (JELLYFIN_SOURCE_GATEWAY_PASSWORD, JELLYFIN_SOURCE_ADMIN_PASSWORD). The
  // marketplace draft is restored to the ${{secret(32)}} defaults in
  // template-defaults.json.
  const gatewayPassword = process.env.JELLYFIN_SOURCE_GATEWAY_PASSWORD ?? "";
  const adminPassword = process.env.JELLYFIN_SOURCE_ADMIN_PASSWORD ?? "";
  const data = volume("Jellyfin Data", { sizeMB: 5_000 });
  const jellyfin = service("Jellyfin", {
    source: JELLYFIN_SOURCE,
    build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile", watchPatterns: ["/Dockerfile", "/railway-entrypoint.sh"] },
    healthcheck: "/health",
    healthcheckTimeout: 600,
    volumeMounts: { "/data": data },
    env: { ...defaults.Jellyfin, JELLYFIN_ADMIN_PASSWORD: adminPassword },
  });
  const gateway = service("Jellyfin Gateway", {
    source: { image: CADDY_IMAGE },
    start: GATEWAY_START,
    healthcheck: "/healthz",
    healthcheckTimeout: 600,
    env: { ...defaults["Jellyfin Gateway"], GATEWAY_PASSWORD: gatewayPassword },
  });
  return project("jellyfin-media-server", { resources: [group("Media server", [gateway, jellyfin, data])] });
});
