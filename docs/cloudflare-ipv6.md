---
last_reviewed: 2026-08-28
owner: info@conduction.nl
---

# IPv6 via Cloudflare

## Waarom dit bestaat, en wanneer het weer weg mag

**Cloudflare zit in het verkeerspad om precies één reden: onze loadbalancer
spreekt geen IPv6.** Niets anders. Geen CDN-wens, geen WAF, geen cachingbeleid.
De edge van Cloudflare is dual-stack en genereert voor een geproxied record
automatisch een AAAA; dat is de hele truc.

Dat is een omweg, en een omweg met een prijs: Cloudflare beëindigt de
versleuteling, ziet de inhoud van verzoeken en de IP-adressen van bezoekers,
houdt de sleutel van het edge-certificaat, en is daarmee een sub-verwerker in de
keten naar de klant. Voor een IPv6-vinkje is dat een fors middel.

**De uitweg is native IPv6 op de loadbalancer.** Zodra de hostingleverancier
(Fuga/Cyso, OpenStack) een dual-stack Service met een IPv6-VIP levert, kan de
proxy voor de eigen zones eruit en vervalt de sub-verwerker uit die keten. Voor
`*.commonground.nu` is er sowieso geen andere weg: die hosts kunnen niet achter
dit CDN, want Cloudflare kapt de request body af op 100 MB terwijl de
Nextcloud-ingress `proxy-body-size: 16G` heeft.

Behandel alles hieronder dus als een tijdelijke inrichting met een bekende
einddatum-voorwaarde, niet als de gewenste architectuur. Wie deze pagina leest
omdat er iets stuk is: de vraag "kan de LB inmiddels IPv6?" hoort bij elke
herziening opnieuw gesteld te worden.

## De twee routes

Twee routes, afhankelijk van wie de zone bezit.

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
2. DNS → Records → `saas` → A `81.24.6.82` → **Proxied**. Dat wordt de
   fallback origin; instellen op de Custom-Hostnames-pagina, wachten op *Active*.
   (Waarom `saas` en niet `customers`: zie § Zoals ingericht.)
3. **Add Custom Hostname** → de klanthost. Cloudflare-managed cert, minimum
   TLS 1.2, validatie via **Delegated DCV**.
4. Noteer de DCV-hostnaam (`<uuid>.dcv.cloudflare.com`) van dezelfde pagina en
   haal de eigendomswaarde op:
   `CF_API_TOKEN=... ./scripts/cf-verify.sh --ownership <hostnaam>`
5. De klant zet **eerst deze twee**. Hier verschuift nog geen verkeer:

       _acme-challenge.open.dinkelland.nl.    CNAME  open.dinkelland.nl.<uuid>.dcv.cloudflare.com.
       _cf-custom-hostname.open.dinkelland.nl. TXT   <eigendomswaarde>

   De DCV-CNAME laat het certificaat uitgeven; de TXT activeert de hostname.
   Sla die TXT niet over — zonder eigendomsbewijs routeert de edge niet, ook al
   staat het certificaat op `active`. Zie § Hostname-activatie.

   **Wil de klant CAA, dan moet dat nú**, zolang de naam nog een A-record is:

       open.dinkelland.nl.                 CAA    0 issue "letsencrypt.org"
       open.dinkelland.nl.                 CAA    0 issue "pki.goog; cansignhttpexchanges=yes"
       open.dinkelland.nl.                 CAA    0 issue "ssl.com"

   Na stap 7 kan dat niet meer, en de CAA die er stond werkt dan ook niet meer:
   naast een CNAME mag op dezelfde naam volgens de DNS-standaard geen ander
   recordtype staan. Een CA volgt de CNAME en komt uit bij de CAA van
   `saas.openwoo.app` → `openwoo.app`, en die zone publiceert er geen. Gemeten
   2026-08-28: `open.tubbergen.nl` (nog een A-record) heeft de drie CA's plus
   een `iodef`, `open.dinkelland.nl` (inmiddels CNAME) heeft effectief géén CAA.
   Dat is niet kapot — geen CAA betekent geen beperking — maar het is wél een
   stille versoepeling die je de klant hoort te melden in plaats van te laten
   ontdekken. Alle drie de CA's zijn verplicht zolang de CAA er staat: zie
   [caa.md](caa.md).

