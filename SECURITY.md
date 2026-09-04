# Säkerhetspolicy

Projektet är en prototyp och ska granskas innan produktionsdistribution.

Rapportera sårbarheter privat via GitHub Security Advisories under repots flik
**Security → Advisories → New draft security advisory**. Lägg inte nycklar,
meddelanden, telefonnummer eller andra personuppgifter i en publik issue.

Rapporten bör innehålla påverkad version, reproduktionssteg och förväntad
säkerhetseffekt. Undvik att testa mot enheter eller data som du inte äger eller
har uttryckligt tillstånd att använda.

## Omfattning

- Parkoppling, nyckellagring och krypterad LAN-transport
- Aviserings- och SMS-behörigheter
- Samtalskommandon
- Filöverföring och filnamn
- WebKit-vyn för Google Messages

Kända designbegränsningar dokumenteras i `docs/SECURITY.md`.
