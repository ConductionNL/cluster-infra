---
last_reviewed: 2026-07-10
owner: info@conduction.nl
---

# cluster-infra

Cluster-wide infrastructure for the Conduction Kubernetes cluster,
delivered via Argo CD (project `cluster-infra`). Intentionally separate
from product platforms (Nextcloud-base, react-base): these components
serve the whole cluster, need cluster-wide RBAC, and have their own
upgrade lifecycle.

## Components

| Component | What it does |
|---|---|
| `argocd` | Argo CD itself, self-managed from this repo (pinned upstream + explicit delta; see [argocd.md](argocd.md)) |
| `external-dns` | syncs Ingress and HTTPRoute hostnames to Cloudflare DNS (zones: commonground.nu, openwoo.app, opencatalogi.nl) |
| `cert-manager-config` | Let's Encrypt DNS-01 ClusterIssuer + wildcard certificate for openwoo.app |
| `external-secrets` | External Secrets Operator |
| `reflector` | mirrors Secrets/ConfigMaps across namespaces |
| `fuse-device-plugin` | advertises `squat.ai/fuse` and `squat.ai/tun` for rootless podman (used by the talos CI runners) |
| `seccomp-profiles` | installs `podman-rootless.json` on nodes (talos `con-ci-oci` dependency) |
| `storage` | StorageClass definitions |
| `gateway-api-crds` | vendored Gateway API + Envoy Gateway CRDs (never pruned; see [gateway-api.md](gateway-api.md)) |
| `envoy-gateway` | Gateway API control plane, running alongside ingress-nginx |
| `envoy-gateway-config` | the shared `GatewayClass`, `Gateway`, `EnvoyProxy`, PROXY-protocol policy and the HTTP→HTTPS redirect |

Each component is an Argo CD `Application` under `argo/applications/`;
the `AppProject` lives in `argo/projects/cluster-infra.yaml`.

## Pages

- [Argo CD onder eigen beheer](argocd.md) — zelfbeheer-opzet, bootstrap-
  secrets, adoptie, upgrade-procedure en break-glass (uitleg + how-to).
- [Gateway API naast ingress-nginx](gateway-api.md) — waarom, hoe de
  onderdelen samenhangen, bootstrap-volgorde en de canary-validatie
  (uitleg + how-to).
- [Cloudflare API token](CLOUDFLARE.md) — creating, loading and rotating
  the token external-dns uses (how-to).
