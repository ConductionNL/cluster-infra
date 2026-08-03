# Changelog

## 2026-08-03 — Argo CD v3.1.16 → v3.2.12 (stap 2 van 4)

Stap 1 is gesynct en groen: alle componenten op v3.1.16 en Ready, app
Synced/Healthy op `9b0811c`, SSO werkte, en `argocd-redis` pullde met succes van
`public.ecr.aws` — daarmee is de onbekende uit stap 1 (nieuwe registry) opgelost
bewijs geworden voor de rest van de reeks.

- `argocd/upstream/install-v3.2.12.yaml` vervangt `install-v3.1.16.yaml`;
  `argocd/kustomization.yaml` en `docs/argocd.md` wijzen mee.

### Wat deze stap in het cluster doet (vooraf doorgerekend)

`kubectl diff -k argocd`: **943 regels over 11 objecten** — 6 Deployments, 1
StatefulSet, 2 CRD's, 1 ClusterRole, 1 Role.

- Images: argocd `v3.1.16` → `v3.2.12`, redis `7.2.11-alpine` →
  **`8.2.2-alpine`**. **Dex blijft `v2.43.0`** — geen SSO-risico in deze stap.
- Alle overige workload-wijzigingen zijn nieuwe env-vars en één configMap-volume,
  allemaal naar `argocd-cmd-params-cm`. Die ConfigMap bestaat, wordt door upstream
  meegeleverd, en het volume staat op `optional: true` — dus geen risico dat een
  pod niet start.

### Correctie op de eerdere planning: Redis 8.x zit hier, niet in stap 4

Bij het plannen is gemeld dat Redis pas in stap 4 naar 8.x zou gaan. Dat was
fout: de major-sprong **7.2 → 8.2 gebeurt in deze stap**. De eerste
inventarisatie miste het doordat het registry-pad van `redis:` naar
`public.ecr.aws/docker/library/redis:` wijzigde en het grep-patroon daar niet op
matchte. `docs/argocd.md` is gecorrigeerd.

Praktisch gevolg is klein — Redis is hier puur cache, dus een herstart kost
hoogstens een koude cache en geen data. Maar het verschuift wél waar je op let.

### RBAC gaat omlaag, niet omhoog

De `applicationset-controller` levert rechten **in**:

- weg: `deployments` get/list/watch (`apps` én `extensions`), `configmaps`
  create/delete/patch/update, en cluster-wijde `leases`
  delete/get/list/patch/update/watch;
- erbij: alleen `leases` create/get/update, **beperkt tot één resourceName**
  (`58ac56fa.applicationsets.argoproj.io`) voor leader-election.

Een brede lease-permissie wordt dus vervangen door één benoemde lease. De ruwe
`kubectl diff` ziet er door herordening van de rules-lijst rommeliger uit dan de
wijziging werkelijk is; bovenstaande komt uit een genormaliseerde
voor/na-vergelijking van de live ClusterRole tegen de render.

### Verificatie

`scripts/verify.sh` groen (31 bestanden yaml-parse, kubeconform 13/13, 
doc-assertion OK). Het gevendorde bestand is byte-identiek aan de kopie waarmee
de voorbereiding is gedaan (sha256 `1097a8e8…`). Sync door een mens.

## 2026-08-03 — Argo CD v3.0.6 → v3.1.16 (stap 1 van 4)

Eerste stap van de reeks naar v3.4.6, één minor per keer (besluit Mark
2026-08-03): **v3.1.16 → v3.2.12 → v3.3.13 → v3.4.6**. Upstream adviseert dat,
en de diff van het vendored bestand ís hier de review — vier minors in één diff
is niet te reviewen en bij een probleem niet te bisecten.

- `argocd/upstream/install-v3.1.16.yaml` vervangt `install-v3.0.6.yaml`;
  `argocd/kustomization.yaml` en `docs/argocd.md` wijzen mee.
- `docs/argocd.md`: de lopende reeks en de per-stap-bevindingen vastgelegd, zodat
  stap 2-4 niet opnieuw hoeven te worden uitgezocht.

