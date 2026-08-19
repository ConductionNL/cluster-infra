# Changelog

## 2026-08-19 (laatste) — SaaS-route beproefd op een eigen hostnaam, drie aannames omgezet in metingen

Voor Dinkelland en Tubbergen stond de omzetting op "aangenomen dat het werkt".
Dat is niet iets om op een gemeentesite uit te proberen, dus de hele route is
eerst doorlopen op `saastest.conduction.nl`: eigen zone, external-dns beheert hem
niet, en gelopen op de acceptatie-canary. Volledig opgeruimd na de test.

Tijdlijn (CEST): 21:15:28 eigendoms-TXT en DCV-TXT gezet, 21:17:38
origin-certificaat READY via HTTP-01, **21:17:51 hostname `active`** terwijl het
A-record nog op onze loadbalancer stond, 21:18:50 edge-certificaat `active`,
21:19:41 A-record vervangen door `CNAME saas.openwoo.app`, 21:19:49 een 200 over
de echte weg met werkende IPv6.

Wat daarmee bewezen is:

- **De eigendoms-TXT activeert de hostname zonder verkeer te verplaatsen** —
  2 min 23 s. Daarmee is de pre-flight die het mailtemplate belooft uitvoerbaar.
- **De Configuration Rule met `ssl=strict` geldt ook voor custom-hostname-verkeer.**
  Dat stond in `docs/cloudflare-ipv6.md` als "nog te bewijzen". De zone staat op
  `flexible` en onze origin geeft op HTTP een 308; had de regel niet gegolden,
  dan was het een redirect-lus of een 526 geworden. Het werd een 200.
- **Het edge-certificaat kwam van `O=SSL Corporation` (ssl.com)**, niet van Let's
  Encrypt of Google. Levend bewijs voor het CAA-advies in `caa.md`: alle drie de
  CA's toestaan of geen CAA zetten. Eén CA noemen had de uitgifte geblokkeerd.
- **De edge filtert onze headers niet.** De repetitie-Ingress had bewust geen
  header-snippet: origin stuurde 2 van 5, edge leverde diezelfde 2.

Ook twee fouten in `scripts/saas-fleet-status.sh` gevonden en gerepareerd, beide
door de repetitie zichtbaar geworden:

1. Het las adressen via de systeemresolver. Eén minuut na de omzetting stond het
   oude A-record nog in de cache en luidde het oordeel `niet-begonnen` terwijl de
   host al klaar was. `NS` is nu env-tunable.
2. Mijn eerste poging zette `NS` op de autoritatieve server van de zone. Die
   volgt geen CNAME naar een andere zone en geeft dus alleen de CNAME terug — dan
   lijkt elke omgezette host adresloos. `NS` moet een recursieve resolver zijn;
   dat staat nu in de header. Daarnaast filtert het script CNAME-regels uit de
   adreswaarden, zodat een keten niet als "adres" doorgaat.

De klantstand is onveranderd: beide hostnames nog `pending`, want die activeren
door de site-CNAME uit stap 2 of door een eigendoms-TXT in hun zone.

## 2026-08-19 (later) — waarom de klanthosts 409 gaven: hostname pending, niet het certificaat

Noaberkracht had stap 1 gezet en het certificaat was uitgegeven, maar
`open.dinkelland.nl` en `open.tubbergen.nl` gaven 409 aan de edge. Gemeten via de
API: `ssl.status: active` naast `status: pending`, met
`verification_errors: ['custom hostname does not CNAME to this zone.']`.

Een custom hostname heeft dus twee statussen. De DCV-CNAME uit stap 1 levert het
certificaat; eigendomsverificatie is een tweede spoor, en zonder dat routeert de
edge niet. Cloudflare bevestigt eigendom standaard door de site-CNAME te zien —
precies het record dat wij pas in stap 2 durven vragen. Die kip-ei zat in ons
eigen mailtemplate: "stap 2 pas versturen nadat de edge gemeten is" was met
alleen de DCV-CNAME onuitvoerbaar.

Drie wijzigingen:

- `docs/mail-ipv6-klant.md` — stap 1 vraagt nu **twee** records: de DCV-CNAME én
  `_cf-custom-hostname.<hostnaam>` TXT met de eigendomswaarde. Met de reden
  erbij, zodat niemand het als overbodig wegstreept, en met de notitie dat het
  TXT-record na stap 2 weg mag.
- `scripts/cf-verify.sh` — nieuwe modus `--ownership [hostnaam]`: drukt per
  custom hostname de eigendoms-TXT, de HTTP-challenge-URL en de openstaande
  meldingen af. Zonder argument alle hostnames. Read-only, zelfde vijf
  Read-rechten.
- `scripts/saas-fleet-status.sh` — nieuw. Eén tabel met de stand van alle
  klantdomein-hosts uit de Ingressen van het cluster: DCV, eigendom, edge-status,
  certificaat-uitgever, AAAA en een oordeel per host (`klaar`, `stap2-open`,
  `stap1-half`, `niet-begonnen`, `elders`, `kapot-<code>`). Geen token nodig;
  `TARGET`, `LB_IP`, `EDGE_IP`, `TIMEOUT` en `OWN_ZONES` zijn env-tunable.

Eerste vlootmeting met dat script (20:26 CEST, klantdomeinen): `open.dinkelland.nl`
en `open.tubbergen.nl` op `stap1-half`, `open.ede.nl` en `open.lansingerland.nl`
op `elders` (staan op een ander platform, hebben daar al IPv6), de overige
klanthosts op `niet-begonnen`. De volledige set duurt enkele minuten; een run met
`timeout 400` haalde 24 van de hosts.

Openstaand en niet aangeraakt: `saas.openwoo.app` geeft zelf een 526, want onze
nginx heeft geen server-block voor die naam en valt terug op het fake
certificaat. Voor de SaaS-route is dat niet fataal (Cloudflare stuurt de
klanthostnaam als SNI), maar het is een valkuil voor wie de fallback origin
handmatig test.

## 2026-08-19 — wildcard `*.openwoo.app` weg: typefouten geven nu NXDOMAIN

Los van het IPv6-dossier, want het effect is burgerzichtbaar en de IPv6-route
heeft dat niet. Nieuwe pagina `docs/wildcard-openwoo-app.md`: status open,
eigenaar platformbeheer cluster-infra, met de meting van 2026-08-19 12:37 CEST.

Wat gemeten is: elke naam onder `openwoo.app` zonder eigen record valt door naar
`81.24.6.45`. Die host presenteert het *Kubernetes Ingress Controller Fake
Certificate* (verify code 18) en geeft daarachter **HTTP 200** met een generieke
OpenCatalogi-frontend van 3,2 MB — geen 404. Een typefout in een gemeentelijke
URL levert dus eerst een certificaatwaarschuwing op en daarna een site die op een
WOO-site lijkt maar niet die van de gemeente is, op een host die in geen enkele
repo hier voorkomt. Netblok `81.24.4.0/22` (`FUGA_AMS`), hetzelfde als onze
loadbalancer, dus vermoedelijk dezelfde leverancier — eigenaar onbekend.

Drie opties in de pagina (wildcard weg, wildcard naar een beheerde 404, of niets
doen), met de blokkerende vraag: van wie is `81.24.6.45`. Gekruislinkt vanuit
`docs/index.md` en `docs/cloudflare-ipv6.md`, waar de wildcard eerder alleen als
zijopmerking bij de `saas`-recordkeuze stond.

