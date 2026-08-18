---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# Standaardmail — IPv6 voor een klantdomein

Voor een hostnaam op een domein dat de klant zelf beheert (`open.<gemeente>.nl`,
`verwerkingsregister.<gemeente>.nl`, enzovoort). Hostnamen onder `*.openwoo.app`
hebben deze mail **niet** nodig; die regelen wij zelf, zie
`mail-ipv6-support.md`.

Vervang alleen `[hostnaam]`, `[naam]` en `[afzender]`. De DCV-bestemming is per
zone vast en staat hieronder al ingevuld.

**Vooraf, bij ons:** de hostnaam als custom hostname toevoegen in Cloudflare
(SSL/TLS → Custom Hostnames, Cloudflare-managed, minimum TLS 1.2, validatie TXT).
Doe dat vóór je de mail stuurt, anders kan de validatie niet slagen.

**Stap 2 pas versturen** nadat de edge gemeten is:

    CF_API_TOKEN=... ./scripts/cf-verify.sh          # hostname op "active"?
    EDGE_IP=<cf-ip> ./scripts/check-saas-hostname.sh [hostnaam]

Niet in deze mail zetten: geen CAA-verzoek (zonder CAA is er geen beperking; en
zetten ze er toch een, dan moeten `letsencrypt.org`, `pki.goog` én `ssl.com`
erin, want de CA wordt door het platform gekozen en kan wisselen) en geen
DANE-belofte.

---

Aan: [naam]
Onderwerp: IPv6 voor [hostnaam] — DNS-wijziging in twee stappen

Beste [naam],

Om de bevinding over IPv6 op te lossen laten we [hostnaam] via ons CDN lopen. De
site is daarmee over IPv6 bereikbaar en de zone blijft bij jullie in beheer. We
doen het in twee stappen, zodat er in stap 1 nog niets verschuift.

## Stap 1 — nu: één CNAME voor certificaatvalidatie

    _acme-challenge.[hostnaam].  CNAME  [hostnaam].7f19f08d5865daf8.dcv.cloudflare.com.

Hiermee kan het certificaat voor jullie hostnaam worden uitgegeven en daarna
automatisch worden vernieuwd, zonder dat jullie er elke keer iets voor hoeven te
doen. Dit record moet dus blijven staan.

Er verandert in deze stap niets voor bezoekers: het verkeer loopt nog precies
zoals nu.

## Stap 2 — later: het verkeer omzetten

Als wij hebben gecontroleerd dat alles klaarstaat, vragen we jullie het A-record
te vervangen door:

    [hostnaam].  CNAME  saas.openwoo.app.

Dat is het moment dat het verkeer verschuift. Terugdraaien kan altijd door het
oorspronkelijke A-record terug te zetten.

## Belangrijk: alleen die CNAME, geen A- of AAAA-record

Het A-record vervalt en er komt **geen** A- of AAAA-record naast de CNAME. Ook
niet een AAAA met een adres van ons: ons platform is IPv4-only, de
IPv6-bereikbaarheid komt van het CDN. Voor een naam met een CNAME mag er
volgens de DNS-standaard ook niets anders naast staan, dus een achtergebleven
A-record levert onvoorspelbaar gedrag op.

Kort samengevat wat er onder [hostnaam] hoort te staan:

    [hostnaam].                  CNAME  saas.openwoo.app.        (in plaats van het A-record)
    _acme-challenge.[hostnaam].  CNAME  [hostnaam].7f19f08d5865daf8.dcv.cloudflare.com.

## Verwerkingsafspraak

Het verkeer loopt na stap 2 via Cloudflare, dat de versleuteling beëindigt. Daar
hoort aan jullie kant een verwerkersafspraak bij.

## DANE/TLSA

Die bevinding kunnen we langs deze weg niet oplossen en ons advies is om dat ook
niet te doen. Geen enkele browser controleert DANE voor websites, terwijl het
record bij elke certificaatvernieuwing zou moeten meebewegen — en die vernieuwing
is bij ons geautomatiseerd terwijl het DNS bij jullie staat. Wij stellen voor deze
bevinding als bewust niet-ingericht af te sluiten.

Laat weten wanneer stap 1 gezet is, dan controleren wij het direct.

Met vriendelijke groet,

[afzender]
Conduction