### Wat deze stap in het cluster doet (vooraf doorgerekend)

`kubectl diff -k argocd`: **720 regels over 16 objecten** — 3 CRD's, 6
Deployments, 1 StatefulSet, 6 NetworkPolicies.

- Images: argocd `v3.0.6` → `v3.1.16`, dex `v2.41.1` → **`v2.43.0`**, redis
  `redis:7.2.7-alpine` → **`public.ecr.aws/docker/library/redis:7.2.11-alpine`**.
- De NetworkPolicies krijgen **alleen labels**, geen regelwijzigingen — dus geen
  connectiviteitsrisico.
- Alle nieuwe env-vars verwijzen naar `argocd-cmd-params-cm` met
  `optional: true`. Die ConfigMap patchen wij niet, dus het zijn no-ops en de
  upstream-defaults blijven gelden.

### Twee aandachtspunten bij de sync

- **SSO verifiëren ná deze sync.** Dex gaat hier al van 2.41.1 naar 2.43.0 — niet
  pas in de laatste stap, zoals eerst gedacht. Met `admin.enabled: "false"`
  betekent kapotte Dex géén UI; herstel loopt via kubectl break-glass.
- **Nieuwe registry.** Dit cluster pulde nog nooit van `public.ecr.aws`
  (geverifieerd: alleen docker.io, registry.k8s.io, quay.io,
  europe-docker.pkg.dev, ghcr.io, codeberg.org). Beide benodigde tags zijn
  anoniem bereikbaar (HTTP 200) en geen admission-policy beperkt registries, dus
  het restrisico is een pull-fout — direct zichtbaar als `ImagePullBackOff`.
  Upstream deed deze verhuizing juist om Docker Hub-rate-limits te ontlopen, wat
  voor deze anoniem pullende fleet gunstig is.

### Verificatie

`scripts/verify.sh` groen (31 bestanden yaml-parse, kubeconform 13/13 valid,
doc-assertion OK). De eigen patches botsen niet: `argocd-cm`, `argocd-rbac-cm` en
`argocd-ssh-known-hosts-cm` zijn upstream identiek in alle vier de releases. Het
gevendorde bestand is byte-identiek aan de kopie waarmee de droogloop is gedaan
(sha256 `e2f69ec0…`), dus die analyse geldt letterlijk voor deze commit.

Sync door een mens, handmatig — de Application heeft bewust geen
automated/selfHeal.

## 2026-07-13 — eigenaarschap → info@conduction.nl (review WP8)
- Alle `owner:`-front-matter en CODEOWNERS omgezet van `mark` naar
  `info@conduction.nl` (opvolging na 2026-08-31). Voorbereid op branch
  `chore/wp8-ownership`; review, merge en push door een mens.

## 2026-07-10

- **feat: Argo CD onder eigen beheer (`argocd/`)** — change `add-argocd-selfmanaged`
  (techbook). Argo CD v3.0.6 draaide als handmatige upstream-install; RBAC, SSO-config,
  ingress en de credential-refresh-CronJob (verse 24u-kubeconfigs voor de 3
  shoot-clusters via Gardener) waren onbeheerde clusterstate. Nu: vendored gepinde
  upstream + expliciet delta (kustomize), Application `argo/applications/argocd.yaml`
  (handmatige sync, geen prune/selfHeal, geen finalizer), docs/argocd.md (bootstrap-
  secrets, adoptievolgorde, upgrade-procedure, break-glass) en verify-uitbreiding
  (render + kubeconform + docs-claim). `kubectl diff -k argocd` toont uitsluitend de
  drie gedocumenteerde, ongevaarlijke afwijkingen die de bootstrap-apply (fase 3, mens)
  wegneemt. Security-finding onderweg: het Keycloak OIDC-clientSecret stond inline in
  argocd-cm — in git vervangen door een `$argocd-oidc-keycloak:clientSecret`-verwijzing;
  rotatie na adoptie (stap 4 in docs/argocd.md). Het cluster is niet aangeraakt.

