# cluster-infra

Cluster-wide infrastructure components for the Conduction Kubernetes
cluster, deployed via Argo CD. Separate from product platforms
(Nextcloud-base, react-base) because these components serve the entire
cluster, require cluster-wide RBAC, and upgrade on their own lifecycle.

Components: external-dns (Cloudflare), cert-manager config (Let's
Encrypt DNS-01 + wildcard cert), external-secrets, reflector,
fuse-device-plugin, seccomp-profiles, storage classes.

## Layout

- `argo/projects/cluster-infra.yaml` — the Argo CD AppProject
- `argo/applications/*.yaml` — one Application per component
- `<component>/` — Helm values or manifests per component

## Documentation

See [docs/index.md](docs/index.md) for the component overview and
operational pages (Cloudflare token management).

## Adding a component

1. Create a values/manifest directory (e.g. `cert-manager/`)
2. Add an Argo CD Application in `argo/applications/`
3. Allow the chart repo in `argo/projects/cluster-infra.yaml` → `sourceRepos`
4. Bootstrap once: `kubectl apply -f argo/applications/<component>.yaml`
5. Create required secrets manually in the target namespace
