# Changelog

## 2026-04-15

- **feat: add openwoo.app and opencatalogi.nl to External DNS domain filters**
  - `external-dns/values.yaml`: added both domains to `domainFilters`
  - `docs/CLOUDFLARE.md`: updated token instructions to cover all three zones
  - `CLAUDE.md`: updated domain filter documentation
  - Cloudflare API token replaced with a combined token covering all three zones
  - Secret `cloudflare-credentials` in namespace `external-dns` updated on cluster
