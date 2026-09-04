# Arkitektur

## Produktbeslut

MacDroid består av en liten menyradsapp för macOS och en companion-app för
Android. Telefonen är sanningskällan för aviseringar och SMS. Macen lagrar bara
det användaren behöver för snabb åtkomst och kan rensas vid frånkoppling.

```text
Samsung Galaxy                         MacBook
┌──────────────────┐              ┌──────────────────┐
│ Notification     │              │ Menyrad          │
│ Listener         │              │  lur / SMS / ⚙︎  │
├──────────────────┤  krypterad   ├──────────────────┤
│ SMS provider     │◄────────────►│ Minnesmodell     │
├──────────────────┤     TCP      ├──────────────────┤
│ Call state       │              │ Filväljare       │
├──────────────────┤              ├──────────────────┤
│ MediaStore       │◄────────────►│ Filström         │
├──────────────────┤     HFP      ├──────────────────┤
│ Bluetooth AG     │◄────────────►│ Samtalskontroll  │
└──────────────────┘              └──────────────────┘
```

## Anslutning och synk

1. Macen annonserar `_macdroid._tcp` via Bonjour på port 53318.
2. Android hittar tjänsten med NSD och öppnar en längdprefixad TCP-ström.
3. Enheterna utbyter enhets-ID, publik X25519-nyckel och färsk nonce.
4. Båda härleder samma X25519-hemlighet och visar en sexsiffrig SAS-kod.
5. Användaren bekräftar att koden är samma på båda skärmarna.
6. Långlivade enhetsnycklar lagras i macOS Keychain respektive Android
   Keystore. Varje anslutning får en unik sessionsnyckel via HKDF och färska
   nonces. Konstruktionen har ännu inte forward secrecy.
7. En monotont ökande sekvens ingår som autentiserad data i AES-256-GCM och
   stoppar replay eller omsorterade kommandon.

Primär transport är en ihållande längdprefixad TCP-ström på LAN. Internet krävs inte. Ett
framtida relay-läge får bara vidarebefordra redan end-to-end-krypterade paket
och får aldrig äga en dekrypteringsnyckel.

## SMS

Android läser konversationer från `Telephony.Sms.CONTENT_URI` efter ett tydligt
samtycke. Första synken är en begränsad snapshot; därefter skickas förändringar.
Macen sänder ett `smsSend` med ett unikt klient-ID. Telefonen skickar via
`SmsManager` och svarar med `sent` eller `failed`. Idempotent återförsök och
full leveranskvittens återstår före produktionslansering.

Google Play begränsar SMS-behörigheter. Cross-device synchronization är ett
uttryckligen dokumenterat undantag, men appen behöver en Permissions Declaration
och Play-granskning. Behörigheter ska inte begäras innan funktionen förklarats.

## Aviseringar

`NotificationListenerService` serialiserar titel, text, app, tid och tillåtna
åtgärder. Hemliga aviseringar skickas utan titel, innehåll eller åtgärder. Svar
använder Androids befintliga `RemoteInput`; MacDroid får inte skapa egna
rättigheter. Ett per-app-filter är planerat men ännu inte implementerat.

## Samtal

Utan Bluetooth skickar Macen ett autentiserat startkommando över MacDroid-
kanalen. Android öppnar eller startar samtalet efter beviljad `CALL_PHONE`-
behörighet och ljudet ligger kvar på telefonen. Inkommande och pågående samtal
speglas dessutom från Androids `TelephonyCallback` när Samsung Telefon inte
publicerar en vanlig avisering.

Som ett separat, valfritt läge använder Mac-appen Apples publika
`IOBluetoothHandsFreeDevice`. Endast en enhet som redan har parkopplats i macOS
kan väljas, och dess Bluetooth-adress koms ihåg efter första valet. HFP:s
servicekanal styr uppringning, svar och avslut samt levererar samtalsstatus.
Mobilnätssamtalet och SIM-kortet ligger fortfarande i telefonen.

Apples publika SCO-anrop har verifierats på målmaskinen med macOS 15.7.9 men
returnerar `kIOReturnUnsupported`; systemet skapar inte heller någon CoreAudio-
enhet för telefonen. Därför hålls ljudet på telefonen. Android-appen fångar inget
ljud och privata macOS-API:er används inte som kringgående lösning.

HFP återansluts vid appstart enbart till den redan parkopplade och ihågkomna
telefonen. Det finns även en uttrycklig återförsöksknapp, och appen faller tillbaka
till den befintliga Android-samtalsvägen när HFP inte är anslutet. Appen kopplar
inte automatiskt från klockor, hörlurar eller andra handsfree-enheter.

## Filöverföring

MacDroid behöver ingen extern filapp. Både Android och Mac kan skicka metadata
följt av 256 KiB stora delar över den parkopplade AES-256-GCM-kanalen. Android
skriver till en dold, väntande MediaStore-post och Macen till en privat `.part`-
fil under `Downloads/MacDroid`. Mottagaren kontrollerar ordning, utlovad storlek
och SHA-256 och gör filen synlig först efter godkänd verifiering. Befintliga filer
skrivs inte över. En krypterad avbrytningssignal, frånkoppling eller appavslutning
stänger filhandtaget och raderar den ofullständiga filen.

## Livscykel och avslutning

Android-bryggan är en synlig foreground-tjänst endast medan användaren har
startat den. Den använder `START_NOT_STICKY`, stoppas när aktiviteten tas bort och
har en Stoppa-åtgärd i systemaviseringen. Ett uttryckligt avslut kopplar även loss
`NotificationListenerService`. Macens Avsluta-åtgärd avbryter filjobb, stänger
TCP-listenern och den aktiva peer-anslutningen samt kopplar från HFP före
processterminering.

## Implementationsordning

1. LAN-transport, Bonjour och QR-parning.
2. Keychain/Keystore och återanslutning.
3. Aviseringar inklusive per-app-filter.
4. SMS snapshot, delta, sändstatus och idempotens.
5. Inbyggd strömmad filöverföring och MediaStore-mottagare.
6. Samtalsstart och inkommande samtalsnotis.
7. Bluetooth HFP-samtalskontroll; ljud ligger kvar på telefonen.
