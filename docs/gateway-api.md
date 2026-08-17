---
last_reviewed: 2026-08-17
owner: info@conduction.nl
---

# Gateway API naast ingress-nginx

## Waarom

`kubernetes/ingress-nginx` is op 2026-03-24 door upstream gearchiveerd. Er
komen geen CVE-patches meer, en de controller draait hier met
`allow-snippet-annotations: true` en `annotations-risk-level: Critical`. Dat
laatste is het eigenlijke probleem: elke namespace die een Ingress mag maken,
mag daarmee nginx-configuratie injecteren. Op een cluster met ~50
gemeentetenants is dat geen theoretisch risico.

Gateway API vervangt dat door een getypeerde API zonder vrije-tekstconfiguratie.
Deze opzet zet het ernáást — ingress-nginx blijft alle niet-gemigreerde tenants
bedienen. Migratie gaat per tenant, met de Ingress en de HTTPRoute tegelijk in
de lucht tot de eigenaar tekent.

De implementatie is **Envoy Gateway**, niet de Gateway API van de CNI: dit
cluster draait Calico, dat geen Gateway API-implementatie meelevert. Envoy
Gateway is CNI-onafhankelijk.

## Onderdelen

| Application | Wat |
|---|---|
| `gateway-api-crds` | 20 CRD's + safe-upgrade-policy, gevendord uit chart 1.8.3 |
| `envoy-gateway` | de controller (Helm, `crds.enabled=false`) |
| `envoy-gateway-config` | `GatewayClass eg`, `Gateway platform-gateway`, `EnvoyProxy`, `ClientTrafficPolicy` |
| `gateway-canary-routes` | tijdelijk: drie canary-HTTPRoutes, één HTTP→HTTPS-redirect en één ReferenceGrant |

De CRD's komen bewust niet uit de chart maar uit `gateway-api/crds/`. Herkomst,
sha256 en de bump-procedure staan in [`../gateway-api/README.md`](../gateway-api/README.md).

## Wat je moet weten voor je iets aanraakt

**PROXY-protocol is geen detail.** De OpenStack-loadbalancer stuurt een
PROXY-header. Zonder `ClientTrafficPolicy` sluit Envoy elke verbinding — niet
"trager", maar helemaal dicht. De annotaties op de Service en de policy horen bij
elkaar; wijzig ze nooit los van elkaar.

**Er is een tweede loadbalancer.** Envoy Gateway krijgt een eigen OpenStack-LB
met een eigen publiek IP, naast de `81.24.6.82` van nginx. Dat is opzet
(coëxistentie), maar het is een kostenpost en een firewallregel.

**Envoy's default route-timeout is 15 seconden.** nginx staat op 1800. Elke
HTTPRoute naar een Nextcloud heeft daarom expliciete `timeouts` nodig. Vergeet
je dat, dan breekt elke upload en elke trage sync — en pas onder belasting.

**`allowedRoutes.namespaces.from: All`** staat bewust wijd open. Het spiegelt de
huidige situatie onder nginx. Verscherpen is de eigenlijke winst van deze
migratie, maar hoort in een aparte change nadat het isolatiemodel vaststaat.

## Bootstrap (eenmalig, door een mens)

De volgorde is niet vrij. Elke stap moet `Synced Healthy` zijn voor de volgende:

    kubectl apply -f argo/applications/gateway-api-crds.yaml
    kubectl apply -f argo/applications/envoy-gateway.yaml
    kubectl apply -f argo/applications/envoy-gateway-config.yaml
    kubectl apply -f argo/applications/gateway-canary-routes.yaml

Status opvragen:

    kubectl get application -n argocd gateway-api-crds envoy-gateway \
      envoy-gateway-config gateway-canary-routes

    kubectl get gatewayclass eg
    kubectl get gateway -n envoy-gateway-system platform-gateway
    kubectl get svc -n envoy-gateway-system

Het externe IP van die laatste Service is het adres van het nieuwe dataplane.
Hierna heet dat `<envoy-ip>`.

## TLS

Geen wijziging aan cert-manager nodig voor de canary's:

- `*.accept.openwoo.app` gebruikt het bestaande wildcard. Reflector spiegelt het
  secret naar `envoy-gateway-system` (regex uitgebreid in
  `cert-manager/wildcard-openwoo-certificate.yaml`).
- `canary.accept.commonground.nu` gebruikt het bestaande per-host secret in
  `canary-accept`, gelezen via een `ReferenceGrant`.

Dat laatste heeft een consequentie: dat certificaat wordt via HTTP-01 over de
**nginx**-Ingress vernieuwd. Verhuist de DNS van die host naar Envoy, dan
breekt de vernieuwing. Daarom krijgt de Nextcloud-canary geen DNS-wijziging.
Voor een echte cutover moet eerst cert-manager's `--enable-gateway-api` aan —
die vlag staat nu uit.

## Canary valideren

De twee WOO-frontends krijgen wél een DNS-record (external-dns leest sinds deze
change ook HTTPRoutes):

    curl -sI https://canary.accept.openwoo.app/
    curl -sI https://almere.accept.openwoo.app/

De Nextcloud-canary heeft geen DNS; forceer de resolutie:

    H=canary.accept.commonground.nu
    curl -sI --resolve "$H:443:<envoy-ip>" "https://$H/status.php"
    curl -sI --resolve "$H:443:<envoy-ip>" "https://$H/.well-known/webfinger"
    curl -sI --resolve "$H:443:<envoy-ip>" "https://$H/.well-known/caldav"
    curl -sI --resolve "$H:443:<envoy-ip>" "https://$H/config/config.php"

Verwacht: `status.php` 200; webfinger en caldav een 301; `config/config.php`
een 404. Die laatste drie komen uit de nginx-sidecar in de pod, niet uit de
ingress — ze horen dus onveranderd te werken. Zie ook de opmerking hieronder.

Poort 80 hoort een 308 naar https te geven, net als nginx vandaag:

    curl -sI http://canary.accept.openwoo.app/

Verder handmatig: een upload boven de drempel, een request dat langer dan 15
seconden duurt (bewijst de timeout-vertaling), en de headers
`strict-transport-security` en `access-control-*` vergelijken met wat
`https://canary.accept.commonground.nu/status.php` via nginx teruggeeft.

## Wat NIET naar HTTPRoute vertaald hoeft

Een hardnekkig misverstand: de webfinger-, nodeinfo-, host-meta- en
CalDAV/CardDAV-omleidingen zouden op de Ingress staan. Dat is niet zo. Voor
GitOps-tenants zitten ze in de nginx-sidecar in de pod
(`Nextcloud-base/nextcloud-platform/values/common.yaml`, `nginx.config.default`)
en blijven ze onveranderd achter de HTTPRoute staan. Wat er in de controller-
ConfigMap staat is een cluster-brede kopie die diezelfde sidecar dubbelt.

Ook niet nodig: `proxy-body-size`. Envoy buffert requests niet by default, dus
er is geen limiet om op te heffen — maar meet het met een echte grote upload
voor je het gelooft.

## Terugdraaien

- Eén canary: het betreffende manifest uit `envoy-gateway/canary-routes/`
  halen. De Ingress heeft altijd doorgedraaid; backend-Services zijn gedeeld en
  onaangeroerd. Bij een frontend ook het DNS-record terug naar `81.24.6.82`.
- Alles: `gateway-canary-routes`, `envoy-gateway-config` en `envoy-gateway`
  verwijderen. `gateway-api-crds` staat op `prune: false` en gaat dus niet
  vanzelf mee — dat is opzet, want een CRD weghalen wist in één klap elk object
  van dat type.