- **feat: fuse-device-plugin also advertises `squat.ai/tun`** (`/dev/net/tun`, count 20,
  same pools). Needed by the con-ci-oci runner: rootless podman ≥5 sets up per-workflow job
  networks with **pasta**, which creates a tap device and fails without `/dev/net/tun`
  ("Failed to open() /dev/net/tun" on the first real `container:` job, 2026-07-04). Same
  design as fuse: device-plugin injection so consumers stay unprivileged — no hostPath, no
  extra caps. Consumer change (requesting `squat.ai/tun: 1`) lands in the `talos` repo.

## 2026-07-01

- **feat: podman-rootless Localhost seccomp profile installer** — new `seccomp-profiles`
  Argo app.
  - `seccomp-profiles/podman-rootless.json` — podman's own default seccomp profile
    (containers/common), which permits `clone`/`clone3`/`unshare`/`setns` unconditionally
    (the containerd RuntimeDefault profile gates those behind CAP_SYS_ADMIN).
  - `seccomp-profiles/installer-daemonset.yaml` — DaemonSet (kube-system, pool
    `worker-0b1p9-1`) that copies the profile to `/var/lib/kubelet/seccomp/podman-rootless.json`
    on each node and stays running (re-places on node roll). Runs as root only to write the
    root-owned hostPath; **not** privileged. Delivered via kustomize configMapGenerator
    (content-hashed name → editing the profile rolls the installer).
  - `argo/applications/seccomp-profiles.yaml` — new Application (auto-detects kustomize),
    syncs to `kube-system`.
  - Lets talos `con-ci-oci` (rootless podman) create user namespaces under baseline
    PodSecurity (which forbids seccomp `Unconfined` but allows `Localhost`).
  - **Bootstrap (one-time):** `kubectl apply -f argo/applications/seccomp-profiles.yaml`.

- **feat: fuse device-plugin (extended resource `squat.ai/fuse`)** — new `fuse-device-plugin`
  Argo app.
  - `fuse-device-plugin/daemonset.yaml` — squat/generic-device-plugin DaemonSet in
    `kube-system`, fuse-only (`--domain=squat.ai --device …/dev/fuse…`, count 20). Runs
    **privileged** with host `/dev` to enumerate devices + register with kubelet; consumer
    pods stay unprivileged. Image pinned by index digest
    (`ghcr.io/squat/generic-device-plugin@sha256:dc192e16…`, tag `latest` @ 2026-07-01).
  - **Scoped to node-pool `worker.gardener.cloud/pool: worker-0b1p9-1`** (where con-ci runs)
    to keep the privileged /dev DaemonSet off the nextcloud/data pools.
  - `argo/applications/fuse-device-plugin.yaml` — new Application, syncs to `kube-system`.
  - Unblocks talos `con-ci-oci` (overlay + fuse-overlayfs instead of vfs) and `runner-build`
    (rootless buildah), which both request `squat.ai/fuse: "1"`.
  - **No AppProject change:** `kube-system` destination already whitelisted (storage uses it);
    a DaemonSet is namespaced, so no clusterResourceWhitelist entry needed.
  - **Bootstrap (one-time):** `kubectl apply -f argo/applications/fuse-device-plugin.yaml`,
    then ArgoCD auto-syncs.

## 2026-06-30