6. Meten vóór de cutover, nu de hostname actief is:
   `EDGE_IP=<cf-ip> ./scripts/check-saas-hostname.sh open.dinkelland.nl`
7. Pas daarna de site-CNAME, en die **vervangt** het A-record:

       open.dinkelland.nl.                 CNAME  saas.openwoo.app.

8. Nameten zonder `EDGE_IP`: `./scripts/check-saas-hostname.sh open.dinkelland.nl`
9. Terugrollen is bij de klant: CNAME weer A-records.

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

**De naam `customers.openwoo.app` was niet vrij.** In deze zone stond toen een
wildcard `*.openwoo.app` → `81.24.6.45`, en dat IP is geen service in dit cluster
(hier zijn alleen `81.24.6.82` voor nginx en `81.24.11.239` voor Envoy). Elke naam
zonder eigen record viel door naar dat andere cluster. Vandaar `saas` als
expliciet record — dat overruled de wildcard voor die ene naam.

Die wildcard is op 2026-08-19 verwijderd (legacy, gedeprecieerd cluster); een
niet-bestaande naam geeft nu NXDOMAIN. Het `saas`-record blijft nodig als
fallback origin. Meting en context: [wildcard-openwoo-app.md](wildcard-openwoo-app.md).

**De zone staat op Flexible en dat kon niet zone-breed om.** De records die daar
al geproxied zijn staan niet op ons cluster maar op **GitHub Pages**:
`openwoo.app` en `www.openwoo.app` zijn CNAME's naar `conductionnl.github.io`,
`conduction.openwoo.app` heeft de vier A-records `185.199.108-111.153`. Die
origin presenteert `CN=*.github.io` — een geldige Let's Encrypt-keten, maar de
naam matcht niet met `openwoo.app`, dus Full (strict) geeft daar een 526.
Gemeten 2026-08-19 13:00 CEST.

Eerdere versies van deze pagina schreven die uitzondering toe aan `81.24.6.45`
en het fake ingress-certificaat. Dat was onjuist: die drie namen komen niet bij
dat cluster uit.

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

**Bewezen op 2026-08-19** met een repetitie op onze eigen hostnaam
`saastest.conduction.nl` — zie de sectie hieronder. De SSL-actie van een
Configuration Rule geldt óók voor custom-hostname-verkeer: 200 door de edge,
terwijl de zone op `flexible` staat en onze origin op HTTP een 308 geeft. Had de
regel niet gegolden, dan was het een redirect-lus geworden.

De pre-flight blijft staan als procedure:

    EDGE_IP=<cloudflare-ip> ./scripts/check-saas-hostname.sh <hostnaam>

## Repetitie op een eigen hostnaam (2026-08-19)

De hele route één keer doorlopen op `saastest.conduction.nl`, om te bewijzen wat
we anders op een gemeentesite zouden uitproberen. Werkt omdat `conduction.nl` bij
Cloudflare staat en external-dns die zone níét beheert; een custom hostname mag
niet in de SaaS-zone zelf staan, dus een naam onder `openwoo.app` kan hier niet.
Gelopen op de acceptatie-canary, niet op een productie-namespace.

| Klok (CEST) | Gebeurtenis |
|---|---|
| 21:15:28 | eigendoms-TXT en DCV-TXT gezet in `conduction.nl` |
| 21:17:38 | origin-certificaat READY via HTTP-01, negen seconden na de challenge |
| 21:17:51 | **hostname `active`** — binnen 2 min 23 s, verkeer stond nog op onze LB |
| 21:18:50 | edge-certificaat `active` |
| 21:19:41 | A-record vervangen door `CNAME saas.openwoo.app`, DNS only |
| 21:19:49 | 200 over de echte weg, IPv6 OK, AAAA via de keten |

Vier dingen die deze repetitie heeft opgeleverd:

**De eigendoms-TXT activeert de hostname zonder verkeer te verplaatsen.** Dat is
de uitweg uit de kip-ei hierboven: pre-flight meten mét `EDGE_IP` kan pas als de
hostname actief is, en dat kan nu vóór de cutover. Reken op enkele minuten.

**De Configuration Rule geldt voor custom-hostname-verkeer.** Zie hierboven.

