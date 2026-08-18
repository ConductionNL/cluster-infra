---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# IPv6 via Cloudflare

Onze loadbalancer is IPv4-only. Cloudflare's edge is dual-stack en genereert voor
geproxiede records automatisch AAAA. Twee routes, afhankelijk van wie de zone
bezit.

| Host | Route | Kosten |
|---|---|---|
| eigen zone (`*.openwoo.app`, `*.commonground.nu`) | proxy-vlag aanzetten | $0 |
| klantdomein (`open.dinkelland.nl`) | Cloudflare for SaaS custom hostname | $0 tot 100 hostnamen, daarna $0,10/mnd |

Zone-delegatie van één subdomein (*subdomain setup*) kan **niet**: Enterprise-only.

## Test A — proxy op een eigen host

1. Zone `openwoo.app` → SSL/TLS → Overview: modus moet **Full (strict)** zijn.
2. DNS → Records → `canary` → Proxy status op *Proxied*.
3. Meten, vóór en na: `./scripts/check-cloudflare-proxy.sh canary.openwoo.app`
4. `--watch 180` erbij om te zien of external-dns de vlag terugdraait
   (`policy: sync`, `interval: 1m`). Klapt hij terug, dan moet het via de
   `cloudflare-proxied`-annotatie in external-dns, niet via het portaal.
5. Terug: Proxy status op *DNS only*.

## Test B — Cloudflare for SaaS

Stap 1–4 zijn bij ons en veranderen niets voor de klant.

1. Zone `openwoo.app` → SSL/TLS → **Custom Hostnames** → aanzetten.
2. DNS → Records → `customers` → A `81.24.6.82` → **Proxied**. Dat wordt de
   fallback origin; instellen op de Custom-Hostnames-pagina, wachten op *Active*.
3. **Add Custom Hostname** → de klanthost. Cloudflare-managed cert, minimum
   TLS 1.2, validatie via **Delegated DCV**.
4. Noteer de DCV-hostnaam (`<uuid>.dcv.cloudflare.com`) van dezelfde pagina.
5. De klant zet:

       open.dinkelland.nl.                 CNAME  customers.openwoo.app.
       _acme-challenge.open.dinkelland.nl. CNAME  open.dinkelland.nl.<uuid>.dcv.cloudflare.com.
       open.dinkelland.nl.                 CAA    0 issue "letsencrypt.org"
       open.dinkelland.nl.                 CAA    0 issue "pki.goog; cansignhttpexchanges=yes"
       open.dinkelland.nl.                 CAA    0 issue "ssl.com"

6. Verifiëren: `./scripts/check-saas-hostname.sh open.dinkelland.nl`
   Vóór cutover kan dat al tegen de edge: `EDGE_IP=<cf-ip> ./scripts/check-saas-hostname.sh …`
7. Terugrollen is bij de klant: CNAME weer A-records.

Bij de fallback-origin-route stuurt Cloudflare SNI = klanthostnaam, dus ons
bestaande Let's Encrypt-certificaat volstaat en Full (strict) houdt. Gebruik
**geen** custom origin per hostname: dan wijkt SNI af van de Host-header en is
strict onmogelijk zonder Enterprise-entitlement.

## Zoals ingericht (2026-08-18)

Gemeten en aangelegd tijdens de eerste uitrol voor Noaberkracht:

| Wat | Waarde |
|---|---|
| SaaS-zone | `openwoo.app` |
| fallback origin | `saas.openwoo.app` → A `81.24.6.82`, proxied |
| custom hostnames | `open.dinkelland.nl`, `open.tubbergen.nl` |
| minimum TLS | 1.2 |
| DCV | Delegated DCV, doel `<hostname>.7f19f08d5865daf8.dcv.cloudflare.com` |

Drie dingen die anders bleken dan gepland:

**De naam `customers.openwoo.app` was niet vrij.** In deze zone staat een
wildcard `*.openwoo.app` → `81.24.6.45`, en dat IP is geen service in dit cluster
(hier zijn alleen `81.24.6.82` voor nginx en `81.24.11.239` voor Envoy). Elke naam
zonder eigen record valt door naar dat andere cluster. Vandaar `saas` als
expliciet record — dat overruled de wildcard voor die ene naam.