- **feat: DNS-01 wildcard cert for openwoo.app + reflector** (cert-manager-config + reflector Argo apps).
  - `cert-manager/clusterissuer-letsencrypt-dns.yaml` — new `letsencrypt-dns` ClusterIssuer
    using the **DNS-01 Cloudflare solver** (HTTP-01 can't issue wildcards). Reuses the
    existing Cloudflare token (`cloudflare-credentials/api-token`, Zone:DNS:Edit on
    openwoo.app) — but cert-manager reads DNS-01 secrets from its OWN namespace, so the
    secret must be bootstrapped into `cert-manager` (see Bootstrap below). Same ACME
    account email as `letsencrypt-prod` (robert@conduction.nl).
  - `cert-manager/wildcard-openwoo-certificate.yaml` — ONE wildcard `Certificate`
    (`*.openwoo.app` + `*.accept.openwoo.app`) → Secret `wildcard-openwoo-tls`. Replaces
    per-tenant HTTP-01 issuance for WOO frontends and removes the 50-certs/week/registered-
    domain pressure entirely. `secretTemplate` annotations tell reflector to replicate it.
  - `reflector/` + `argo/applications/reflector.yaml` — emberstack/reflector replicates the
    wildcard Secret into WOO tenant namespaces (regex `.*-(accept|prod|test|demo)`), so each
    frontend Ingress can reference one shared cert. **Chart version `7.1.288` is a placeholder
    — VERIFY against the chart repo before first sync.**
  - **AppProject widened** (`argo/projects/cluster-infra.yaml`): + sourceRepo
    `https://emberstack.github.io/helm-charts`, + destination ns `reflector`,
    + clusterResourceWhitelist `cert-manager.io/ClusterIssuer`.
  - **Caveat:** the Cloudflare token needs **Zone:Read** in addition to DNS:Edit (DNS-01 does
    a zone lookup) — verify the token scope.
  - **Bootstrap (one-time, manual):** create `cloudflare-credentials` in the `cert-manager`
    namespace (same token external-dns uses), then `kubectl apply` the AppProject + the
    reflector and cert-manager-config Applications.

## 2026-06-22

- **feat: install External Secrets Operator** (`argo/applications/external-secrets.yaml` + `external-secrets/values.yaml`).
  - Cluster-wide ESO controller + CRDs via the `external-secrets/external-secrets` Helm chart, same pattern as `external-dns` (upstream chart + this repo's values, `installCRDs: true`, `ServerSideApply=true` for the large CRDs).
  - Rationale: ESO is a cluster capability (like cert-manager / external-dns), not an app-platform concern — consumers (`ClusterSecretStore` / `ExternalSecret`) live in the platform repos (e.g. Nextcloud-base `platform/externalsecrets/`).
  - Chart `targetRevision` pinned to **`2.6.0`** (== appVersion `v2.6.0`; verified 2026-06-22
    against the chart index at `charts.external-secrets.io`). The earlier `0.10.5` pin was
    stale. **Breaking:** the 2.x major dropped the served `external-secrets.io/v1beta1` API
    (only `v1` is served now) — Nextcloud-base consumers were moved to `external-secrets.io/v1`
    in the same window. `generators.external-secrets.io/v1alpha1` (ClusterGenerator) unchanged.
  - **AppProject `cluster-infra` widened** (`argo/projects/cluster-infra.yaml`) so the app can
    sync: added sourceRepo `https://charts.external-secrets.io`, destination namespace
    `external-secrets`, and cluster resources `Validating`/`MutatingWebhookConfiguration`
    (the chart's webhook). Without this the app fails `InvalidSpecError` (repo/destination
    not permitted) and installs nothing.
  - Deploy in the platform sync window; Nextcloud-base's ESO consumers depend on these CRDs being present first.

## 2026-06-03

- **chore: migrate Argo source GitHub → Codeberg**
  - GitHub org `ConductionNL` is shadowbanned; cluster access broken (`external-dns`, `storage` apps `SYNC=Unknown`).
  - `repoURL` `https://github.com/ConductionNL/cluster-infra.git` → `https://codeberg.org/Conduction/cluster-infra.git` in `argo/projects/cluster-infra.yaml`, `argo/applications/external-dns.yaml`, `argo/applications/storage.yaml`.
  - Public HTTPS, no credentials needed. Repo mirrored to Codeberg; GitHub kept for rollback.

## 2026-04-15

- **feat: add openwoo.app and opencatalogi.nl to External DNS domain filters**
  - `external-dns/values.yaml`: added both domains to `domainFilters`
  - `docs/CLOUDFLARE.md`: updated token instructions to cover all three zones
  - `CLAUDE.md`: updated domain filter documentation
  - Cloudflare API token replaced with a combined token covering all three zones
  - Secret `cloudflare-credentials` in namespace `external-dns` updated on cluster