**Het edge-certificaat kwam van een derde CA:** `O=SSL Corporation, CN=Cloudflare
TLS Issuing ECC CA 4`. Dat is `ssl.com` — niet Let's Encrypt, niet Google. Levend
bewijs dat een CAA-record op een klanthostnaam alle drie moet toestaan, zoals
`caa.md` voorschrijft. Eén CA noemen had hier de uitgifte geblokkeerd.

**Onze headers gaan ongeschonden door de edge.** De repetitie-Ingress kreeg
bewust niet de header-snippet van de echte tenants: de origin stuurde 2 van 5, de
edge leverde precies diezelfde 2. Geen filtering aan de edge.

Opruimen hoort dezelfde dag: custom hostname weg, de vier records weg, Ingress en
certificaat weg. Een custom hostname kost een slot (1 van 100) en een
hand-aangelegde Ingress in een Argo-namespace is drift die niemand later plaatst.

## Onze eigen hosts onder `*.openwoo.app`

Hier is geen Cloudflare for SaaS nodig: die namen staan in onze zone, dus de
proxy-vlag is de hele oplossing. Twee dingen maken dit gunstiger dan bij een
klantdomein.

**Het certificaat komt van DNS-01.** De hosts vallen onder één wildcard
(`*.openwoo.app` + `*.accept.openwoo.app`, Certificate `wildcard-openwoo`,
ClusterIssuer `letsencrypt-dns`). De vernieuwing loopt dus niet via een
HTTP-challenge door de edge, maar via een TXT-record in onze eigen zone. Proxyen
raakt die keten niet. Dat is precies het risico dat bij een klantdomein wél
speelt.

**Full (strict) kan hier gewoon**, want de origin presenteert dat wildcard voor
elke `*.openwoo.app`-host.

De Configuration Rule moet dan wel ruimer dan alleen de klanthostnamen. Eén regel
die zowel custom hostnames als onze eigen tenants dekt en precies de twee kapotte
uitzonderingen overslaat:

    (http.host ne "openwoo.app") and (http.host ne "conduction.openwoo.app")
    → SSL: Full (strict)

Die twee zijn uitgezonderd omdat ze op GitHub Pages uitkomen, dat `CN=*.github.io`
presenteert: geldige keten, verkeerde naam, dus Full (strict) geeft er een 526.
Wordt voor die namen ooit een GitHub-Pages-certificaat op het eigen domein
uitgegeven, dan kan de uitzondering vervallen — dat is nog niet gemeten of
aangevraagd.

**De proxy-vlag zet je niet in het portaal.** external-dns bezit deze records
(`policy: sync`) en zet `proxied` standaard op false, dus een dashboard-klik
loopt het risico teruggedraaid te worden. Het hoort via de Ingress:

    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"

Dat is een annotatie in `react-platform/values/common.yaml` (ingress.annotations)
in React-base. Platformwijziging, dus canary eerst en dan de waves volgens
`ROLLOUTS.md`. Voor de custom-domain tenants is die annotatie een no-op:
external-dns beheert alleen `commonground.nu`, `openwoo.app` en `opencatalogi.nl`,
en een klanthostnaam valt daarbuiten.

Verifiëren per host: `./scripts/check-cloudflare-proxy.sh <host>` — verwacht een
AAAA, `server: cloudflare` en een werkende IPv6-verbinding.

De hele klantdomein-set in één tabel, zonder token:

    ./scripts/saas-fleet-status.sh

Dat leest de klanthosts uit de Ingressen van het cluster en zet per host neer of
de DCV-CNAME staat, of de eigendoms-TXT staat, wat de edge antwoordt en of IPv6
werkt. Reken op enkele minuten voor de volledige set; `TIMEOUT` korter zetten
maakt het sneller maar minder betrouwbaar op trage hosts.

## Via de API controleren en zetten

    CF_API_TOKEN=... ./scripts/cf-verify.sh              # leest zone-modus, fallback origin, custom hostnames, rule
    CF_API_TOKEN=... ./scripts/cf-verify.sh --ownership   # wat er nog nodig is om `pending`/`moved` op te heffen
    CF_API_TOKEN=... ./scripts/cf-configrule-apply.sh    # dry-run van de Configuration Rule
    CF_API_TOKEN=... ./scripts/cf-configrule-apply.sh --apply

Rechten: `cf-verify.sh` heeft vijf Read-rechten (Zone, Zone Settings, DNS, SSL and
Certificates, Config Rules); `cf-configrule-apply.sh` heeft Zone:Read plus
Config Rules:Edit. Het token komt uit de omgeving en wordt nooit geprint; een
ontbrekend recht meldt zich luidruchtig in plaats van als "OK".

