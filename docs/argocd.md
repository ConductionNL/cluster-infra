---
last_reviewed: 2026-07-10
owner: mark
---

# Argo CD onder eigen beheer (zelfbeheer)

Argo CD beheert dit cluster — en sinds change `add-argocd-selfmanaged`
(techbook) ook **zichzelf**, vanaf `argocd/` in deze repo. Vóór die
change was Argo een handmatige upstream-install en waren RBAC, SSO en
het cluster-toegangsmechanisme onbeheerde clusterstate.

## Opzet

- `argocd/upstream/install-v3.0.6.yaml` — de kale upstream-manifests,
  gepind en **vendored** (hermetisch: renderen vergt geen egress, en een
  upgrade is één vervangen bestand met reviewbare diff).
- `argocd/patches/` — het volledige eigen delta op upstream:
  `argocd-cm` (url, OIDC/Keycloak, admin uit, service-accounts),
  `argocd-rbac-cm` (autorisatie — wijzigingen hier zijn access-control,
  review verplicht), ssh-known-hosts.
- `argocd/resources/` — namespace, de ingress
  (admin.commonground.nu) en het **credential-refresh-mechanisme**: een
  CronJob die elke 12 uur via de Gardener-API verse 24-uurs-kubeconfigs
  ophaalt voor de shoot-clusters (con-prod, conductionprod, test-accept)
  en ze als `cluster-api.*`-secrets schrijft. Missiekritisch: valt dit
  stil, dan verliest Argo binnen 24 uur de toegang tot alles wat het
  beheert. (Alerting hierop: opvolgpunt in de monitoring-repo.)
- `argo/applications/argocd.yaml` — de Application die dit pad beheert.
  Bewust zonder automated/prune/selfHeal: elke wijziging aan Argo zelf
  is een handmatige, reviewde sync.

## Bootstrap-secrets (mens plaatst; nooit in git)

Er is geen externe secret-backend; deze secrets zijn de gedocumenteerde
uitzondering op "alles uit git" en worden bij bootstrap door een mens
aangemaakt:

| Secret | Inhoud | Gebruikt door |
|---|---|---|
| `argocd-oidc-keycloak` | key `clientSecret` (Keycloak-client `argocd`); label `app.kubernetes.io/part-of: argocd` verplicht | `argocd-cm` via `$argocd-oidc-keycloak:clientSecret` |
| `gardener-sa-kubeconfig` | Gardener-service-account-kubeconfig | credential-refresh-CronJob |
| `nextcloud-repo-key`, `react-base-repo` | repo-credentials | Argo repo-server |

`cluster-api.*`-secrets zijn runtime-artefacten van de CronJob en horen
níét in git of in deze lijst. `argocd-server-tls` komt van cert-manager.

## Adoptie (fase 3 — elke stap door een mens)

`scripts/argocd-adopt.sh` begeleidt deze fase: per stap (`stap1`…`stap4`,
plus `status`) met controles vóór en ná, bevestiging per mutatie, en een
harde stop zodra de diff méér bevat dan de drie gedocumenteerde
afwijkingen. Het OIDC-secret wordt in-cluster gekopieerd en komt nooit
in argv of terminal. De stappen, ook handmatig uitvoerbaar:

Voorwaarde vooraf: `kubectl diff -k argocd` toont uitsluitend de drie
bekende, ongevaarlijke afwijkingen (OIDC-regel in argocd-cm als
secret-verwijzing; expliciet subject-namespace op zes RoleBindings;
herstelde upstream-labels op argocd-rbac-cm). Volgorde:

1. Bootstrap-secret `argocd-oidc-keycloak` aanmaken (waarde = de huidige
   clientSecret uit argocd-cm; vergeet het part-of-label niet).
2. `kubectl apply -k argocd` — de bootstrap-apply. Verifieer daarna de
   SSO-login op admin.commonground.nu (rollback: kubectl edit van
   argocd-cm; Argo beheert zichzelf nog niet).
3. `kubectl diff -k argocd` is nu leeg. Apply
   `argo/applications/argocd.yaml`; de eerste handmatige sync is
   aantoonbaar een no-op.
4. Roteer de OIDC-clientSecret in Keycloak (de oude waarde was leesbaar
   voor iedereen met ConfigMap-read in de namespace) en werk het
   bootstrap-secret bij.
5. Observatieperiode; daarna expliciet besluit over selfHeal.

## Upgraden

1. Nieuwe upstream downloaden:
   `curl -sSfL -o argocd/upstream/install-vX.Y.Z.yaml https://raw.githubusercontent.com/argoproj/argo-cd/vX.Y.Z/manifests/install.yaml`
2. `kustomization.yaml` naar het nieuwe bestand wijzen, oude verwijderen.
3. PR: de diff van het vendored bestand ís de upgrade-review (lees ook
   de upstream release notes; patches blijven expliciet zichtbaar).
4. Na merge: handmatige sync van de Application `argocd`, daarna de UI
   en een steekproef-Application controleren.

## Break-glass

Als Argo CD zichzelf onbruikbaar maakt (mislukte upgrade, kapotte
config): repareer met kubectl vanaf een werkstation —
`kubectl apply -k argocd` vanaf de laatst goede commit (of gericht
`kubectl -n argocd edit`). De admin-login staat uit (`admin.enabled:
"false"`); herstel loopt dus via kubectl, niet via de UI. Na herstel:
de afwijking terugbrengen in de repo (of de repo-versie applyen) zodat
git weer leidend is, en het incident in de CHANGELOG.

## Verificatie

De pre-push gate (`scripts/verify.sh`) rendert `argocd/` en valideert
met kubeconform, en assert dat de Application en deze pagina met de
bootstrap-secrets bestaan.

```bash verify
test -f argo/applications/argocd.yaml
grep -q 'argocd-oidc-keycloak' docs/argocd.md
grep -q 'gardener-sa-kubeconfig' docs/argocd.md
```
