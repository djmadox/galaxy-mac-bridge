# Galaxy ↔ Mac Bridge

> Oberoende open-source-prototyp med arbetsnamnet MacDroid. Projektet är inte
> kopplat till Samsung, Google, Apple, LocalSend eller den kommersiella produkten
> MacDroid från Electronic Team.

MacDroid kopplar en Samsung Galaxy till macOS för aviseringsspegling, SMS,
samtalsgenvägar och lokal filöverföring. Produkten är **local-first**: dator och
telefon hittar varandra på det lokala nätverket och nyttolasten är
end-to-end-krypterad.

Projektet är en prototyp. Läs [integritetspolicyn](PRIVACY.md),
[säkerhetspolicyn](SECURITY.md) och [hotmodellen](docs/SECURITY.md) före användning
med känsliga data.

## Status

- Körbar macOS-menyradsapp med glansig, transparent panel.
- Bonjour-upptäckt och riktig TCP-transport på port 53318.
- X25519-parning med sexsiffrig verifiering och AES-256-GCM.
- Persistenta identiteter i macOS Keychain och Android Keystore-skyddad lagring.
- Inbyggd dubbelriktad, strömmad filöverföring med AES-256-GCM,
  SHA-256-verifiering och säker avbrytning.
- Android-klient med NSD-upptäckt, aviseringslyssnare, SMS-läsning/sändning och
  fjärrstart av samtal.
- Valfri Bluetooth HFP-anslutning för att ringa, svara och lägga på från Macen.
- Swift och Kotlin verifieras mot samma RFC 7748-testvektor.

## Kör Mac-prototypen

```sh
./scripts/build-macos-app.sh
open .build/app/MacDroid.app
```

MacDroid visas som en ikon i macOS menyrad. Klicka på den för grön telefon,
blå SMS-knapp och inställningar.

Testa kärnan:

```sh
swift test
```

Android-projektet ligger i `android/`. SDK:n kopplas via den lokala, ignorerade
filen `android/local.properties`. Bygg en debug-APK med:

```sh
./android/gradlew -p android assembleDebug
```

APK:n skapas i `android/app/build/outputs/apk/debug/app-debug.apk`.

## Parkoppla

1. Kör `swift run MacDroid` och öppna MacDroid-ikonen i menyraden.
2. Installera debug-APK:n på telefonen och ge endast de behörigheter du vill använda.
3. Tryck **Starta säker anslutning** på telefonen. Macen hittas automatiskt via Bonjour/NSD.
4. Öppna kugghjulet på Macen. Kontrollera att den sexsiffriga koden är identisk.
5. Tryck **Koderna matchar** på båda enheterna.

Efter bekräftelsen begär Macen en SMS-snapshot och nya aviseringar skickas live.
Telefon och Mac måste vara på samma lokala nätverk. Första gången kan macOS fråga
om åtkomst till lokalt nätverk och brandväg.

## Samtal

Android ger inte tredjepartsappar tillgång till ljudet från ett pågående
mobilnätssamtal. `CAPTURE_AUDIO_OUTPUT` är reserverad för systemappar. MacDroid
försöker därför aldrig fånga ljudet i Android-appen.

- **Ring via Galaxy:** Macen skickar en autentiserad samtalsbegäran; telefonen
  startar samtalet och behåller ljudet.
- **Bluetooth-samtal:** efter separat Bluetooth-parkoppling använder Macen HFP:s
  kontrollkanal för uppringning, svar, avslut och samtalsstatus. Appen återansluter
  till den redan parkopplade telefonen vid start.

På den testade MacBooken med macOS 15.7.9 fungerar HFP-kontrollen, men systemet
returnerar `kIOReturnUnsupported` för den publika SCO-ljudkanalen och skapar ingen
CoreAudio-enhet. Samtalsljudet stannar därför på telefonen. MacDroid använder
inte privata API:er eller osäkra ljudfångstmetoder för att kringgå detta.

En annan ansluten handsfree-enhet, exempelvis en Galaxy Watch, kan göra att
telefonen nekar kontrollanslutningen. MacDroid kopplar inte från sådana enheter
automatiskt.

Se [arkitekturen](docs/ARCHITECTURE.md) och [hotmodellen](docs/SECURITY.md).

## Filöverföring

Filöverföringen är inbyggd i MacDroid på båda enheterna. Ingen separat app,
adress, port eller PIN behöver anges. Välj filer antingen på Macen eller i steg 5
i Android-appen. Filer strömmas i 256 KiB stora krypterade delar över den redan
verifierade MacDroid-kanalen och kontrolleras med SHA-256 hos mottagaren. De blir
synliga först när hela filen har verifierats och sparas under
`Hämtade filer/MacDroid` på mottagaren. Avbrytning, frånkoppling och avslutning
raderar ofullständiga filer.

## Avsluta helt

- På Android: tryck **Stoppa och avsluta**, använd **Stoppa** i den pågående
  systemaviseringen eller svep bort appen. Bryggan har ingen automatisk omstart.
- På Mac: öppna kugghjulet och välj **Avsluta MacDroid**.

När bryggan är aktiv visar Android alltid en foreground-avisering och Macen en
menyradsikon. Efter uttryckligt avslut finns ingen synkroniseringstjänst kvar i
bakgrunden.
