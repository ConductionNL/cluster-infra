# Changelog

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
