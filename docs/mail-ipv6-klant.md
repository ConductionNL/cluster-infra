---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# Standaardmail — IPv6 voor een klantdomein

Template voor een hostnaam op een domein dat de klant zelf beheert (bijvoorbeeld
`open.<gemeente>.nl`). Vervang de blokhaken. Achtergrond: `cloudflare-ipv6.md`.

Twee stappen, bewust gescheiden: stap 1 verschuift geen verkeer, stap 2 wel. Zet
stap 2 pas in de mail nadat wij de edge hebben gemeten
(`check-saas-hostname.sh` met `EDGE_IP`).

Niet in deze mail zetten:

- **Geen CAA-verzoek.** Zonder CAA is er geen beperking en werkt de vernieuwing.
  Zetten ze er toch een, dan moeten `letsencrypt.org`, `pki.goog` én `ssl.com`
  erin — de certificaatautoriteit wordt door het platform gekozen en kan wisselen.
  Eén CA noemen breekt een latere vernieuwing.
- **Geen belofte over DANE.** Dat kan langs deze route niet; de alinea hieronder
  sluit die bevinding expliciet af.

---

Aan: [contactpersoon]
Onderwerp: IPv6 voor [hostnaam] — DNS-wijziging in twee stappen

Beste [naam],

Om de bevinding over IPv6 op te lossen laten we [hostnaam] via ons CDN lopen.
De site is daarmee over IPv6 bereikbaar en de zone blijft bij jullie in beheer.
We doen het in twee stappen, zodat er in stap 1 nog niets verschuift.

## Stap 1 — nu: één CNAME voor certificaatvalidatie

    _acme-challenge.[hostnaam].  CNAME  [hostnaam].[dcv-id].dcv.cloudflare.com.

Hiermee kan het certificaat voor jullie hostnaam worden uitgegeven en daarna
automatisch worden vernieuwd, zonder dat jullie er elke keer iets voor hoeven te
doen. Dit record moet dus blijven staan.

Er verandert in deze stap niets voor bezoekers: het verkeer loopt nog precies
zoals nu.

## Stap 2 — later: het verkeer omzetten

Als wij hebben gecontroleerd dat alles klaarstaat, vragen we jullie het
A-record te vervangen door:

    [hostnaam].  CNAME  saas.openwoo.app.

Dat is het moment dat het verkeer verschuift. Terugdraaien kan altijd door het
oorspronkelijke A-record terug te zetten.

## Verwerkingsafspraak

Het verkeer loopt na stap 2 via Cloudflare, dat de versleuteling beëindigt. Daar
hoort aan jullie kant een verwerkersafspraak bij.

## DANE/TLSA

Die bevinding kunnen we langs deze weg niet oplossen en ons advies is om dat ook
niet te doen. Geen enkele browser controleert DANE voor websites, terwijl het
record bij elke certificaatvernieuwing zou moeten meebewegen — en die
vernieuwing is bij ons geautomatiseerd terwijl het DNS bij jullie staat. Wij
stellen voor deze bevinding als bewust niet-ingericht af te sluiten.

Laat weten wanneer stap 1 gezet is, dan controleren wij het direct.

Met vriendelijke groet,

[afzender]
Conduction
