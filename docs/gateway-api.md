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

Deze opzet zet Gateway API ernáást. Migratie gaat per tenant, met de Ingress en
de HTTPRoute tegelijk in de lucht tot de eigenaar tekent.

De implementatie is **Envoy Gateway**, niet de Gateway API van de CNI: dit
cluster draait Calico, dat geen implementatie meelevert.

## Wie bezit wat

| Waar | Wat |
|---|---|
| `gateway-api-crds` (deze repo) | 20 gevendorde CRD's + safe-upgrade-policy |
| `envoy-gateway` (deze repo) | de controller (Helm, `crds.enabled=false`) |
| `envoy-gateway-config` (deze repo) | `GatewayClass`, `Gateway`, `EnvoyProxy`, `ClientTrafficPolicy`, HTTP→HTTPS-redirect |
| `charts/woo-website` (React-base) | de HTTPRoute van een frontend-tenant |
| `charts/tenant-httproute` (Nextcloud-base) | de HTTPRoute + ReferenceGrant van een Nextcloud-tenant |

Dat is de conventie en hij is bewust zo: **het platform bezit de Gateway, de
tenant bezit zijn route.** Een route hoort bij de applicatie en komt dus uit
dezelfde generator die vandaag zijn Ingress rendert. Cluster-infra heeft
daardoor geen schrijfrecht in tenant-namespaces nodig.

Een tenant zet het aan in zijn bestand onder
`Nextcloud-base/nextcloud-platform/values/tenants/`:

    gateway:
      frontend: true
      nextcloud: true
      sectionName: https-<listener>

Beide vlaggen staan los, want een tenant kan zijn frontend eerder migreren dan
zijn Nextcloud. Zonder `gateway:`-blok rendert er niets extra's — bestaande
tenants zien geen enkele wijziging in hun values, ook niet in de vorm van een
`enabled: false`. Dat is opzet: een blok dat altijd wordt meegegeven zou alle 84
Applications tegelijk laten hersyncen.

## Wat je moet weten voor je iets aanraakt

**PROXY-protocol is geen detail.** De OpenStack-loadbalancer stuurt een
PROXY-header. Zonder `ClientTrafficPolicy` sluit Envoy elke verbinding — niet
"trager", maar helemaal dicht. De annotaties op de Service en de policy horen bij
elkaar; wijzig ze nooit los van elkaar.

**Er is een tweede loadbalancer.** Envoy Gateway heeft een eigen OpenStack-LB op
`81.24.11.239`, naast de `81.24.6.82` van nginx.

**Envoy's default route-timeout is 15 seconden.** nginx staat op 1800. Elke
HTTPRoute naar een Nextcloud heeft daarom expliciete `timeouts` nodig. Vergeet
je dat, dan breekt elke upload — en pas onder belasting.

**`sectionName` is verplicht op elke route.** Zonder pin hecht een route zich ook
aan de HTTP-listener op poort 80. Omdat een expliciete hostname wint van de
hostname-loze redirect-route, zou `http://` dan inhoud serveren in plaats van te
redirecten.

**`allowedRoutes.namespaces.from: All`** staat bewust wijd open. Het spiegelt de
huidige situatie onder nginx. Verscherpen is de eigenlijke winst van deze
migratie, maar hoort in een aparte change nadat het isolatiemodel vaststaat.

## De rem op opschalen: certificaten voor commonground.nu

De frontends zijn eenvoudig: `*.openwoo.app` en `*.accept.openwoo.app` vallen
onder één wildcard (DNS-01), dat reflector in `envoy-gateway-system` spiegelt.
Eén listener bedient de hele vloot.

Voor Nextcloud is dat niet zo. Die hosts staan onder `commonground.nu` en
krijgen elk een eigen certificaat via HTTP-01. Gevolg: **elke Nextcloud-tenant
heeft een eigen listener op de gedeelde Gateway nodig**, met een eigen
`certificateRef` en een `ReferenceGrant` in de tenant-namespace. Dat werkt voor
een canary en schaalt niet naar 84.

De oplossing is dezelfde als die voor openwoo.app al genomen is: een
wildcard-certificaat voor `*.commonground.nu` en `*.accept.commonground.nu` via
DNS-01. De zone staat al bij Cloudflare en `letsencrypt-dns` bestaat al. Dat is
een aparte beslissing en staat als openstaand punt in de change
`add-gateway-api-bootstrap`.

Tot die er is, blijft de per-host listener in `envoy-gateway/config/gateway.yaml`
handwerk per tenant.

## TLS vandaag

- Wildcard: reflector spiegelt `wildcard-openwoo-tls` naar
  `envoy-gateway-system` (regex uitgebreid in
  `cert-manager/wildcard-openwoo-certificate.yaml`).
- Per-host: het bestaande secret blijft in de tenant-namespace en de Gateway
  leest het via een `ReferenceGrant` die de tenant-chart meelevert.

Dat tweede heeft een consequentie: dat certificaat wordt via HTTP-01 over de
**nginx**-Ingress vernieuwd. Verdwijnt die Ingress bij een cutover voordat
cert-manager's `--enable-gateway-api` aanstaat (die vlag staat nu uit), dan
breekt de vernieuwing stil en pas bij de eerstvolgende renewal.

## Hoe een cutover echt gaat

