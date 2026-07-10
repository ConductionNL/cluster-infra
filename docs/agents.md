---
last_reviewed: 2026-07-10
owner: mark
---

# Agent-cataloog (referentie)

Guardrails voor agents in deze repo, per het handboek-formaat
(org → Werken met agents). **Niet in dit cataloog = eerst vragen.**
Alles hier is cluster-breed: de blast radius is per definitie maximaal.

## Operaties

| Operatie | Autonomie | Idempotentie | Verificatie |
|---|---|---|---|
| Component-values wijzigen (`<component>/values.yaml`) | autonoom bewerken | declaratief | `./scripts/verify.sh` (yaml + kubeconform + componenten-assertie); push mens |
| Nieuw component voorbereiden (dir + Application + sourceRepos-regel) | **voorstel-eerst** (toon de manifests, schrijf na akkoord — creatie-regel 2026-07-10) | declaratief; bestaat al → geen tweede | verify; bootstrap-apply is mens-vereist |
| Docs bijwerken (componentenoverzicht in de index!) | autonoom | tekstueel | docs-contract-gate + componenten-assertie |
| Versie-bumps (`targetRevision` van een chart) | mens-vereist | — | changelog van de upstream chart lezen; agent bereidt diff + samenvatting voor |
| Secrets (Cloudflare-token, age) aanmaken/roteren | mens-vereist | — | CLOUDFLARE.md-runbook; nooit door een agent |
| `argocd/`-manifests wijzigen (Argo's zelfbeheer, incl. rbac-cm!) | autonoom bewerken; rbac/SSO-wijzigingen **voorstel-eerst** | declaratief | verify (render + kubeconform + doc-assertie); sync mens-vereist, zie docs/argocd.md |
| `kubectl apply`/delete, Argo-syncs | mens-vereist | — | agent levert commando + verwachte uitkomst |
| Push | mens-vereist | — | gates draaien bij de mens |
| `txtOwnerId` van external-dns wijzigen | verboden | — | orphaned DNS-records voor alles (staat in CLAUDE.md) |

## Grondwaarheid en gedrag

- Handboek (MCP `conduction-docs`) boven modelkennis; `docs/index.md`
  hier is het componentenoverzicht — en wordt door de verify-assertie
  tegen de werkelijke mappen gehouden.
- GET-check-first: lees de bestaande Application/values vóór een edit.