Gemeten en gezet op 2026-08-18: de regel stond op `full` in plaats van `strict`,
en `www.openwoo.app` ontbrak in de expressie. Nu:

    ssl=strict
    (http.host ne "openwoo.app") and (http.host ne "www.openwoo.app") and (http.host ne "conduction.openwoo.app")

Daarna nagemeten: de apex en `www` geven nog steeds hun 301 naar conduction.nl,
`conduction.openwoo.app` en `canary.openwoo.app` geven 200. `full` werkt ook,
maar valideert het origin-certificaat niet — en dat kan hier juist wel, want elke
host presenteert een vertrouwd certificaat op zijn eigen naam.

## Canary-uitkomst (2026-08-18)

`canary.openwoo.app` staat achter de proxy en werkt over IPv6:

    A        104.21.60.114, 172.67.195.232   (Cloudflare)
    AAAA     2606:4700:3035::ac43:c3e8, 2606:4700:3034::6815:3c72
    server   cloudflare, cf-ray ...-AMS
    cert     Google Trust Services (edge), origin-cert bleef het openwoo-wildcard
    IPv6     status 200, 5.065.692 bytes binnengehaald

Daarmee is bewezen wat niet gedocumenteerd stond: de **SSL-actie van een
Configuration Rule werkt**. De regel staat op Full (strict); had die niet
gegolden, dan zou de zone-modus `flexible` gelden en had onze origin met een 308
naar https een redirect-lus opgeleverd. Er komt een 200 met inhoud, dus Cloudflare
praat over TLS met de origin en accepteert het certificaat.

Onze headers komen ongeschonden door de edge: HSTS, `X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy` en de CSP in Report-Only.

Twee dingen die de canary aan het licht bracht:

**external-dns draait de proxy-vlag niet terug.** `canary.accept.openwoo.app`
stond dagen op `proxied=true` terwijl external-dns dat record bezit
(TXT-registratie aanwezig, `policy: sync`). Een handmatige klik in het portaal
blijft dus staan — dat is geen geruststelling maar een waarschuwing: de vlag is
dan drift die niemand ziet. Vandaar dat hij via de Ingress-annotatie hoort te
komen.

**Twee niveaus diep breekt.** Universal SSL dekt `openwoo.app` en
`*.openwoo.app`, maar niet `*.accept.openwoo.app`. Die accept-host gaf een
TLS-handshakefout zolang hij geproxied stond; teruggezet op DNS only en daarna
weer `Verify return code: 0`, status 200. Voor accept-hosts is Advanced
Certificate Manager nodig (betaalde add-on), of ze blijven IPv4-only.

## Vloot-uitrol: wie heeft IPv6

De proxy-vlag is geautomatiseerd in de ApplicationSet van React-base: **default
aan voor beide omgevingen**, met `frontend.proxied: false` als uitzondering per
tenant. Voor accept kan dat sinds het advanced certificate pack op
`accept.openwoo.app` + `*.accept.openwoo.app` (besteld 2026-08-18, `active`,
Google Trust Services, auto-renew, 1 van 100 advanced certificates).

Gemeten stand:

    gemeten 2026-08-18 21:20 CEST
    live-openwoo    17 van 25
    accept-openwoo  25 van 42
    klantdomein     5 van 46
    commonground.nu 0 van 121 (kan niet via deze route)

Die telling is een momentopname midden in de uitrol: external-dns werkt de
records per tenant bij en resolvers cachen een leeg AAAA-antwoord even na. Meet
zelf in plaats van dit getal te vertrouwen:

    ./scripts/check-cloudflare-proxy.sh <host>          # eigen zone
    ./scripts/check-saas-hostname.sh <klanthost>        # klantdomein

| Groep | Route naar IPv6 |
|---|---|
| `*.openwoo.app` (live) | proxy-vlag; edge-cert is het universal pack |
| `*.accept.openwoo.app` | proxy-vlag; edge-cert is het advanced pack (`CN=accept.openwoo.app`) |
| klantdomeinen (`open.*.nl`) | Cloudflare for SaaS; wacht op twee records van de klant in stap 1 van de klantmail (DCV-CNAME + eigendoms-TXT) en de site-CNAME in stap 2 daarvan |
| `*.commonground.nu` (Nextcloud) | **kan niet** via deze route — 100 MB bodylimiet tegen `proxy-body-size: 16G` |

