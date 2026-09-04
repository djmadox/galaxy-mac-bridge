# Integritet

Galaxy Mac Bridge är local-first och har ingen egen molntjänst eller analys-
SDK. Aviseringar, SMS och filer skickas direkt mellan enheter på det lokala
nätverket efter att användaren jämfört en sexsiffrig parkopplingskod.

## Data som behandlas

- Android-aviseringar som användaren har gett systemåtkomst till.
- SMS när den separata SMS-behörigheten har beviljats.
- Samtalsstatus och användarinitierade samtalskommandon.
- Filer som användaren uttryckligen väljer.
- Enhets-ID och publika parkopplingsnycklar.

Privata nycklar lagras lokalt i macOS Keychain respektive krypteras med en
icke-exporterbar nyckel i Android Keystore. Ingen meddelandetext, fil, kontakt,
telefonnummer eller privat nyckel ska skrivas till diagnostikloggar.

Google Messages-vyn är Googles webbplats i en separat WebKit-datalagring.
Inloggningsdata stannar lokalt och kan tas bort med **Rensa webbdata**.

## Behörigheter

Android-behörigheter aktiveras funktionsvis. Appen använder inte platsdata,
mikrofon, samtalsinspelning, annonserings-ID eller analysdata. Säkerhetskopiering
och enhetsöverföring av appens privata Android-data är avstängd.

## Källkod och byggartefakter

Publika Git-filer innehåller inga användardata. Lokala SDK-sökvägar,
parkopplingsdata, Keychain/Keystore-data, loggar, APK-filer och byggkataloger är
uteslutna från versionshantering.

## Bakgrundskörning

Android visar alltid en systemavisering när bryggan körs. **Stoppa och avsluta**
stoppar anslutningen, aktiva filöverföringar och aviseringslyssnaren utan
automatisk omstart. På macOS gör **Avsluta MacDroid** samma sak innan processen
avslutas. Ofullständiga mottagna filer raderas vid avbrott eller frånkoppling.
