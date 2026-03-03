# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo manages **cluster-wide infrastructure components** for the Conduction Kubernetes cluster, deployed via Argo CD. It is intentionally separate from product-specific platforms (e.g., `Nextcloud-base`) because these components serve the entire cluster, require cluster-wide RBAC, and have their own upgrade lifecycle.

Current components:
- **External DNS** — syncs Ingress hostnames to Cloudflare DNS automatically

Planned (not yet migrated from Helm):
- cert-manager
- ingress-nginx
- Argo CD itself

## Deployment Windows

**Everything in this repo is a platform change.** There are no tenant-only exceptions.

| Window | Allowed? |
|--------|----------|
| Mon–Thu 17:00–07:00 UTC | ✅ |
| Mon–Fri 07:00–17:00 UTC | ❌ Office hours |
| Friday 17:00+ | ❌ |
| Saturday / Sunday | ❌ |

Exception: mwest2020 can explicitly approve an out-of-window deployment.

## Repository Structure

```
argo/
  projects/cluster-infra.yaml     # AppProject (RBAC, sync windows, allowed repos)
  applications/external-dns.yaml  # Argo CD Application for External DNS
external-dns/
  values.yaml                     # Helm values for External DNS + Cloudflare
```

## Documentation

- `docs/CLOUDFLARE.md` — how to create the Cloudflare API token and load it into the cluster

## Bootstrap (one-time, manual)

Since Argo CD is managed via Helm (not GitOps yet), new components require a one-time manual bootstrap:

```bash
# 1. Create the AppProject
kubectl apply -f argo/projects/cluster-infra.yaml

# 2. Create the Cloudflare secret (DNS edit token for commonground.nu)
kubectl create namespace external-dns
kubectl create secret generic cloudflare-credentials \
  -n external-dns \
  --from-literal=api-token=<CF_API_TOKEN>

# 3. Register the Application with Argo CD
kubectl apply -f argo/applications/external-dns.yaml

# Argo CD will now sync and deploy External DNS automatically.
```

## Adding a New Component

1. Create a values file in a new directory (e.g., `cert-manager/values.yaml`)
2. Add an Argo CD Application in `argo/applications/`
3. Add the Helm chart repo to `argo/projects/cluster-infra.yaml` → `sourceRepos`
4. Bootstrap: `kubectl apply -f argo/applications/<component>.yaml`
5. Create any required secrets manually in the target namespace

## External DNS Behaviour

- Watches all Ingress resources cluster-wide
- Creates/updates/deletes Cloudflare DNS records automatically when Ingresses change
- Domain filter: `commonground.nu` — ignores all other zones
- Cloudflare proxy is **disabled** (DNS-only) — required for cert-manager HTTP-01 challenges
- `txtOwnerId: conduction-cluster` — **never change this** after first deploy, it will orphan existing DNS records
- Sync interval: 1 minute
- Records that External DNS created are deleted automatically when the Ingress is removed

## Upgrading External DNS

Update `targetRevision` in `argo/applications/external-dns.yaml`. Check the [External DNS changelog](https://github.com/kubernetes-sigs/external-dns/releases) before upgrading. Only do this within the allowed deployment windows.