De klantdomeinen die nu al AAAA hebben, staan niet op onze loadbalancer
(`open.ede.nl`, `open.lansingerland.nl`, `opencatalogi.nl`); die IPv6 komt van een
ander platform.

Aan het certificaat zie je welk pad een accept-host loopt: `CN=accept.openwoo.app`
is de edge, `CN=*.openwoo.app` is onze origin en dus nog niet omgezet.

Verdwijnt het advanced pack, dan moet de default weer per omgeving — anders geeft
een accept-host een TLS-handshakefout. Dat staat als voorwaarde in de template.

Support-antwoorden per situatie: `mail-ipv6-support.md`.

## Hostname-activatie: het certificaat is niet genoeg

Een custom hostname heeft twee onafhankelijke statussen. `ssl.status` gaat op
`active` zodra het certificaat is uitgegeven — dat regelt de DCV-CNAME uit stap 1 van de klantmail.
De hostname zelf (`status`) blijft daarnaast onbevestigd tot Cloudflare eigendom
heeft vastgesteld, en zolang dat zo is routeert de edge niet: **HTTP 409**, met
`custom hostname does not CNAME to this zone` in `verification_errors`.

**Die status heet niet altijd `pending`.** Is de hostname aangemaakt vóórdat de
CNAME er stond, dan heeft Cloudflare al eens gekeken, niets gevonden, en zet hij
`moved`. Wie op "pending" zoekt herkent zijn eigen storing dan niet, terwijl het
dezelfde blokkade met dezelfde oplossing is. Gemeten 2026-08-28 bij
`open.dinkelland.nl`: aangemaakt 18-08, certificaat `active` sinds 19-08,
CNAME pas deze week gezet, en toen nog steeds `status: moved` — Cloudflare
hervalideert een `moved`-hostname niet vanzelf snel genoeg om op te wachten.
Behandel `pending` en `moved` als één toestand: eigendom niet bevestigd.

Standaard bevestigt Cloudflare eigendom door de site-CNAME zelf te zien — maar
dat is stap 2 van de klantmail, en die willen we juist pas zetten nadat we de
route hebben gemeten. Die kip-ei zit in de eerste versie van
`mail-ipv6-klant.md` en kwam op 2026-08-19 bij Noaberkracht naar boven:
certificaat `active`, hostname `pending`, edge 409, stap 2 niet te
verantwoorden. Op 2026-08-28 kwam bij dezelfde klant de andere volgorde langs —
site-CNAME gezet zonder eigendoms-TXT — met `open.dinkelland.nl` offline tot
gevolg. Beide volgordes lopen stuk op hetzelfde ontbrekende record.

Uitweg is pre-validatie. Twee wegen, per hostnaam op te vragen met
`cf-verify.sh --ownership`:

    _cf-custom-hostname.<hostnaam>.  TXT  <uuid>          bij de klant, één record
    http://<hostnaam>/.well-known/cf-custom-hostname-challenge/<uuid>   bij ons

De TXT is de goedkoopste: één extra record in stap 1 van de klantmail, en de hostname wordt actief
zonder dat er verkeer verschuift. De HTTP-variant kan zonder de klant zolang die
hostnaam nog naar onze loadbalancer wijst, maar vraagt een route op de
tenant-frontend en is daarmee duurder dan het probleem.

## Wat de uitrol niet meeneemt

Dertien frontend-Applications hebben geen revisie in hun status en renderen de
annotatie dus niet: `bct-accept`, `beek-accept`, `beek-live`, `ede-accept`,
`ede-live`, `koophulpje-live`, `odmh-accept`, `soest-accept`, `soest-live`,
`stichtsevecht-live`, `test-accept`, `vaals-accept`, `zandbak-010-live`
(suffix `-reactfront`; waar hier "live" staat is dat de productie-variant).
Gecontroleerd op `soest`: `cloudflare-proxied` staat niet in de Helm-values van
die Application, terwijl het bij `baarn` en `helmond` wél staat.

Die apps volgen de huidige ApplicationSet dus niet. Ze krijgen geen IPv6, en ook
geen andere platformwijziging — dat is een groter punt dan IPv6 alleen en hoort
apart uitgezocht.

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
