# Säkerhets- och integritetsmodell

## Skyddsmål

- Endast uttryckligen parkopplade enheter får läsa eller styra data.
- En angripare på samma Wi-Fi ska varken kunna läsa, ändra eller spela upp trafik.
- Ett stulet relay-system ska inte kunna dekryptera användardata.
- En förlorad telefon eller Mac ska kunna spärras från den andra enheten.
- Känsliga Android-aviseringar ska vara dolda som standard.

## Kontroller

- X25519-nyckelutbyte med manuell sexsiffrig SAS-verifiering.
- HKDF-SHA-256 för separata sessionsnycklar.
- AES-256-GCM med sekvensnummer som authenticated data.
- Privata nycklar i Keychain/Keystore, aldrig i loggar eller vanlig lagring.
- Ingen analysdata som innehåller telefonnummer, meddelandetext eller aviseringsinnehåll.
- Mac-appen håller SMS och aviseringar i minnet och skriver ingen egen
  meddelandedatabas till disk.
- Fildata använder samma verifierade AES-256-GCM-kanal som övrig synk och varje
  färdig fil verifieras med SHA-256 innan Android eller macOS gör den synlig.
- Avbrutna överföringar stängs och raderas hos mottagaren. Filnamn reduceras till
  en enda säker sökvägskomponent och befintliga filer skrivs inte över.
- Maxgränser gäller för nätverksramar, texter, filstorlek, filnamn och samtidiga
  överföringar. Telefonnummer normaliseras och USSD/MMI-/URI-syntax avvisas.
- Bonjour- och parkopplingserbjudanden använder generiska enhetsnamn så datorns
  personliga namn och telefonmodell inte exponeras före autentisering.
- Bluetooth-samtal kan bara ansluta till en redan parkopplad Galaxy-enhet. Den
  valda Bluetooth-adressen låses efter första valet för att undvika att appen
  byter till en annan parkopplad telefon med liknande namn.

## Behörighetsprincip

Varje funktion aktiveras separat. Aviseringsåtkomst innebär inte automatiskt
SMS-, samtals- eller kontaktåtkomst. Android-appen slutar läsa SMS om behörigheten
tas bort och visar alltid en pågående systemavisering medan bryggan är aktiv.
Tjänsten startar inte om efter ett stopp. Den uttryckliga avslutningsåtgärden
stoppar även aviseringslyssnaren; användaren måste starta bryggan igen för ny synk.

Aviseringar markerade `VISIBILITY_SECRET` överförs utan titel, text eller
åtgärder. Övriga aviseringar går endast över den parkopplade krypterade kanalen.

MacDroid begär inte `CAPTURE_AUDIO_OUTPUT`, mikrofonåtkomst, root, Accessibility
för ljudfångst eller privata Samsung-/macOS-API:er. HFP används enbart som en
parkopplad kontrollkanal; samtalsljudet stannar på telefonen. Bluetooth-länken har
sin egen parkopplings- och länkkryptering och ska inte beskrivas som samma end-to-
end-kryptering som MacDroids AES-GCM-kanal.

## Kända begränsningar

- De långlivade X25519-identitetsnycklarna ger autentiserade, unika
  sessionsnycklar med färska nonces men inte full forward secrecy. Inför en
  produktionslansering bör protokollet uppgraderas med autentiserade efemära
  X25519-nycklar och extern kryptogranskning.
- Någon användarfunktion för nyckelrotation eller **Glöm enhet** är ännu inte
  implementerad. Radering görs tills vidare genom att rensa appdata/Keychain.
- Androids aviseringsåtkomst är systemövergripande. Ett per-app-filter bör
  implementeras före bred distribution.

## Innan lansering

- Autentiserade efemära sessionsnycklar, nyckelrotation och **Glöm enhet**.
- Extern protokoll- och kryptogranskning.
- Android Network Security Config och Certificate Transparency för eventuella
  centrala tjänster.
- Threat-model-test för replay, downgrade, MITM och förlorad enhet.
- Fuzzning av alla inkommande längder, JSON-fält och filnamn.
- Fortsatt fuzzning och penetrationstest av filöverföringen.
- Google Play Permissions Declaration för SMS/call-log om dessa distribueras.