**De zone staat op Flexible en dat kon niet zone-breed om.** De records die daar
al geproxied zijn (`openwoo.app` apex en `conduction.openwoo.app`) komen uit op
`81.24.6.45`, dat alleen het *Kubernetes Ingress Controller Fake Certificate*
presenteert. Full (strict) zone-breed zou die twee een 526 geven.

Flexible laten staan kon ook niet: onze origin antwoordt op HTTP met een **308
naar https**, dus Cloudflare zou een redirect-lus opleveren.

Oplossing: een **Configuration Rule** per hostnaam, zone blijft Flexible.

    (http.host eq "open.dinkelland.nl") or (http.host eq "open.tubbergen.nl")
    → SSL: Full (strict)

Dat schaalt met een negatieve match, want een custom hostname is per definitie
geen naam in deze zone:

    (not http.host ends_with ".openwoo.app") and (http.host ne "openwoo.app")

Cloudflare waarschuwt bij het opslaan dat er geen geproxied record voor die
hostnaam bestaat. Dat is bij Cloudflare for SaaS normaal — de naam staat in de
zone van de klant. Negeren en deployen; géén record voor de klanthostnaam in onze
zone aanmaken.

**Nog te bewijzen:** dat de SSL-actie van een Configuration Rule ook op
custom-hostname-verkeer werkt. Gedocumenteerd per custom hostname zijn minimum
TLS-versie en cipher suites, de modus niet. Daarom test de edge vóór de cutover:

    EDGE_IP=<cloudflare-ip> ./scripts/check-saas-hostname.sh open.dinkelland.nl

Krijgen we een redirect-lus of 526, dan valt deze route af zonder dat de klant
iets merkt.

## Certificaatautoriteit en CAA

De CA van het edge-certificaat kies je op non-Enterprise niet zelf: Cloudflare
mag uit Let's Encrypt, Google Trust Services en SSL.com kiezen en kan wisselen.
Een CAA-record op een klanthostnaam moet daarom alle drie toestaan, of er moet
geen CAA staan. Eén CA noemen breekt een latere vernieuwing.

## DANE

Valt met deze route af. Cloudflare publiceert TLSA als recordtype en heeft sinds
april 2026 DANE voor MX, maar niets voor het edge-certificaat van een geproxiede
website — dat certificaat is van hen en rouleert. Weegt niet mee in de
internet.nl-score (INFO/NOTICE), maar hoort expliciet naar de klant.

## Nextcloud niet

`*.commonground.nu` mag hier niet achter: Cloudflare kapt de request body af op
100 MB (Free en Pro), terwijl de Nextcloud-ingress `proxy-body-size: 16G` en
timeouts van 1800s heeft. IPv6 voor die hosts wacht op de hostingleverancier.

## Wat dit raakt

- **Origin-certificaat**: met de proxy ervoor loopt HTTP-01 door de edge. Een
  Cloudflare Origin CA-certificaat haalt cert-manager voor die hosts uit de
  keten. Keuze, nog niet gemaakt.
- **Onze eigen regel** "geen proxy aanzetten, dat breekt HTTP-01" staat in
  `react-base/CLAUDE.md` en hier. Herzien op basis van test A, niet negeren.
- **Client-IP**: de origin ziet Cloudflare-adressen. Logging en rate-limiting
  gaan op `CF-Connecting-IP`; de PROXY-protocol-keten van de OpenStack-LB blijft
  eronder.
- **Edge-cert** is een bundel ECDSA P-256 + RSA-2048. Een audit kan opnieuw over
  RSA-2048 vallen; dat is dan Cloudflare's keuze.
- **Verwerkersovereenkomst**: van de klant, niet van ons.

## Bronnen

- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/>
- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/getting-started/>
- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/reference/connection-details/>
- <https://developers.cloudflare.com/dns/zone-setups/subdomain-setup/>
- <https://developers.cloudflare.com/network/ipv6-compatibility/>
- <https://developers.cloudflare.com/ssl/reference/certificate-authorities/>