**Opgelost dezelfde dag.** De zone-beheerder heeft de wildcard verwijderd; de
host achter `81.24.6.45` was een gedeprecieerd legacy-cluster. Nagemeten om 12:45
CEST autoritatief tegen `bailey.ns.cloudflare.com`, dus zonder resolver-cache:

- verzonnen naam, typefout en `dinkelland.openwoo.app` → **NXDOMAIN**
- `openwoo.app`, `www`, `conduction`, `canary` → eigen geproxiede records, ongewijzigd
- alle **67** hosts met een Ingress onder `openwoo.app` → 67 × NOERROR, 0 kapot
- 34 CT-namen (certspotter): 29 resolven, 5 NXDOMAIN — alle vijf onder
  `accept.openwoo.app` en zonder Ingress in het cluster (234 Ingress-hosts
  gecontroleerd), dus historische certificaten van verdwenen tenants en géén
  gevolg van deze wijziging. Een wildcard op één label dekte namen met twee
  labels ook nooit.

**Correctie in dezelfde sessie.** De Configuration-Rule-uitzonderingen voor
`openwoo.app`, `www.openwoo.app` en `conduction.openwoo.app` blijven staan, maar
niet om de reden die hier stond. `cloudflare-ipv6.md` schreef die uitzondering
sinds 2026-08-18 toe aan `81.24.6.45` en het fake ingress-certificaat; dat is
onjuist. Gemeten 2026-08-19 13:00 CEST: apex en `www` zijn CNAME's naar
`conductionnl.github.io`, `conduction.openwoo.app` heeft de vier
GitHub-Pages-A-records `185.199.108-111.153`, en die origin presenteert
`CN=*.github.io` — geldige Let's Encrypt-keten, verkeerde naam, dus Full (strict)
geeft er een 526. Gecorrigeerd in `docs/cloudflare-ipv6.md` en
`docs/wildcard-openwoo-app.md`.

Wat daarmee nieuw openstaat: die drie namen zouden Full (strict) wél kunnen
halen als GitHub Pages een certificaat op het eigen domein uitgeeft. Niet
gemeten, niet aangevraagd.

De DNS-wijziging is door een mens gedaan, buiten deze repo (Cloudflare-zone).
Hier alleen documentatie.

## 2026-08-18 (later 6) — wildcard voor commonground.nu: certificaat eerst

Dit is de rem op de Gateway-migratie van de Nextcloud-kant. Elke host onder
`commonground.nu` heeft nu een eigen HTTP-01-certificaat, dus elke tenant vraagt
een eigen listener op de gedeelde Gateway met een eigen `certificateRef`. Werkt
voor één canary, niet voor 84.

Zelfde patroon als `wildcard-openwoo`, dat sinds 2026-06-30 draait:

- `cert-manager/clusterissuer-letsencrypt-dns.yaml` — `commonground.nu` erbij in
  de solver-selector, naast `openwoo.app`.
- `cert-manager/wildcard-commonground-certificate.yaml` — nieuw, voor
  `*.commonground.nu` en `*.accept.commonground.nu`.

**Bewijs dat het token deze zone aankan, zonder het secret te lezen:**
external-dns bezit TXT-eigenaarsrecords in `commonground.nu`
(`heritage=external-dns,...owner=conduction-cluster` op
`canary.accept.commonground.nu`, gemeten 2026-08-18). Een record schrijven
vereist eerst een zone-lookup, dus Zone:Read én DNS:Edit zijn beide aantoonbaar
aanwezig. Dat is precies wat de DNS-01-solver vraagt. De comment in de issuer
waarschuwde daar expliciet voor.

**Reflector-scope is strakker dan bij openwoo, en dat is opzet.** Het
openwoo-secret gaat naar élke tenant-namespace, want daar leest de Ingress het
zelf. Dit certificaat gaat alleen naar `envoy-gateway-system`: de Gateway
termineert centraal. De blast radius van deze private key is één namespace in
plaats van vijftig — dit wildcard is dus veiliger dan het bestaande.

**Bewust nog géén Gateway-listener in deze stap.** Een listener met een
`certificateRef` naar een secret dat nog niet bestaat zet de hele Gateway op
`Programmed=False` — dat is vandaag al een keer gebeurd toen de ReferenceGrant
werd gepruned. Dus: eerst uitgifte bewijzen, dan pas de listener, dan pas de
canary verplaatsen en de per-host listener weghalen. Drie stappen, drie bewijzen.

Meegewijzigd in `docs/gateway-api.md`: de wildcard-route, plus een correctie op
het tenant-voorbeeld — `sectionName` hoort bij de Nextcloud-route en
`frontendSectionName` bij de frontend. Eén gedeeld veld hing vandaag de frontend
van canary-accept aan de verkeerde listener.

## 2026-08-18 (later 11) — verweesde DNS-records geadopteerd

Bij de IPv6-uitrol bleven hosts achter terwijl hun app en Ingress wél om waren.
Oorzaak: external-dns werkt met een TXT-registry en raakt alleen records aan waar
zijn eigen eigendomsrecord bij staat. Voor die hosts bestonden die TXT-records
niet — met de hand aangemaakt, of verweesd door een wijziging van `txtOwnerId`,
precies waar `external-dns/values.yaml` voor waarschuwt. Gemeten: 46 van de 67
hosts in de zone hadden eigendom, de rest niet.

Nieuw `scripts/adopt-dns-records.sh` zet het ontbrekende TXT-eigendom bij (twee
records per host, `<host>` en `a-<host>`), waarna external-dns het record
overneemt. Dry-run als default. Twee ingebouwde grenzen: hosts waarvan het
A-record niet naar onze loadbalancer wijst worden overgeslagen (adoptie zou daar
verkeer verplaatsen — `barneveld.openwoo.app` staat op een ander cluster), en met
`--only-annotated` blijven hosts buiten schot waar adoptie niets oplost.

Uitgevoerd op almere en daarna op negen hosts met de proxy-annotatie. Acht van de
negen hadden binnen enkele minuten AAAA, alle negen geven 200. Elf hosts sloeg het
script bewust over: dat zijn de legacy-Ingresses zonder proxy-annotatie.

`mail-ipv6-klant.md` en `mail-ipv6-support.md`: expliciet dat het A-record wordt
**vervangen** door de CNAME en dat er geen A of AAAA naast mag staan — ook niet een
AAAA met een adres van ons, want het platform is IPv4-only.

## 2026-08-18 (later 10) — accept doet mee, docs op de gemeten stand

Advanced certificate pack besteld en `active` op `accept.openwoo.app` +
`*.accept.openwoo.app` (Google Trust Services, auto-renew). De ACM-entitlement
zat al op het plan — 0 van 100 advanced certificates in gebruik — dus er was
niets te kopen; alleen te bestellen. Daarna staat de proxy-default in React-base
aan voor beide omgevingen.

`docs/cloudflare-ipv6.md` heeft nu de gemeten stand in plaats van een tabel met
verwachtingen, met de waarschuwing dat het een momentopname is: external-dns
werkt per tenant bij en resolvers cachen een leeg AAAA-antwoord na.
`mail-ipv6-support.md` sectie 3 is omgedraaid: accept is geregeld, met de
certificaatregel als check (`CN=accept.openwoo.app` = via de edge,
`CN=*.openwoo.app` = nog niet omgezet).

