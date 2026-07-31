# Backlog

## Persistent Volumes & Claims

- [ ] **Find a consistent PV/PVC pattern** across `database` and `llm` charts — currently inconsistent:
  - `database/pv.yaml` always renders a `hostPath` PV with no `storageClassName` guard and no `persistentVolumeReclaimPolicy`
  - `llm/pv.yaml` guards with `{{- if eq .Values.llm.storageClassName "" }}` and sets `persistentVolumeReclaimPolicy: Retain`
  - `database/pvc.yaml` has no guard; `llm/pvc.yaml` has no guard either
  - Decision needed: apply the same `storageClassName` guard, `reclaimPolicy`, and naming convention to both charts

## Hetzner CSI Persistent Volumes (dev + prod)

- [ ] Create `hetzner-csi.yaml` and run one-time CSI driver install: `helm upgrade --install hcloud-csi hcloud/hcloud-csi -n kube-system --values hetzner-csi.yaml` (replace `fleet-1-secrets` with actual fleet secret name)
- [ ] Guard `helm/charts/database/templates/pv.yaml` hostPath PV with `{{- if eq .Values.database.storageClassName "" }}` (same pattern as llm chart)
- [ ] Set `storageClassName: hcloud-volumes` in `dev.yaml` (database + llm) and `prod.yaml` (database)
- [ ] Add `nodeSelector` templating to database and llm deployments; set `cfke.io/provider: hetzner` in dev/prod values, leave empty in local

## Helm Namespace Creation

- [ ] **Fix namespace chart**: replace the kubectl workaround in CI/CD (`Deploy namespace` step) with a proper Helmfile-managed release. Idea: use `incubator/raw` (or `dysnix/raw`) to deploy the namespace as a raw manifest from `kube-system`, so Helm has a stable namespace to store release state in:
  ```yaml
  # helmfile.yaml
  releases:
    - name: my-namespace
      chart: incubator/raw
      namespace: kube-system
      values:
        - resources:
            - apiVersion: v1
              kind: Namespace
              metadata:
                name: my-app
                labels:
                  env: production
                  team: platform
  ```
  - [ ] **Step 1** — move `helm/charts/namespace/templates/namespace.yaml` into `helmfile.yaml` as an `incubator/raw` release (namespace `kube-system`); parameterise name and labels via environment values
  - [ ] **Step 2** — replace the kubectl `Deploy namespace` step in `cicd.yaml` with a `helmfile sync -l name=namespace` step using `helmfile/helmfile-action`
  - [ ] **Step 3** — delete the now-redundant `helm/charts/namespace/` chart directory

## Networking

- [ ] **Refactor per-app hostname config** — `gateway.hosts.domain` is duplicated in every app's values file (`helm/apps/frontend`, `helm/apps/iam`) instead of being derived from the shared `networking` gateway singleton, which already holds the real domain (`argocd/clusters/*/values/networking.enc.yaml`). Right now prod's `iam.enc.yaml` and staging's `iam.enc.yaml` still have `domain: ""`, which disables hostname-based routing (`hostnames`/`sectionName: https` are skipped in `helm/apps/*/templates/httproute.yaml`), so those HTTPRoutes match any Host header instead of only their intended one. Both envs' `frontend.enc.yaml` were fixed manually as a stopgap. Consider having app HTTPRoutes read the domain from one shared source instead of requiring every app+env combo to set it correctly.

## IAM

- [ ] **Check if subpath for IAM is necessary** — `KC_HTTP_RELATIVE_PATH=/iam` is set in `helm/charts/iam/templates/deployment.yaml`; verify whether the gateway routes require this subpath or if it can be removed to simplify the setup