Niet zoals je zou denken. external-dns laat het bestaande record met rust zolang
de Ingress bestaat: bij twee bronnen voor dezelfde hostname wint de eerste
resource. Gemeten 2026-08-17 — met alle canary-routes actief bleef
`canary.accept.openwoo.app` naar `81.24.6.82` wijzen en meldde external-dns
zes reconciles lang "All records are already up to date".

**De cutover is dus het weghalen van de Ingress, niet het bijzetten van de
route.** Dat is ook meteen het punt van geen terugweg: zodra de Ingress weg is,
verhuist het record en is terugdraaien een tweede DNS-wijziging.

Valideren vóór die stap gaat daarom met een geforceerde resolutie, niet op
hostnaam — een `curl` op de hostnaam raakt nog steeds nginx.

## Canary valideren

    IP=81.24.11.239
    H=canary.accept.commonground.nu
    curl -sI --resolve "$H:443:$IP" "https://$H/status.php"
    curl -sI --resolve "$H:443:$IP" "https://$H/.well-known/caldav"
    curl -sI --resolve "$H:80:$IP"  "http://$H/"

Verwacht: 200, 301, 308. Draai daarna dezelfde `curl`s zonder `--resolve` en
vergelijk — dat is het verschil tussen Envoy en nginx.

Verder handmatig: een upload boven de drempel en een request dat langer dan 15
seconden duurt, want dat is wat de `timeouts` moeten bewijzen.

## Gemeten verschillen met ingress-nginx

Gemeten 2026-08-17 op `canary.accept.commonground.nu`. Geen van deze is een
regressie, maar ze zijn wél zichtbaar voor een client en horen langs de eigenaar
vóór een cutover.

| | Envoy | nginx | Waarom |
|---|---|---|---|
| `/.well-known/webfinger` | 301 | 404 | de globale ConfigMap-snippet herschrijft dit intern bij nginx; via Envoy valt het in de `.well-known`-catch-all van de sidecar |
| `/config/config.php` | 404 | 403 | nginx blokkeert op ingress-niveau (`deny all`), de sidecar met `return 404`. Beide dicht |
| CORS op gewone GET | alleen `allow-origin` | volledige set | Gateway API zet de set op de preflight; ingress-nginx op élk antwoord |
| CORS-preflight | 200, Origin geëchood | 204, `*` | met `allow-credentials: true` is `*` door geen browser te gebruiken en een geëchode Origin wél |

Gelijk zijn: `status.php` 200, `.well-known/caldav` 301, poort 80 geeft 308, en
HSTS is identiek (`max-age=31536000; includeSubDomains`).

Die HSTS-waarde is gemeten, niet afgeleid: `nginx.ingress.kubernetes.io/hsts-max-age`
is geen geldige annotatie maar een ConfigMap-instelling, dus de `15552000` in
`Nextcloud-base/values/common.yaml` doet niets. De sidecar zet zelf óók een
HSTS-header (`15768000`) die de client niet haalt.

## Wat NIET naar HTTPRoute vertaald hoeft

Een hardnekkig misverstand: de webfinger-, nodeinfo-, host-meta- en
CalDAV/CardDAV-omleidingen zouden op de Ingress staan. Dat is niet zo. Voor
GitOps-tenants zitten ze in de nginx-sidecar in de pod
(`Nextcloud-base/nextcloud-platform/values/common.yaml`, `nginx.config.default`)
en blijven ze onveranderd achter de HTTPRoute staan.

Ook niet nodig: `proxy-body-size`. Envoy buffert requests niet by default, dus
er is geen limiet om op te heffen — maar meet het met een echte grote upload
voor je het gelooft.

## Bootstrap (eenmalig, door een mens)

De volgorde is niet vrij. Het AppProject eerst: dat wordt door geen enkele
Application beheerd, dus zonder die apply worden alle andere geweigerd.

    kubectl apply -f argo/projects/cluster-infra.yaml
    kubectl apply -f argo/applications/gateway-api-crds.yaml
    kubectl apply -f argo/applications/envoy-gateway.yaml
    kubectl apply -f argo/applications/envoy-gateway-config.yaml

Elke stap `Synced Healthy` afwachten voor de volgende. Let op tussen de derde en
de vierde: `kubectl get svc -n envoy-gateway-system` moet een extern IP tonen.
Krijgt de LoadBalancer er geen, dan is dat quota en heeft doorgaan geen zin.

Let ook op de volgorde met `external-dns`: die draait met
`--source=gateway-httproute` en start niet zonder de Gateway API-CRD's. Landt
die instelling vóór `gateway-api-crds`, dan crashloopt external-dns met
`failed to sync *v1beta1.Gateway`. Dat is op 2026-08-17 precies zo misgegaan.

## Terugdraaien

- Eén tenant: de `gateway:`-vlag uit zijn bestand halen. De Ingress heeft altijd
  doorgedraaid en de backend-Service is gedeeld en onaangeroerd. Is het record
  al verhuisd, dan hoort de Ingress terug vóór de vlag eruit gaat.
- Alles: `envoy-gateway-config` en `envoy-gateway` verwijderen.
  `gateway-api-crds` staat op `prune: false` en gaat dus niet vanzelf mee — dat
  is opzet, want een CRD weghalen wist in één klap elk object van dat type.