`mail-ipv6-klant.md` is klaar-voor-gebruik: de DCV-bestemming staat er letterlijk
in (per zone vast) en er staat bij wat je vóór verzending zelf moet doen.

Bevinding uit de uitrol: dertien frontend-Applications hebben geen revisie in hun
status en renderen de annotatie niet. Op `soest` gecontroleerd: `cloudflare-proxied`
staat niet in hun Helm-values, terwijl het bij `baarn` en `helmond` wél staat. Die
apps volgen de huidige ApplicationSet dus niet — dat raakt meer dan IPv6 en staat
als apart punt in de docs.

## 2026-08-18 (later 9) — vloot-default, accept-grens en support-antwoorden

De proxy-vlag is nu een default in de ApplicationSet van React-base: aan voor
live, uit voor accept. `docs/cloudflare-ipv6.md` heeft de vloot-tabel (17 live
onder `*.openwoo.app` krijgen AAAA, 12 klantdomeinen zijn een no-op, 38 accept
blijven DNS-only) en de voorwaarde voor accept: Advanced Certificate Manager,
omdat Universal SSL geen tweede niveau dekt.

Nieuw `docs/mail-ipv6-support.md`: drie situaties met een kant-en-klaar antwoord
(host onder openwoo.app, klantdomein, acceptatie), plus wat support nooit belooft
— geen DANE, geen CAA-verzoek, geen IPv6 op Nextcloud.

## 2026-08-18 (later 8) — IPv6 werkt op de canary

`canary.openwoo.app` staat achter de Cloudflare-proxy en is over IPv6 bereikbaar:
status 200 en 5 MB inhoud over v6, edge-cert van Google Trust Services, en onze
headers komen ongeschonden door (HSTS, nosniff, XFO, Referrer-Policy, CSP in
Report-Only).

Dat bewijst het punt dat niet gedocumenteerd stond: de SSL-actie van een
Configuration Rule werkt óók op deze route. Gold hij niet, dan had de zone-modus
`flexible` gegolden en had de 308-naar-https van onze origin een redirect-lus
gegeven.

Twee bevindingen. external-dns draait de proxy-vlag **niet** terug — de
accept-canary stond dagen geproxied terwijl external-dns dat record bezit, dus een
portaalklik is stille drift. En twee niveaus diep breekt: Universal SSL dekt
`*.openwoo.app` maar niet `*.accept.openwoo.app`; die host gaf een
TLS-handshakefout en staat weer op DNS only (`Verify return code: 0`, 200).

## 2026-08-18 (later 7) — Cloudflare via de API: controleren en de rule zetten

Twee scripts. `cf-verify.sh` leest de zone-SSL-modus, het fallback-origin-record,
de custom hostnames en de Configuration Rule, en velt per stuk een oordeel.
`cf-configrule-apply.sh` zet die regel, dry-run als default en idempotent.

Wat de eerste meting opleverde: de regel stond op `full` in plaats van `strict`
en `www.openwoo.app` ontbrak in de expressie. Bijgewerkt naar `ssl=strict` met
alle drie de uitzonderingen. Nagemeten: apex en `www` geven nog hun 301,
`conduction.openwoo.app` en `canary.openwoo.app` geven 200.

Beide scripts lezen het token uit de omgeving en printen het nooit. Een
ontbrekend recht meldt zich als "NIET OP TE HALEN" in plaats van stil als OK.

## 2026-08-18 (later 6) — standaardmail en de route voor onze eigen zone

`docs/mail-ipv6-klant.md` is de template voor een klantdomein: twee stappen,
plus expliciet wat er níét in hoort (geen CAA-verzoek, geen DANE-belofte).

`docs/cloudflare-ipv6.md` heeft nu ook de route voor `*.openwoo.app`. Daar is
geen Cloudflare for SaaS nodig — de namen staan in onze zone, dus de proxy-vlag
is de hele oplossing. Twee metingen maken dat gunstiger dan bij een klantdomein:
het wildcard-certificaat komt van `letsencrypt-dns` (DNS-01), dus proxyen raakt
de vernieuwing niet, en de origin presenteert dat wildcard voor elke host, dus
Full (strict) kan gewoon.

De Configuration Rule moet daarvoor ruimer: alles behalve de apex en
`conduction.openwoo.app`, want die twee komen uit op een ingress met het fake
default-certificaat. En de proxy-vlag hoort niet in het portaal maar op de
Ingress (`external-dns.alpha.kubernetes.io/cloudflare-proxied`), want
external-dns bezit die records.

## 2026-08-18 (later 5) — Cloudflare for SaaS ingericht voor de twee Noaberkracht-hosts

`docs/cloudflare-ipv6.md` bevat nu de as-built: SaaS-zone `openwoo.app`, fallback
origin `saas.openwoo.app` (proxied A naar de nginx-LB), custom hostnames voor
open.dinkelland.nl en open.tubbergen.nl, minimum TLS 1.2, Delegated DCV.

Drie dingen bleken anders dan gepland. `customers.openwoo.app` was niet vrij: er
staat een wildcard `*.openwoo.app` naar een IP buiten dit cluster. De zone staat
op Flexible en kan niet zone-breed naar Full (strict), want de al geproxiede
records komen uit op een ingress die alleen het fake default-certificaat
presenteert. En Flexible laten staan kon ook niet, want onze origin antwoordt op
HTTP met een 308 naar https — dat is een redirect-lus. Oplossing: een
Configuration Rule per hostnaam, met een negatieve match die met de vloot
meeschaalt.

Nog te bewijzen vóór de cutover: dat de SSL-actie van een Configuration Rule ook
op custom-hostname-verkeer werkt. Dat is niet gedocumenteerd en wordt gemeten met
`check-saas-hostname.sh` via `EDGE_IP`, zonder dat de klant iets merkt.

