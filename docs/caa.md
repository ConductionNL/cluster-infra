---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# CAA-records per zone

Een CAA-record zegt welke certificaatautoriteit mag uitgeven voor een naam. Wie
er één vergeet, breekt de vernieuwing van die CA — en dat merk je pas als het
certificaat verloopt. Vandaar de regel: **eerst meten wie er nu uitgeeft, dan
pas zetten.**

Meten doe je met `./scripts/caa-landscape.sh` (leest Certificate Transparency,
read-only). Het script meldt luidruchtig als de publieke API afknijpt; een
onvolledige meting mag niet als volledige lezen.

## Landschap (gemeten 2026-08-18)

| Zone | Let's Encrypt | Google Trust Services | Sectigo | DigiCert |
|---|---|---|---|---|
| `openwoo.app` | 36 hostnamen | apex + wildcard | apex + wildcard | — |
| `commonground.nu` | 184 hostnamen | apex + wildcard | 25 hostnamen | 2 hostnamen |
| `opencatalogi.nl` | 56 certificaten | 22 certificaten | — | — |
| `conduction.nl` | `demo.` (live gemeten) | apex + `www.` (live gemeten) | ? | ? |

Twee dingen die dit duidelijk maakt:

**Google Trust Services = Cloudflare.** Die verschijnt op apex en wildcard van de
geproxiede zones; dat is Universal SSL van de edge, niet iets van ons.

**Sectigo en DigiCert in `commonground.nu` zijn van derden.** Het zijn
`admin.*` en `api.*` hostnamen van VrijBRP- en tsplitsing-omgevingen, plus
`vrijbrp-noordenveld`. Een CAA die alleen Let's Encrypt toestaat, sloopt hun
vernieuwing. Dat is niet onze beslissing om te nemen.

`opencatalogi.nl` is dus schoon: alleen wij (Let's Encrypt) en de edge (Google
Trust Services). Daar kan een CAA op zoneniveau wél smal blijven:

    opencatalogi.nl.  CAA 0 issue "letsencrypt.org"
    opencatalogi.nl.  CAA 0 issue "pki.goog; cansignhttpexchanges=yes"

## Wat dat betekent voor de records

Per zone moeten álle actieve CA's erin, anders eerst de dienst verhuizen:

    openwoo.app.      CAA 0 issue "letsencrypt.org"
    openwoo.app.      CAA 0 issue "pki.goog; cansignhttpexchanges=yes"
    openwoo.app.      CAA 0 issue "sectigo.com"

    commonground.nu.  CAA 0 issue "letsencrypt.org"
    commonground.nu.  CAA 0 issue "pki.goog; cansignhttpexchanges=yes"
    commonground.nu.  CAA 0 issue "sectigo.com"
    commonground.nu.  CAA 0 issue "digicert.com"

Zo breed is een CAA op zoneniveau bijna geen beperking meer. De winst zit dan
ook niet op de zone maar **op de hostnaam**: een CAA op precies de host die wij
bedienen sluit alles uit wat wij niet gebruiken, zonder iemand anders te raken.
Dat is ook wat we een klant adviseren voor zijn eigen domein.

CAA werkt van de naam omhoog en stopt bij de eerste naam die een record heeft.
Een record op `<host>` overrulet dus de zone, en de zone raakt de host niet meer.

## Klantdomeinen

Voor een host op een klantdomein (bijvoorbeeld `open.dinkelland.nl`) blijft het
smal: `letsencrypt.org` voor ons origin-certificaat, plus
`pki.goog; cansignhttpexchanges=yes` en `ssl.com` zodra die host via
Cloudflare for SaaS loopt. Zie `cloudflare-ipv6.md`.

## Nog te doen

1. `conduction.nl` volledig meten. De CT-bronnen gaven vandaag geen antwoord
   (rate limit bij de één, time-out bij de ander); draai het script opnieuw.
   Live geprobeerd: apex en `www.` staan op Google Trust Services (dus geproxied),
   `demo.` op Let's Encrypt. Of er nog een derde CA in die zone actief is, weten
   we dus nog niet — en dat is precies wat je moet weten vóór je iets zet.
2. Uitzoeken van wie het Sectigo-certificaat op `openwoo.app` apex/wildcard is —
   de enige onbekende in een zone die wij bezitten.
3. Pas daarna records zetten. Begin bij `opencatalogi.nl`: die is smal en dus
   een echte beperking. Op `commonground.nu` eerst per hostnaam.
