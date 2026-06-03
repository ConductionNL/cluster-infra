# Changelog

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