Verder vastgelegd: de CA van het edge-certificaat is op non-Enterprise niet te
kiezen (Let's Encrypt, Google Trust Services of SSL.com), dus een CAA-record moet
alle drie toestaan of ontbreken. DANE valt met deze route af.

## 2026-08-18 (later 4) — certificaatketen noorderzijlvest gerepareerd

`open.noorderzijlvest.nl` serveerde alleen het leaf-certificaat. De intermediate
stond in de AIA-extensie van dat leaf, dus ophalen kon zonder de klant. Alleen
`tls.crt` in het secret vervangen (private key onaangeroerd), keten valideert nu
tot Sectigo Root R46 en de server stuurt twee certificaten.

Dat is een subtest die meeweegt in de internet.nl-score, dus de regel
`open.noorderzijlvest.nl cert` is uit `hosts/internetnl-allow.txt` gehaald: de
wekelijkse gate slaat vanaf nu aan als de keten terugvalt.

## 2026-08-18 (later 3) — SHA-224 uitzetten met back-up en zelfrollback

`tls-sigalgs-apply.sh` zet de `http-snippet` met `ssl_conf_command
SignatureAlgorithms` op de controller-ConfigMap. Niet als losse `kubectl patch`,
om twee redenen: die ConfigMap staat in geen repo (Helm-release `nginx`, geen
Argo-app), en de wijziging raakt de hele vloot plus Nextcloud.

Het script maakt eerst een back-up, patcht, en verifieert daarna twee dingen: dat
`ECDSA+SHA224` daadwerkelijk geweigerd wordt én dat de smoke-hosts nog
antwoorden. Klopt dat niet binnen `WAIT_SECONDS`, dan draait hij zelf terug.
Zonder `--apply` is het een dry-run. `backup/` staat in `.gitignore`:
clusterstaat hoort niet in git.

Meting die hierbij hoort: de ECDSA-omzetting loste SHA-224 NIET op. `RSA+SHA224`
wordt geweigerd omdat de sleutel geen RSA meer is, maar `ECDSA+SHA224` gaf op
beide Noaberkracht-hosts nog een signatuur.

## 2026-08-18 (later 2) — periodieke buitenkant-meting als gate

`internetnl-precheck.sh` kreeg `--strict` en `--allow`: hij faalt alleen op gaten
die niet in de allowlist staan. Nieuwe workflow `internetnl.yml` draait dat elke
maandag 06:00 UTC over `hosts/internetnl.txt` (33 publieke klanthosts).

Op GitHub-runners en niet in de monitoring-stack, want deze meting mag niet
afhangen van één cluster. En niet als pre-push-hook: vóór de deploy bestaat de
stand niet, en een netwerkafhankelijke gate is een onbetrouwbare gate.

`hosts/internetnl-allow.txt` bevat de 51 gemeten, bekende gaten van vandaag met
de reden erbij. Dat is een werkvoorraad, geen vrijbrief.

Twee gaten in het toezicht staan expliciet in `docs/internet-nl.md`:
`CertificateExpiringSoon` ziet alleen cert-manager-certificaten (het handmatige
Sectigo-cert van noorderzijlvest wordt door niets bewaakt), en de wekelijkse
meting dekt de commonground-hosts nog niet.

## 2026-08-18 (later) — internet.nl: de score-set gemeten, niet aangenomen

Klantomgevingen moeten naar 100%. Uit de bron van internet.nl (categories.py +
scoring.py) blijkt dat alleen IPv6, DNSSEC, RPKI en het TLS-blok meewegen.
Headers, security.txt, CAA, DANE, OCSP en de SHA-224-hashfunctie staan op NOTICE
of INFO en leveren geen procent op — goed om te doen, maar niet hiervoor.

Nieuw script `internetnl-precheck.sh` meet die set per host. Uitkomst over 33
klanthosts en een steekproef van commonground.nu staat in `docs/internet-nl.md`.
Kort: IPv6 is het enige punt dat alles raakt (RPKI van ons prefix is al valid),
13 hosts staan nog op RSA-2048 (internet.nl wil 3072+ of ECDSA),
`open.noorderzijlvest.nl` serveert een chain zonder intermediate en
`open-oud.noaberkracht.nl` is dood.

De eerste versie van het script stopte stil na 13 hosts: set -e plus pipefail
op een `grep` die niets vond. Precies de hosts zonder HSTS of zonder TLS vielen
zo buiten de meting — de interessante dus.

## 2026-08-18 — IPv6 via Cloudflare: onderzoek, runbook en meetscripts

De LB is IPv4-only, dus IPv6 (audit open.dinkelland.nl) moet van de edge komen.
Twee routes vastgelegd in `docs/cloudflare-ipv6.md`: proxy-vlag voor onze eigen
zones, Cloudflare for SaaS custom hostnames voor klantdomeinen. Subdomein-zone
delegeren kan niet (Enterprise-only). Kosten: $0 tot 100 hostnamen.

Twee read-only meetscripts: `check-cloudflare-proxy.sh` (test A, incl. `--watch`
om te zien of external-dns de proxy-vlag terugdraait) en
`check-saas-hostname.sh` (test B, ook vóór cutover te draaien via `EDGE_IP`).

Nog geen besluit en niets aangezet in het portaal.

## 2026-08-17 (later) — routes naar de generators, tijdelijke constructie weg

De canary-routes stonden in deze repo omdat de generators van Nextcloud-base en
react-base tijdens de eerste uitrol niet geraakt mochten worden. Dat is nu de
conventie geworden die het hoort te zijn: **het platform bezit de Gateway, de
tenant bezit zijn route.**

- `gateway-canary-routes` en `envoy-gateway/canary-routes/` verwijderd. De
  routes komen nu uit `React-base/charts/woo-website` en
  `Nextcloud-base/charts/tenant-httproute`, gerenderd door dezelfde
  ApplicationSets die vandaag hun Ingress renderen. Opt-in per tenant met
  `gateway.frontend` / `gateway.nextcloud`.
- `canary-accept` en `almere-accept` uit de `destinations` van het AppProject.
  Cluster-infra kan daarmee niet meer in tenantruimte schrijven.
- De HTTP→HTTPS-redirect blijft, maar verhuist naar
  `envoy-gateway/config/httproute-http-redirect.yaml` en is nu hostname-loos:
  permanent platformgedrag voor élke host op de Gateway in plaats van drie
  hardgecodeerde canary-hosts.

Opruimen in het cluster is handwerk: `kubectl delete application -n argocd
gateway-canary-routes`. De volgorde maakt niet uit — er loopt nog geen verkeer
over de Gateway, want geen enkel DNS-record wijst ernaar.

`docs/gateway-api.md` herschreven met de eigendomsverdeling, de vier gemeten
verschillen met nginx, en twee dingen die eerder fout in de docs stonden: een
`curl` op de hostnaam raakt nog nginx (dus valideren gaat met `--resolve`), en
een cutover is het wéghalen van de Ingress, niet het bijzetten van de route.

Bekende beperking, expliciet opgeschreven: Nextcloud-hosts hebben elk een eigen
HTTP-01-certificaat en dus elk een eigen listener op de gedeelde Gateway. Dat
schaalt niet naar 84. De oplossing is een DNS-01-wildcard voor
`*.commonground.nu`, zoals al gedaan voor openwoo.app.

## 2026-08-17 — Gateway API naast ingress-nginx (canary)

Vier nieuwe Applications, naast de bestaande controller — er verandert niets
voor verkeer dat vandaag over nginx loopt. Aanleiding: `ingress-nginx` is
upstream gearchiveerd (2026-03-24) en draait hier met
`allow-snippet-annotations: true` + `annotations-risk-level: Critical`, wat
elke namespace met Ingress-rechten nginx-configuratie laat injecteren.

- `gateway-api-crds` — 20 CRD's + safe-upgrade-policy, gevendord uit
  `gateway-helm` 1.8.3 (Gateway API bundle v1.5.1) in
  `gateway-api/crds/envoy-gateway-crds-1.8.3.yaml`. `prune: false`: een CRD
  weghalen wist elk object van dat type tegelijk. Herkomst, sha256 en de
  bump-procedure in `gateway-api/README.md`. Niet het upstream
  standard-channel-asset: dat heeft 8 CRD's, de chart 12, en de ClusterRole van
  Envoy Gateway watcht `tcproutes`/`udproutes`/`listenersets`.
- `envoy-gateway` — de controller, chart gepind op 1.8.3, `crds.enabled=false`.
  OCI-registry, dus `repoURL: docker.io/envoyproxy` zonder `oci://`-prefix.
- `envoy-gateway-config` — `GatewayClass eg`, `Gateway platform-gateway`,
  `EnvoyProxy` en `ClientTrafficPolicy`. Gescheiden van de controller om
  dezelfde reden als `cert-manager-config`.
- `gateway-canary-routes` — tijdelijk: HTTPRoutes voor
  `canary-accept/woo-website`, `almere-accept/woo-website` en
  `canary-accept/nextcloud`, een HTTP→HTTPS-redirect (308, want nginx geeft
  vandaag ook 308 en zonder route zou poort 80 een 404 geven) en een
  `ReferenceGrant`. Verhuist naar de generators zodra de batch-migratie begint.

Punten die tijdens de bouw uit metingen bleken en niet uit de manifests:

- De OpenStack-LB spreekt PROXY-protocol. Zonder `ClientTrafficPolicy` sluit
  Envoy elke verbinding. `enableProxyProtocol` is in 1.8 deprecated; gebruikt is
  `proxyProtocol.optional: false`.
- Envoy's default route-timeout is 15s tegen 1800s bij nginx. De
  Nextcloud-HTTPRoute zet `timeouts.request`/`backendRequest` expliciet.
- De HSTS- en CORS-filters zijn afgeleid van de **gemeten** response-headers,
  niet van de annotaties: `nginx.ingress.kubernetes.io/hsts-max-age` is geen
  geldige annotatie, dus op de lijn staat de controller-default 31536000 en
  niet de 15552000 uit `Nextcloud-base`.
- De Nextcloud-canary krijgt geen DNS-wijziging: zijn certificaat wordt via
  HTTP-01 over de nginx-Ingress vernieuwd en dat breekt bij een cutover.

Meegewijzigd: `external-dns` leest nu ook `gateway-httproute` (additief, de
chart breidt de ClusterRole zelf uit); de reflector-regex op het
openwoo-wildcard is uitgebreid met `envoy-gateway-system`; `verify.sh`
valideert `envoy-gateway/` mee; AppProject uitgebreid met de OCI-bron,
`envoy-gateway-system`, twee met naam genoemde canary-namespaces en de
cluster-scoped types `GatewayClass` en `ValidatingAdmissionPolicy(Binding)`.

`./scripts/verify.sh` groen: 44 YAML-bestanden geparseerd, 25 manifests valide,
doc-assertie dekt 12 Applications.

## 2026-08-11 — docs-controle op de credential-refresh-wijziging

Alle claims uit de wijziging van 2026-08-10 nagetrokken tegen het cluster. Ze
kloppen: `restartPolicy` staat op `Never`, de env-vars `GARDENER_SA`,
`RENEW_BEFORE_DAYS` (30) en `TOKEN_DURATION` staan op de container, de live
`refresh.sh` bevat het zelfverleng-blok, en de run van 2026-08-11 00:00 UTC
logde `Gardener-token: 89d resterend (drempel 30d)` en patchte alle drie de
clusters. De genoemde alertnamen bestaan ook echt in de monitoring-repo.

- `docs/argocd.md`, § tweede refresh-pad: de **bron** benoemd
  (`toolchain/scripts/login_script.sh`, drie `argocd cluster add --upsert --yes`
  met persoonlijke kubeconfigs; dezelfde constructie zit in de robert- en
  ruben-varianten, dus het geldt voor drie mensen), plus de branch waar de fix
  klaarligt en een controle om te zien of het pad écht weg is. Reden: zodra die
  fix landt, wijst deze sectie de volgende lezer bij een storing de verkeerde
  kant op. Nu staat er wat je moet meten en wanneer de sectie mag verdwijnen.

## 2026-08-11 — pre-commit: techbook-hooks naar v0.2.0

De techbook-hooks stonden nog op commit `edf269ee` terwijl `monitoring`,
`Nextcloud-base` en `openwoo-app-config` al op tag `v0.2.0` zitten. Naar `v0.2.0`
gebracht en de hook `docs-touched` toegevoegd, zodat deze repo dezelfde gate
draait als de rest. Alle zes hooks groen over de hele repo.

## 2026-08-10 — credential-refresh: verlopen Gardener-token, logretentie en docs

De CronJob `argocd-credential-refresh` faalde om 12:00 UTC
(`argocd-credential-refresh-29772720`, `BackoffLimitExceeded`). Oorzaak: het
service-account-token in bootstrap-secret `gardener-sa-kubeconfig` was
verlopen — `sub` `system:serviceaccount:garden-wh2mnkj:argocd-automation`,
`iat` 2026-05-12T07:14:20Z, `exp` **2026-08-10T07:14:20Z** (90 dagen). De run
van 00:00 UTC slaagde nog. Het service-account zelf was in orde; alleen het
token moest geroteerd worden.

Argo CD bleef ondertussen werken, maar niet dankzij de CronJob: de drie
`cluster-api.*`-secrets bevatten certificaten met subject
`…:garden-wh2mnkj:mark-conduction`, geschreven door `mcc login` via de
user-systemd-timer `mcc-login.timer` op een werkstation. Dat vangnet loopt op
een persoonlijke identiteit, op één machine, met ongeveer een minuut marge
tussen certverval (03:00 UTC) en de volgende timerrun (03:00 UTC).

### Herstel

Geroteerd op 2026-08-10: het nieuwe token voor `argocd-automation` heeft `exp`
**2026-11-08T12:58:32Z** (volledige 90 dagen). Na een handmatige run staan de
drie `cluster-api.*`-secrets weer op subject `…:argocd-automation` met
`notAfter` van +24 uur; het CronJob-pad draait dus weer op eigen benen.

### Zelfverlenging, zodat er geen persoonlijk account meer in het pad zit

- `argocd/resources/credential-refresh/configmap.yaml`: `refresh.sh` verlengt
  aan het begin van elke run zijn eigen Gardener-token. Het leest de
  `exp`-claim uit het gemounte kubeconfig en mint bij minder dan
  `RENEW_BEFORE_DAYS` resterend een opvolger van `TOKEN_DURATION`, waarna het
  `gardener-sa-kubeconfig` patcht. Dat mag zonder RBAC-wijziging: de Role hier
  had `patch`/`update` op dat secret al, en het service-account heeft `create`
  op `serviceaccounts/token` in `garden-wh2mnkj` (`auth can-i` → `yes`).
  Beide externe calls zijn afgevangen; mislukken ze, dan logt de job een
  waarschuwing en gaat door met het nog geldige token — een mislukte
  verlenging mag de credential-refresh zelf niet omvergooien.
- Hetzelfde bestand is omgezet van een geëscapete YAML-regel naar een
  block-scalar. Reden: een blok van 25 regels toevoegen aan een one-liner van
  60 regels shell is niet te reviewen, en in deze repo *is* de diff de review.
  Inhoudelijk is er niets aan het bestaande script gewijzigd — gecontroleerd
  door de gerenderde `refresh.sh` vóór en ná te diffen (alleen toevoegingen).
  Het resultaat is door `bash -n` en `shellcheck` gehaald.
- `argocd/resources/credential-refresh/cronjob.yaml`: `GARDENER_SA`,
  `RENEW_BEFORE_DAYS` (30) en `TOKEN_DURATION` (2160h = 90d, het
  Gardener-maximum) als expliciete `env` op de container, zodat de drempels
  zichtbaar en te draaien zijn zonder de ConfigMap te lezen.

Grens van dit mechanisme, vastgelegd in de docs: ligt de CronJob langer dan
`TOKEN_DURATION` stil, dan is handmatige rotatie alsnog nodig. Cyso heeft
meerdere mensen met rechten op het project, dus die break-glass hangt niet aan
één persoon.

### Overige wijzigingen

- `argocd/resources/credential-refresh/cronjob.yaml`: `restartPolicy`
  `OnFailure` → `Never`. Bij `OnFailure` ruimt de job-controller de pod op
  zodra `backoffLimit` is bereikt, waardoor de logs van déze storing niet meer
  op te vragen waren. Met `Never` blijven falende pods staan tot
  `failedJobsHistoryLimit` ze opruimt.
- `docs/argocd.md`: nieuwe § Credential-refresh met de zelfverlenging en haar
  drempels, handmatige rotatie als break-glass, de commando's om expiry en
  certsubject te controleren zonder credentials te tonen, en het tweede
  refresh-pad als gedocumenteerd vangnet (géén ontwerp). De alerting-regel is
  niet langer een opvolgpunt maar verwijst naar de monitoring-repo.

Openstaand, buiten deze repo: `mcc` laten ophouden met het patchen van
platformsecrets met een persoonlijke identiteit. Zolang dat draait, blijft een
persoonlijk account in het pad zitten en verbergt het of de CronJob werkt.
## 2026-08-07 — servergate op de pre-commit-hooks; techbook-hooks van GitHub

### Aanleiding

Een security-sweep over de infra-repos liet zien dat gitleaks hier alleen in
`.pre-commit-config.yaml` stond. Dat is een lokale controle: hij mist iedereen
die `pre-commit install` niet heeft gedraaid, en `--no-verify` zet hem uit.
GitHub's secret scanning vangt het daarna wel op deze repo (aan, nul alerts),
maar dat is detectie ná de push, niet preventie ervoor.

### Toegevoegd

- `.github/workflows/ci.yml` — draait op elke PR en elke push naar `main`
  exact dezelfde `.pre-commit-config.yaml` als de operator, met
  `--hook-stage pre-push` zodat de `verify`-hook meegaat. Geen tweede lijst
  checks; één config, twee plekken die hem draaien. Zelfde patroon als
  `openwoo-app-config`. `kubectl` en `kubeconform` worden vast geprikt en op
  sha256 gecontroleerd geïnstalleerd; kubeconform staat bewust op v0.7.0,
  de versie die de operator lokaal draait.

### Gewijzigd

- `.pre-commit-config.yaml` haalt de techbook-hooks nu van
  `github.com/ConductionNL/techbook` in plaats van
  `codeberg.org/Conduction/techbook`. Dezelfde `rev` (`edf269e`) bestaat daar
  — de hashes zijn bij de migratie behouden — dus dit is een exacte
  omzetting, geen versiesprong. Zonder deze wijziging zou de nieuwe CI de
  hooks bij elke run van de oude trust root trekken.
- `docs/agents.md` — de regel "Push: gates draaien bij de mens" klopte niet
  meer nu ze ook serverside draaien.

## 2026-08-03 — Argo CD v3.2.12 → v3.4.6 (slotstap; 3.3 overgeslagen)

Stap 2 is gesynct en groen: alles op v3.2.12 en Ready, app Synced/Healthy op
`e3708b8`, en de redis-major 7.2 → 8.2 verliep zonder problemen.

- `argocd/upstream/install-v3.4.6.yaml` vervangt `install-v3.2.12.yaml`;
  `argocd/kustomization.yaml` en `docs/argocd.md` wijzen mee.

### Waarom 3.3 is overgeslagen

De geplande tussenstap **v3.3.13 bevat een upstream-fout**: de
`argocd-repo-server`-Deployment mount `argocd-cmd-params-cm` als volume maar
declareert dat volume niet. `kubectl diff -k argocd` faalt daarop hard met
`The Deployment "argocd-repo-server" is invalid:
spec.template.spec.containers[0].volumeMounts[8].name: Not found:
"argocd-cmd-params-cm"`.

Per patchrelease uitgezocht: **v3.3.0 t/m v3.3.12 zijn goed, alleen v3.3.13 is
kapot**, en in v3.4.6 staat het volume er weer wél. Keuze was v3.3.12 als
tussenstap of direct door; besluit Mark: **direct naar v3.4.6**, omdat v3.3.12
een wegwerp-tussenstap zou zijn op een release waar we niet blijven.

Prijs daarvan is de bisect-mogelijkheid — de 3.3- en 3.4-wijzigingen landen in
één sync. Dat weegt licht: de twee risico's zijn aan hun symptoom te
onderscheiden (de CRD-wijziging kan geen SSO-storing geven, Dex kan geen
CRD-fout geven). Loopt het mis, dan blijft **v3.3.12 de bruikbare tussenstap**.

### Wat deze stap in het cluster doet (vooraf doorgerekend)

`kubectl diff -k argocd`: **7415 regels over 10 objecten** — 6 Deployments, 1
StatefulSet, 3 CRD's. Geen RBAC-wijzigingen; die verlaging landde al bij v3.2.12.

- Images: argocd `v3.2.12` → `v3.4.6`, dex **`v2.43.0` → `v2.45.0`**, redis
  `8.2.2-alpine` → `8.2.3-alpine`.
- De render is volledig gecontroleerd op volume/mount-consistentie over álle
  workloads en containers: geen inconsistenties. Diezelfde check ving de
  v3.3.13-fout, dus hij is nu de standaardcontrole bij een vendored manifest.

### SSA hard aangetoond

De `applicationsets.argoproj.io`-CRD is **373.903 bytes** — ruim boven de
262.144-byte-limiet van de last-applied-annotatie. Client-side apply kán dus
niet meer. Geverifieerd vóór deze stap: `ServerSideApply=true` staat in
`argo/applications/argocd.yaml`, de live CRD heeft alleen de field managers
`argocd-controller` (Apply) en `kube-apiserver` (Update), en de
last-applied-annotatie is 0 bytes. De upstream-val van deze grens geldt hier
dus niet.

### Aandachtspunt bij de sync

**Dex gaat naar 2.45.0** — met `admin.enabled: "false"` betekent een kapotte Dex
géén UI, en dan is kubectl break-glass de enige weg terug. Verifieer de
SSO-login op admin.commonground.nu direct na de sync. De
`ContinueOnConnectorFailure`-default van 2.45 geldt ongewijzigd; er is geen
`argocd-cmd-params-cm`-patch.

### Verificatie

`scripts/verify.sh` groen (31 bestanden yaml-parse, kubeconform 13/13,
doc-assertion OK). Gevendord bestand byte-identiek aan de voorbereidingskopie
(sha256 `752b5a26…`). Sync door een mens.

## 2026-08-03 — Argo CD v3.1.16 → v3.2.12 (stap 2 van 4)

Stap 1 is gesynct en groen: alle componenten op v3.1.16 en Ready, app
Synced/Healthy op `9b0811c`, SSO werkte, en `argocd-redis` pullde met succes van
`public.ecr.aws` — daarmee is de onbekende uit stap 1 (nieuwe registry) opgelost
bewijs geworden voor de rest van de reeks.

- `argocd/upstream/install-v3.2.12.yaml` vervangt `install-v3.1.16.yaml`;
  `argocd/kustomization.yaml` en `docs/argocd.md` wijzen mee.

### Wat deze stap in het cluster doet (vooraf doorgerekend)

`kubectl diff -k argocd`: **943 regels over 11 objecten** — 6 Deployments, 1
StatefulSet, 2 CRD's, 1 ClusterRole, 1 Role.

- Images: argocd `v3.1.16` → `v3.2.12`, redis `7.2.11-alpine` →
  **`8.2.2-alpine`**. **Dex blijft `v2.43.0`** — geen SSO-risico in deze stap.
- Alle overige workload-wijzigingen zijn nieuwe env-vars en één configMap-volume,
  allemaal naar `argocd-cmd-params-cm`. Die ConfigMap bestaat, wordt door upstream
  meegeleverd, en het volume staat op `optional: true` — dus geen risico dat een
  pod niet start.

### Correctie op de eerdere planning: Redis 8.x zit hier, niet in stap 4

Bij het plannen is gemeld dat Redis pas in stap 4 naar 8.x zou gaan. Dat was
fout: de major-sprong **7.2 → 8.2 gebeurt in deze stap**. De eerste
inventarisatie miste het doordat het registry-pad van `redis:` naar
`public.ecr.aws/docker/library/redis:` wijzigde en het grep-patroon daar niet op
matchte. `docs/argocd.md` is gecorrigeerd.

Praktisch gevolg is klein — Redis is hier puur cache, dus een herstart kost
hoogstens een koude cache en geen data. Maar het verschuift wél waar je op let.

### RBAC gaat omlaag, niet omhoog

De `applicationset-controller` levert rechten **in**:

- weg: `deployments` get/list/watch (`apps` én `extensions`), `configmaps`
  create/delete/patch/update, en cluster-wijde `leases`
  delete/get/list/patch/update/watch;
- erbij: alleen `leases` create/get/update, **beperkt tot één resourceName**
  (`58ac56fa.applicationsets.argoproj.io`) voor leader-election.

Een brede lease-permissie wordt dus vervangen door één benoemde lease. De ruwe
`kubectl diff` ziet er door herordening van de rules-lijst rommeliger uit dan de
wijziging werkelijk is; bovenstaande komt uit een genormaliseerde
voor/na-vergelijking van de live ClusterRole tegen de render.

### Verificatie

`scripts/verify.sh` groen (31 bestanden yaml-parse, kubeconform 13/13, 
doc-assertion OK). Het gevendorde bestand is byte-identiek aan de kopie waarmee
de voorbereiding is gedaan (sha256 `1097a8e8…`). Sync door een mens.

## 2026-08-03 — Argo CD v3.0.6 → v3.1.16 (stap 1 van 4)

Eerste stap van de reeks naar v3.4.6, één minor per keer (besluit Mark
2026-08-03): **v3.1.16 → v3.2.12 → v3.3.13 → v3.4.6**. Upstream adviseert dat,
en de diff van het vendored bestand ís hier de review — vier minors in één diff
is niet te reviewen en bij een probleem niet te bisecten.

- `argocd/upstream/install-v3.1.16.yaml` vervangt `install-v3.0.6.yaml`;
  `argocd/kustomization.yaml` en `docs/argocd.md` wijzen mee.
- `docs/argocd.md`: de lopende reeks en de per-stap-bevindingen vastgelegd, zodat
  stap 2-4 niet opnieuw hoeven te worden uitgezocht.

### Wat deze stap in het cluster doet (vooraf doorgerekend)

`kubectl diff -k argocd`: **720 regels over 16 objecten** — 3 CRD's, 6
Deployments, 1 StatefulSet, 6 NetworkPolicies.

- Images: argocd `v3.0.6` → `v3.1.16`, dex `v2.41.1` → **`v2.43.0`**, redis
  `redis:7.2.7-alpine` → **`public.ecr.aws/docker/library/redis:7.2.11-alpine`**.
- De NetworkPolicies krijgen **alleen labels**, geen regelwijzigingen — dus geen
  connectiviteitsrisico.
- Alle nieuwe env-vars verwijzen naar `argocd-cmd-params-cm` met
  `optional: true`. Die ConfigMap patchen wij niet, dus het zijn no-ops en de
  upstream-defaults blijven gelden.

### Twee aandachtspunten bij de sync

- **SSO verifiëren ná deze sync.** Dex gaat hier al van 2.41.1 naar 2.43.0 — niet
  pas in de laatste stap, zoals eerst gedacht. Met `admin.enabled: "false"`
  betekent kapotte Dex géén UI; herstel loopt via kubectl break-glass.
- **Nieuwe registry.** Dit cluster pulde nog nooit van `public.ecr.aws`
  (geverifieerd: alleen docker.io, registry.k8s.io, quay.io,
  europe-docker.pkg.dev, ghcr.io, codeberg.org). Beide benodigde tags zijn
  anoniem bereikbaar (HTTP 200) en geen admission-policy beperkt registries, dus
  het restrisico is een pull-fout — direct zichtbaar als `ImagePullBackOff`.
  Upstream deed deze verhuizing juist om Docker Hub-rate-limits te ontlopen, wat
  voor deze anoniem pullende fleet gunstig is.

### Verificatie

`scripts/verify.sh` groen (31 bestanden yaml-parse, kubeconform 13/13 valid,
doc-assertion OK). De eigen patches botsen niet: `argocd-cm`, `argocd-rbac-cm` en
`argocd-ssh-known-hosts-cm` zijn upstream identiek in alle vier de releases. Het
gevendorde bestand is byte-identiek aan de kopie waarmee de droogloop is gedaan
(sha256 `e2f69ec0…`), dus die analyse geldt letterlijk voor deze commit.

Sync door een mens, handmatig — de Application heeft bewust geen
automated/selfHeal.

## 2026-07-13 — eigenaarschap → info@conduction.nl (review WP8)
- Alle `owner:`-front-matter en CODEOWNERS omgezet van `mark` naar
  `info@conduction.nl` (opvolging na 2026-08-31). Voorbereid op branch
  `chore/wp8-ownership`; review, merge en push door een mens.

## 2026-07-10

- **feat: Argo CD onder eigen beheer (`argocd/`)** — change `add-argocd-selfmanaged`
  (techbook). Argo CD v3.0.6 draaide als handmatige upstream-install; RBAC, SSO-config,
  ingress en de credential-refresh-CronJob (verse 24u-kubeconfigs voor de 3
  shoot-clusters via Gardener) waren onbeheerde clusterstate. Nu: vendored gepinde
  upstream + expliciet delta (kustomize), Application `argo/applications/argocd.yaml`
  (handmatige sync, geen prune/selfHeal, geen finalizer), docs/argocd.md (bootstrap-
  secrets, adoptievolgorde, upgrade-procedure, break-glass) en verify-uitbreiding
  (render + kubeconform + docs-claim). `kubectl diff -k argocd` toont uitsluitend de
  drie gedocumenteerde, ongevaarlijke afwijkingen die de bootstrap-apply (fase 3, mens)
  wegneemt. Security-finding onderweg: het Keycloak OIDC-clientSecret stond inline in
  argocd-cm — in git vervangen door een `$argocd-oidc-keycloak:clientSecret`-verwijzing;
  rotatie na adoptie (stap 4 in docs/argocd.md). Het cluster is niet aangeraakt.

- **feat: fuse-device-plugin also advertises `squat.ai/tun`** (`/dev/net/tun`, count 20,
  same pools). Needed by the con-ci-oci runner: rootless podman ≥5 sets up per-workflow job
  networks with **pasta**, which creates a tap device and fails without `/dev/net/tun`
  ("Failed to open() /dev/net/tun" on the first real `container:` job, 2026-07-04). Same
  design as fuse: device-plugin injection so consumers stay unprivileged — no hostPath, no
  extra caps. Consumer change (requesting `squat.ai/tun: 1`) lands in the `talos` repo.

## 2026-07-01

- **feat: podman-rootless Localhost seccomp profile installer** — new `seccomp-profiles`
  Argo app.
  - `seccomp-profiles/podman-rootless.json` — podman's own default seccomp profile
    (containers/common), which permits `clone`/`clone3`/`unshare`/`setns` unconditionally
    (the containerd RuntimeDefault profile gates those behind CAP_SYS_ADMIN).
  - `seccomp-profiles/installer-daemonset.yaml` — DaemonSet (kube-system, pool
    `worker-0b1p9-1`) that copies the profile to `/var/lib/kubelet/seccomp/podman-rootless.json`
    on each node and stays running (re-places on node roll). Runs as root only to write the
    root-owned hostPath; **not** privileged. Delivered via kustomize configMapGenerator
    (content-hashed name → editing the profile rolls the installer).
  - `argo/applications/seccomp-profiles.yaml` — new Application (auto-detects kustomize),
    syncs to `kube-system`.
  - Lets talos `con-ci-oci` (rootless podman) create user namespaces under baseline
    PodSecurity (which forbids seccomp `Unconfined` but allows `Localhost`).
  - **Bootstrap (one-time):** `kubectl apply -f argo/applications/seccomp-profiles.yaml`.

- **feat: fuse device-plugin (extended resource `squat.ai/fuse`)** — new `fuse-device-plugin`
  Argo app.
  - `fuse-device-plugin/daemonset.yaml` — squat/generic-device-plugin DaemonSet in
    `kube-system`, fuse-only (`--domain=squat.ai --device …/dev/fuse…`, count 20). Runs
    **privileged** with host `/dev` to enumerate devices + register with kubelet; consumer
    pods stay unprivileged. Image pinned by index digest
    (`ghcr.io/squat/generic-device-plugin@sha256:dc192e16…`, tag `latest` @ 2026-07-01).
  - **Scoped to node-pool `worker.gardener.cloud/pool: worker-0b1p9-1`** (where con-ci runs)
    to keep the privileged /dev DaemonSet off the nextcloud/data pools.
  - `argo/applications/fuse-device-plugin.yaml` — new Application, syncs to `kube-system`.
  - Unblocks talos `con-ci-oci` (overlay + fuse-overlayfs instead of vfs) and `runner-build`
    (rootless buildah), which both request `squat.ai/fuse: "1"`.
  - **No AppProject change:** `kube-system` destination already whitelisted (storage uses it);
    a DaemonSet is namespaced, so no clusterResourceWhitelist entry needed.
  - **Bootstrap (one-time):** `kubectl apply -f argo/applications/fuse-device-plugin.yaml`,
    then ArgoCD auto-syncs.

## 2026-06-30

- **feat: DNS-01 wildcard cert for openwoo.app + reflector** (cert-manager-config + reflector Argo apps).
  - `cert-manager/clusterissuer-letsencrypt-dns.yaml` — new `letsencrypt-dns` ClusterIssuer
    using the **DNS-01 Cloudflare solver** (HTTP-01 can't issue wildcards). Reuses the
    existing Cloudflare token (`cloudflare-credentials/api-token`, Zone:DNS:Edit on
    openwoo.app) — but cert-manager reads DNS-01 secrets from its OWN namespace, so the
    secret must be bootstrapped into `cert-manager` (see Bootstrap below). Same ACME
    account email as `letsencrypt-prod` (robert@conduction.nl).
  - `cert-manager/wildcard-openwoo-certificate.yaml` — ONE wildcard `Certificate`
    (`*.openwoo.app` + `*.accept.openwoo.app`) → Secret `wildcard-openwoo-tls`. Replaces
    per-tenant HTTP-01 issuance for WOO frontends and removes the 50-certs/week/registered-
    domain pressure entirely. `secretTemplate` annotations tell reflector to replicate it.
  - `reflector/` + `argo/applications/reflector.yaml` — emberstack/reflector replicates the
    wildcard Secret into WOO tenant namespaces (regex `.*-(accept|prod|test|demo)`), so each
    frontend Ingress can reference one shared cert. **Chart version `7.1.288` is a placeholder
    — VERIFY against the chart repo before first sync.**
  - **AppProject widened** (`argo/projects/cluster-infra.yaml`): + sourceRepo
    `https://emberstack.github.io/helm-charts`, + destination ns `reflector`,
    + clusterResourceWhitelist `cert-manager.io/ClusterIssuer`.
  - **Caveat:** the Cloudflare token needs **Zone:Read** in addition to DNS:Edit (DNS-01 does
    a zone lookup) — verify the token scope.
  - **Bootstrap (one-time, manual):** create `cloudflare-credentials` in the `cert-manager`
    namespace (same token external-dns uses), then `kubectl apply` the AppProject + the
    reflector and cert-manager-config Applications.

## 2026-06-22

- **feat: install External Secrets Operator** (`argo/applications/external-secrets.yaml` + `external-secrets/values.yaml`).
  - Cluster-wide ESO controller + CRDs via the `external-secrets/external-secrets` Helm chart, same pattern as `external-dns` (upstream chart + this repo's values, `installCRDs: true`, `ServerSideApply=true` for the large CRDs).
  - Rationale: ESO is a cluster capability (like cert-manager / external-dns), not an app-platform concern — consumers (`ClusterSecretStore` / `ExternalSecret`) live in the platform repos (e.g. Nextcloud-base `platform/externalsecrets/`).
  - Chart `targetRevision` pinned to **`2.6.0`** (== appVersion `v2.6.0`; verified 2026-06-22
    against the chart index at `charts.external-secrets.io`). The earlier `0.10.5` pin was
    stale. **Breaking:** the 2.x major dropped the served `external-secrets.io/v1beta1` API
    (only `v1` is served now) — Nextcloud-base consumers were moved to `external-secrets.io/v1`
    in the same window. `generators.external-secrets.io/v1alpha1` (ClusterGenerator) unchanged.
  - **AppProject `cluster-infra` widened** (`argo/projects/cluster-infra.yaml`) so the app can
    sync: added sourceRepo `https://charts.external-secrets.io`, destination namespace
    `external-secrets`, and cluster resources `Validating`/`MutatingWebhookConfiguration`
    (the chart's webhook). Without this the app fails `InvalidSpecError` (repo/destination
    not permitted) and installs nothing.
  - Deploy in the platform sync window; Nextcloud-base's ESO consumers depend on these CRDs being present first.

## 2026-06-03

- **chore: migrate Argo source GitHub → Codeberg**
  - GitHub org `ConductionNL` is shadowbanned; cluster access broken (`external-dns`, `storage` apps `SYNC=Unknown`).
  - `repoURL` `https://github.com/ConductionNL/cluster-infra.git` → `https://codeberg.org/Conduction/cluster-infra.git` in `argo/projects/cluster-infra.yaml`, `argo/applications/external-dns.yaml`, `argo/applications/storage.yaml`.
  - Public HTTPS, no credentials needed. Repo mirrored to Codeberg; GitHub kept for rollback.

## 2026-04-15

- **feat: add openwoo.app and opencatalogi.nl to External DNS domain filters**
  - `external-dns/values.yaml`: added both domains to `domainFilters`
  - `docs/CLOUDFLARE.md`: updated token instructions to cover all three zones
  - `CLAUDE.md`: updated domain filter documentation
  - Cloudflare API token replaced with a combined token covering all three zones
  - Secret `cloudflare-credentials` in namespace `external-dns` updated on cluster