- [x] **`iam` pod OOMKilled + provisioning Job failed on staging** — Keycloak's `start-dev` Quarkus augmentation is both CPU- and memory-hungry: under the old 200m CPU / 512Mi memory limits, the pod was OOMKilled mid-boot on one attempt and took ~268s to finish augmenting on the next; the `iam-provision` post-upgrade hook Job gave up after its 150s retry window (`BackoffLimitExceeded`) with the realm never seeded, so `/iam/realms/ai-system/...` 404'd. Also had no readiness probe, so the Service routed traffic (including the provisioning Job) to the pod before Keycloak was even listening on 8080. Fixed:
  - `helm/apps/iam/templates/deployment.yaml` — added `readinessProbe`/`livenessProbe` (`tcpSocket:8080`)
  - `helm/apps/iam/templates/provision-job.yaml` — retry window doubled 150s → 300s
  - `argocd/clusters/staging/values/iam.enc.yaml` — CPU 200m→500m, memory 512Mi→1Gi (via `sops`)

## LLM

- [ ] **`replicas: 0` still provisions a 20Gi PVC** on prod even though no pod runs — `helm/apps/llm/templates/pvc.yaml` (and the guarded `pv.yaml` on clusters without a real StorageClass) isn't gated on `replicas`; consider skipping the PV/PVC entirely when self-hosted inference is disabled, to avoid the idle storage cost.

## Worker

- [ ] **Add HTTP endpoint for `/chronsorting`** — `api`'s `WORKER_URL` env var points `POST /chronsorting` at the `worker` Service, but the worker image (per `kubernetes-ai-system`) only runs a Celery consumer process today, no HTTP server; the request will fail to connect until upstream adds one (see `kubernetes-ai-system` BACKLOG.md's "Deduplicate `routes.py`/`main.py` structure" item)
- [ ] **Split `worker` into its own source repo and wire up CI** — like `kubernetes-api` was split from `kubernetes-ai-system`; until then, `helm/apps/worker`'s `image.repository`/`tag` are empty on staging/prod and must be set by hand to deploy a real image
- [ ] **Supply a real `ANTHROPIC_API_KEY`** — `argocd/clusters/*/values/worker.enc.yaml`'s `secret.anthropicApiKey` is currently an empty SOPS-encrypted placeholder in every environment; the worker will fail to call Anthropic until a real key is set via `sops`

## Security

### Critical
- [ ] **Disable audience bypass** — `verify_aud: False` in `api/src/auth.py:29` means any Keycloak-issued token (for any client) is accepted; set the correct `audience` value and remove the override
- [ ] **Replace `admin-cli` + password grant** — `Login.tsx:21-22` uses the Keycloak admin client with the deprecated ROPC flow; create a dedicated app client in Keycloak and switch to Authorization Code + PKCE
- [ ] **Keycloak `start-dev` in production** — `helm/charts/iam/templates/deployment.yaml:20` runs `start-dev` in all envs; this disables TLS and uses an in-memory H2 DB (state lost on pod restart); switch to `start` with an external DB for prod

### High
- [ ] **JWKS cache TTL** — `api/src/auth.py:9` caches JWKS keys forever; add a TTL (e.g. 5 min) and retry on decode failure to handle Keycloak key rotation gracefully
- [ ] **Keycloak admin credentials in Helm values** — `helm/charts/iam/templates/deployment.yaml:29-31` injects the admin password from plain values (visible in `helm history`); move to a Kubernetes `Secret` and use `valueFrom.secretKeyRef`
- [ ] **Distinguish auth vs infra errors** — `api/src/auth.py:30` catches all exceptions and returns 401; a Keycloak outage should return 503, not 401

### Medium
- [ ] **Server-side MIME detection for uploads** — `api/src/routes.py:33` checks `file.content_type` from the client header, which is attacker-controlled; use `python-magic` to inspect actual file bytes
- [ ] **Paginate `/promises`** — `api/src/routes.py:24-27` returns the entire collection unbounded; add `limit`/`skip` parameters with a max page size to prevent memory exhaustion
- [ ] **CSP headers for token in sessionStorage** — the JWT is stored in `sessionStorage`, accessible to any JS on the page; add strict `Content-Security-Policy: script-src 'self'` headers at the gateway/ingress level

## Frontend Local Development

- [ ] **Fix `vite.config.ts` for local development** — the dev proxy for the IAM API subpath (`VITE_IAM_API_SUBPATH`) rewrites to the hardcoded `/iam` UI subpath; this should be driven by `VITE_IAM_UI_SUBPATH` so local dev mirrors the gateway rewrite without hardcoding

