---
last_reviewed: 2026-08-22
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

**Haal daarna de eigendomsverificatie op**, want die waarde is per hostnaam
uniek en moet in stap 1 mee:

    CF_API_TOKEN=... ./scripts/cf-verify.sh --ownership <hostnaam>

Zonder dat record blijft de hostname op `pending` staan met de melding
`custom hostname does not CNAME to this zone`, en dan routeert de edge niet —
status 409. Het certificaat wordt wél uitgegeven, dus `ssl: active` met
`status: pending` is de normale tussenstand als je dit vergeet. Aantoonbaar
misgegaan bij Noaberkracht op 2026-08-19: stap 1 vroeg alleen de DCV-CNAME,
waarna de edge niet te meten was en stap 2 dus niet verstuurd kon worden.

**Stap 2 pas versturen** nadat de edge gemeten is:

    CF_API_TOKEN=... ./scripts/cf-verify.sh          # hostname op "active"?
    EDGE_IP=<cf-ip> ./scripts/check-saas-hostname.sh [hostnaam]

Niet in deze mail zetten: geen CAA-verzoek (zonder CAA is er geen beperking; en
zetten ze er toch een, dan moeten `letsencrypt.org`, `pki.goog` én `ssl.com`
erin, want de CA wordt door het platform gekozen en kan wisselen) en geen
DANE-belofte.

**Meerdere hostnamen in één mail** als het dezelfde beheerder is — zet de
records dan onder elkaar per hostnaam. Twee losse mails leveren twee losse
ronden op.

## Wat deze mail bewust wél bevat

Drie dingen die eruit zijn gesloopt tijdens de eerste uitrol (Noaberkracht,
augustus 2026) en er daarna weer in moesten, elk goed voor een extra ronde:

1. **De zelfcontrole met `nslookup`.** Zonder dat commando meldt een klant "het
   staat erin" terwijl het record niet is gepubliceerd, en gaat er een ronde
   heen en weer voordat iemand meet. Gebeurd op 2026-08-22 bij beide hostnamen
   van Noaberkracht: hun eigen nameserver gaf nog het A-record met TTL 300, dus
   het was geen cache maar een niet-opgeslagen wijziging.
2. **Verwijderen-dan-aanmaken.** Veel panelen laten het recordtype niet
   wijzigen. Wie dat niet weet, zet de CNAME náást het A-record — en dat is
   precies de configuratie die een site voor een deel van de bezoekers stuk
   maakt.
3. **Kort.** De eerste versie was drie schermen lang. Wat er niet in staat,
   wordt wél gelezen.

---

Aan: [naam]
Onderwerp: IPv6 voor [hostnaam] — DNS-wijziging in twee stappen

Beste [naam],

Om de IPv6-bevinding op te lossen laten we [hostnaam] via ons CDN lopen. De zone
blijft bij jullie. Twee stappen; in stap 1 verschuift er nog niets.

## Stap 1 — twee records toevoegen

    _acme-challenge.[hostnaam].       CNAME  [hostnaam].7f19f08d5865daf8.dcv.cloudflare.com.
    _cf-custom-hostname.[hostnaam].   TXT    [eigendomswaarde]

Het eerste zorgt dat het certificaat wordt uitgegeven en zich daarna vanzelf
vernieuwt; dat record blijft staan. Het tweede laat ons de route testen terwijl
het verkeer nog gewoon loopt.

Controleer zelf of ze staan, dan hoeven we daar niet over heen en weer:

    nslookup -type=TXT _cf-custom-hostname.[hostnaam] 1.1.1.1

Laat weten wanneer ze staan.

## Stap 2 — het A-record vervangen

Nadat wij stap 1 hebben gecontroleerd:

    [hostnaam].  CNAME  saas.openwoo.app.

**Vervangen, niet toevoegen.** Het A-record moet weg. Naast een CNAME mag
volgens de DNS-standaard niets anders op dezelfde naam staan — blijft het
A-record staan, dan is de site voor een deel van de bezoekers onbereikbaar.

Twee dingen die in de praktijk misgaan:

- In veel beheerpanelen kun je het type van een bestaand record niet wijzigen.
  Verwijder dan eerst het A-record en maak daarna de CNAME aan.
- Sommige panelen hebben een aparte knop om wijzigingen te publiceren. Zonder
  die klik is er niets veranderd, ook al ziet het scherm er goed uit.

Controleer daarom zelf voordat je het doorgeeft:

    nslookup -type=CNAME [hostnaam] 1.1.1.1

Staat er `saas.openwoo.app`, dan is het gelukt. Staat er nog een IP-adres, dan
is de wijziging niet opgeslagen of niet gepubliceerd.

Omdat wij in stap 1 al hebben getest, is er bij deze omzetting geen
onderbreking te verwachten. Terugdraaien kan altijd: CNAME weg, oorspronkelijk
A-record terug.

Er komt geen AAAA-record bij — dat verzorgt het CDN.

## Verwerkingsafspraak

Het verkeer loopt na stap 2 via Cloudflare, dat de versleuteling beëindigt. Daar
hoort aan jullie kant een verwerkersafspraak bij.

## DANE/TLSA

Die bevinding kunnen we langs deze weg niet oplossen en ons advies is om dat ook
niet te doen. Geen enkele browser controleert DANE voor websites, terwijl het
record bij elke certificaatvernieuwing zou moeten meebewegen — en die vernieuwing
is bij ons geautomatiseerd terwijl het DNS bij jullie staat. Wij stellen voor deze
bevinding als bewust niet-ingericht af te sluiten.

Laat weten wanneer de records staan, dan controleren wij het direct.

Met vriendelijke groet,

[afzender]
Conduction
