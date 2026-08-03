---
last_reviewed: 2026-08-03
owner: info@conduction.nl
---

# Argo CD onder eigen beheer (zelfbeheer)

Argo CD beheert dit cluster — en sinds change `add-argocd-selfmanaged`
(techbook) ook **zichzelf**, vanaf `argocd/` in deze repo. Vóór die
change was Argo een handmatige upstream-install en waren RBAC, SSO en
het cluster-toegangsmechanisme onbeheerde clusterstate.

## Opzet

- `argocd/upstream/install-v3.4.6.yaml` — de kale upstream-manifests,
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

### Lopende reeks naar v3.4.6 (besluit 2026-08-03)

Van v3.0.6 naar v3.4.6, één minor per keer: de diff van het vendored bestand
ís hier de review, dus meerdere minors in één diff is niet te reviewen en bij
een probleem niet te bisecten. Elke stap is los terug te rollen via break-glass
vanaf de vorige commit.

Opgezet als vier stappen (v3.1.16 → v3.2.12 → v3.3.13 → v3.4.6), uitgevoerd
als **drie**: de 3.3-stap is overgeslagen. Reden hieronder.

**Stand van de reeks (2026-08-03):**

| Stap | Versie | Status |
|---|---|---|
| 1 | v3.1.16 | gesynct, groen — SSO werkte, en het cluster bleek van `public.ecr.aws` te kunnen pullen (daarvóór onbekend) |
| 2 | v3.2.12 | gesynct, groen — redis-major 7.2 → 8.2 zonder problemen |
| — | v3.3.x | **overgeslagen**, zie hieronder |
| 3 | v3.4.6 | staat klaar |

### Waarom 3.3 is overgeslagen

**v3.3.13 bevat een upstream-fout in de install-manifests:** de
`argocd-repo-server`-Deployment mount `argocd-cmd-params-cm` als volume, maar
declareert dat volume niet. `kubectl diff -k argocd` faalt daarop hard:

    The Deployment "argocd-repo-server" is invalid:
    spec.template.spec.containers[0].volumeMounts[8].name:
    Not found: "argocd-cmd-params-cm"

Uitgezocht per patchrelease: v3.3.0 t/m **v3.3.12 zijn goed**, alleen v3.3.13
is kapot; in v3.4.6 staat het volume er weer wél. Twee uitwegen waren mogelijk
— naar v3.3.12 als tussenstap, of direct door naar v3.4.6. Gekozen voor
**direct naar v3.4.6** (besluit Mark): v3.3.12 zou een wegwerp-tussenstap zijn
op een release waar we niet blijven.

Wat je daarmee opgeeft is de bisect-mogelijkheid — de 3.3- en 3.4-wijzigingen
landen nu in één sync. Dat weegt hier licht, omdat de twee risico's aan hun
symptoom te onderscheiden zijn: de ApplicationSet-CRD-wijziging kan geen
SSO-storing geven, en Dex kan geen CRD-fout geven. Gaat de gecombineerde sync
mis, dan is **v3.3.12 nog steeds de bruikbare tussenstap**.

Les voor volgende keer: controleer bij een vendored upstream-manifest niet
alleen of het rendert, maar of elke `volumeMount` een bijbehorend `volume`
heeft. Een `kubectl kustomize` slaagt namelijk wél op zo'n manifest — pas
`kubectl diff` of de apply loopt erop stuk.

Wat per stap is uitgezocht en niet opnieuw hoeft:

- **De eigen patches botsen niet.** `argocd-cm`, `argocd-rbac-cm` en
  `argocd-ssh-known-hosts-cm` zijn upstream identiek in álle betrokken
  releases (v3.0.6 t/m v3.4.6), dus de patches passen in elke stap schoon toe.
- **Dex bumpt in twee stappen.** 2.41.1 → 2.43.0 bij **v3.1.16**, en
  2.43.0 → 2.45.0 bij **v3.4.6**. Bij v3.2.12 verandert Dex niet. Omdat
  `admin.enabled: "false"` staat, betekent een kapotte Dex géén UI. **Verifieer
  de SSO-login dus na v3.1.16 én na v3.4.6** — niet alleen aan het eind.
- **Redis: eerst een andere registry, dan een major.** `redis:7.2.7-alpine`
  (Docker Hub) wordt `public.ecr.aws/docker/library/redis:7.2.11-alpine` bij
  **v3.1.16**, **`8.2.2-alpine` bij v3.2.12** en `8.2.3-alpine` bij **v3.4.6**.
  De major-sprong 7.2 → 8.2 zit dus bij v3.2.12, niet aan het eind zoals bij het
  plannen eerst werd aangenomen — de eerste inventarisatie miste dat doordat het
  registry-pad wijzigde en een grep op `redis:` daar niet meer op matchte. Les:
  bij een registry-verhuizing per release opnieuw uitlezen, niet één patroon
  over alle versies. Redis is hier puur cache, dus een herstart kost hoogstens
  een koude cache — geen dataverlies.
  De registry-verhuizing deed upstream om Docker Hub-rate-limits te ontlopen,
  gunstig voor deze anoniem pullende fleet. Bij v3.1.16 is bewezen dat het
  cluster van `public.ecr.aws` kan pullen; dat was daarvóór onbekend. Knelt het
  ooit, dan is de uitweg de bestaande regsync-mirror in
  `cluster-config/mirror/regsync.yaml` (die mirrort al
  `docker.io/library/redis`) — maar dat vergt een image-patch, en dat is een
  nieuw soort delta in `argocd/patches/`.
- **v3.2.12 verlaagt de RBAC van de applicationset-controller.** Netto weg:
  `deployments` get/list/watch (apps én extensions), `configmaps`
  create/delete/patch/update, en cluster-wijde `leases`
  delete/get/list/patch/update/watch. Erbij: alleen `leases` create/get/update
  **beperkt tot één resourceName** (`58ac56fa.applicationsets.argoproj.io`) voor
  leader-election. Een brede lease-permissie wordt dus vervangen door één
  benoemde lease — een verbetering, geen risico. De ruwe `kubectl diff` ziet er
  door herordening rommeliger uit dan de wijziging is.
- **De 3.3-grens eist ServerSideApply, en dat is hier hard aangetoond.** De
  `applicationsets.argoproj.io`-CRD is in v3.4.6 **373.903 bytes** — ruim boven
  de 262.144-byte-limiet van de last-applied-annotatie, dus client-side apply
  kán niet meer. `ServerSideApply=true` staat al in
  `argo/applications/argocd.yaml`, en de live CRD heeft alleen de field managers
  `argocd-controller` (Apply) en `kube-apiserver` (Update) — geen
  `kubectl-client-side-apply` en een last-applied-annotatie van 0 bytes. Die
  migratie is dus al schoon. Zet **niet** `ClientSideApplyMigration=false`.
- **3.3→3.4 clusterversie-formaat** (`vMajor.Minor.Patch`) raakt alleen
  ApplicationSets met *cluster*-generators plus `auto-label-cluster-info`. De
  fleet gebruikt **git**-generators, dus niet van toepassing.
- **Geen k8s-blokkade:** cluster draait v1.32.13; ArgoCD 3.1 t/m 3.4 zijn alle
  tegen 1.32 getest. 3.5 was op het moment van besluiten nog RC.

### Procedure per stap

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