## Frontend Routing & Auth

- [ ] **Fix reload on subpath** — reloading on a subpath (e.g. `/chronsorting`) returns 404; the server needs to serve `index.html` for all non-asset routes so the SPA router can handle them (check Nginx config in `frontend/Containerfile` and HTTPRoute in `helm/charts/frontend/templates/httproute.yaml`)
- [ ] **Token timeout** — review and set appropriate token expiry in Keycloak (`tokenExpire` in environment values); align access token and refresh token lifetimes with session expectations
- [ ] **Redirect on token expiry** — when the token expires the user should be redirected to `/login` automatically; currently undefined behaviour (check `frontend/src/App.tsx` and API error handling)
- [ ] **Logging behaviour** — define what gets logged and at what level across services; ensure no tokens or sensitive data appear in logs
- [ ] **Modern CSS style** — refresh the frontend styling with a consistent, modern design system (review `frontend/src/global.css` and component styles)

## Clean Up

- [x] **iam-secrets `stringData` type errors** — `realms-ai-system.yaml`, `clients-chronsorting.yaml`, `clients-frontend.yaml`, `users-user1.yaml`, `users-user2.yaml` emitted raw booleans/lists into `Secret.stringData` (must be `map[string]string`), causing Argo CD sync to fail with `cannot unmarshal bool into Go struct field Secret.stringData of type string`; only `admin-credentials` (already quoted) applied. Fixed by quoting scalars and JSON-encoding lists.
- [x] **`iam-secrets` `VALUES_FILE` pointed at the wrong chart's values** — `iam-secrets-dev.yaml` reused `argocd/clusters/dev/values/iam.yaml` (overrides for the `iam` chart: image, gateway, hpa, etc.), which shares no keys with `iam-secrets/values.yaml`'s `secrets:` tree — a no-op copy-paste from `iam-dev.yaml`. Split into a dedicated `argocd/clusters/dev/values/iam-secrets.yaml` for plain (non-secret) overrides.
- [ ] **Stale `provision` key in `iam.yaml`** — `argocd/clusters/dev/values/iam.yaml` still sets `provision.enabled: true`, but `helm/apps/iam/templates/provision.yaml`/`provision-config.yaml` and the `iam/config/*` JSON files were deleted when the iam-secrets chart was split out (commit `e40bad1`); the key is now read by nothing — remove it or confirm a replacement provisioning path is still planned.

### Secrets Workflow (SOPS)

- [ ] **Document the SOPS secrets workflow** — how `helm/apps/iam-secrets` + `argocd/clusters/dev/values/iam-secrets.enc.yaml` fit together, for anyone rotating credentials or adding a new secret-backed chart:
  1. Non-secret chart defaults live in `helm/apps/<chart>/values.yaml`.
  2. Real secret values are only ever edited via `sops argocd/clusters/dev/values/<chart>.enc.yaml` (never hand-edited — `encrypted_regex: ^(username|password)$` in `.sops.yaml` controls what gets encrypted).
  3. Plain, non-secret per-cluster overrides (if any) go in a sibling plain file, e.g. `argocd/clusters/dev/values/iam-secrets.yaml` — never mix secret and non-secret overrides in the same file.
  4. The Argo CD Application for the chart uses `sources[].plugin.name: sops-helm` (not `sources[].helm`), with `CHART_PATH`/`VALUES_FILE`/`SECRETS_FILE` env vars — see `argocd/clusters/dev/iam-secrets-dev.yaml` and the plugin definition in `argocd/clusters/dev/values/argocd-cmp.yaml`.
  5. The decryption key (`sops-age-key` Secret) is created out-of-band per-cluster, never committed — see README.
  6. Every field the templates put in `stringData` must be a real string — quote booleans/numbers, JSON-encode lists/objects (see the fix above).
  - [ ] Add a "Secrets (SOPS)" section to `README.md` covering steps 1-6 above and the local `sops-age-key` setup.

## Ideas for implementation
- [ ] **Law support**
- [ ] 