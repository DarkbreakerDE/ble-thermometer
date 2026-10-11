# Beobachtetes Ovy OT35 BLE-Protokoll

Diese Beschreibung fasst beobachtete Aufzeichnungen und Gerätetests zusammen.
Sie enthält keine Kopplungsschlüssel, persönliche Geräteadresse oder echte
Messhistorie. Verhalten anderer Firmwareversionen ist nicht geprüft.

## Pairing und Verbindung

Beobachtet wurde LE Legacy Pairing mit Passkey Entry und Bonding. Das Gerät
meldet DisplayOnly; ein KeyboardDisplay-Client kann den angezeigten Code
entgegennehmen. Secure Connections wurde im untersuchten Pairing nicht
ausgehandelt. BlueZ soll Pairing und Schlüsselverwaltung übernehmen.

Die BLE-Verbindung blieb für mindestens zwölf Minuten nutzbar. Einstellungen
und Speicherabrufe funktionieren über dieselbe Verbindung. Neue körperliche
Messungen ließen sich im getesteten Übertragungszustand erst nach Aus- und
Einschalten des Thermometers starten; alleiniger Disconnect genügte nach
Nutzerbeobachtung nicht. Ein Hostbefehl zum Messstart ist nicht bekannt.

## GATT

16-Bit-UUIDs verwenden die Basis `0000xxxx-0000-1000-8000-00805f9b34fb`.
Handles sind beobachtete Werte, keine garantierte Schnittstelle; im Client
Characteristics per UUID entdecken. Effektive beobachtete ATT-MTU: 23.

| Service | Characteristic | Value-Handle | Eigenschaften | Bedeutung |
| --- | --- | --- | --- | --- |
| 180f | 2a19 | 0029 | Read, Notify | Batterie, ein Byte in Prozent |
| 1805 | 2a2b | 002d | Read, Write, Notify | Current Time, zehn Bytes |
| fff0 | fff1 | 0031 | Indicate | gespeicherte Messungen |
| fff0 | fff2 | 0034 | Indicate | Anzahl/Abschluss, ein Byte |
| fff0 | fff3 | 0037 | Write | Kontrollwerte |
| fff0 | fff4 | 0039 | Read, Write, Notify | Einheit und Einstellungsbits |

CCCD: Batterie `002a`, Messungen `0032`, Anzahl `0035`. `01 00` aktiviert
Notifications; `02 00` aktiviert Indications. BlueZ bestätigt ATT-Indications
selbst. Das ist getrennt vom proprietären Write `fff3=01`.

Aktuelle Wireshark-UUID-Namen für fff0–fff4 können irreführend sein. Für
dieses Gerät die numerischen UUIDs und tatsächlichen Nutzdaten verwenden.

## Speicherabruf

1. Verbinden und Services entdecken.
2. fff1 und danach fff2 für Indications abonnieren.
3. Der erste vollständige Transfer beginnt im beobachteten Ablauf automatisch.
4. Messpakete auf fff1 sammeln; fff2 meldet anschließend deren Anzahl.
5. Bei weiterhin aktiven Abonnements `02` als ein Byte an fff3 schreiben,
   um einen weiteren vollständigen Transfer auszulösen.

Wiederabrufe per `02` wurden mehrfach in derselben Verbindung und über
mehrere Verbindungen bestätigt. Erneutes StopNotify/StartNotify allein löste
keinen Wiederabruf aus. Ein gezielter Abruf nach Index/Datum ist unbekannt;
einzelne Messwerte können auf dem Host aus dem vollständigen Transfer gewählt
werden. Transfers nacheinander ausführen; überlappende Writes sind nicht geprüft.

| FFF3-Wert | Beobachtung |
| --- | --- |
| `00` | angenommen; kein LED-Blinken, kein Wiederabruf; genaue Funktion unbekannt |
| `01` | zweimaliges LED-Blinken, danach wieder Dauerleuchten; kein Wiederabruf |
| `02` | zweimaliges LED-Blinken und vollständiger Wiederabruf bei aktiven Abonnements |

Vor und nach `00`/`01` leuchtet die Verbindungsleuchte dauerhaft. Die genaue
Funktion von `01` bleibt unbekannt; der Testername `ack` ist eine Arbeitshypothese.
Im getesteten Ablauf löschen `00` und `01` die vorhandenen Messungen nicht.
Ohne Abonnements kann aus fehlenden Indications keine interne Wirkungslosigkeit
eines Writes abgeleitet werden.

## Einstellungen auf FFF4

Zwei Bytes schreiben: `[Einheit, Flags]`.

- Einheit: `00` Celsius, `01` Fahrenheit.
- Flags Bit 0 (`01`): Vibration.
- Flags Bit 1 (`02`): Signalton.
- Flags Bit 2 (`04`): angenommen und zurückgelesen, keine offensichtliche
  Wirkung im Verbindungsmodus; Funktion und Neustartpersistenz unbekannt.
- Weitere Bits wurden nicht getestet.

Beispiel `00 03`: Celsius, Ton und Vibration an. Die bekannten Einstellungen
wurden nach einem Neustart sowohl zurückgelesen als auch physisch bestätigt.
Experimentell geschriebenes `00 04` anschließend auf einen bekannten Zustand
zurücksetzen. Schreiben/Zurücklesen allein belegt keine physische Funktion.

Die Einheit bestimmt auch die Ausgabe bereits gespeicherter Messungen.
Einheitenwechsel und Wiederabruf per `02` funktionieren in derselben
Verbindung. Zeitstempel und Messanzahl bleiben gleich. C/F-Versionen nicht
als neue Messungen zählen; Geräteidentität und Zeitstempel zur Zuordnung
verwenden. Mehrere Messungen mit identischem Sekundenzeitstempel sind nicht
untersucht. Die exakte C/F-Rundungsimplementierung ist nicht bekannt.

## Messformat auf FFF1

Beobachtet wurden 13 Bytes, entsprechend dem Aufbau der Bluetooth Temperature
Measurement Characteristic, hier jedoch unter proprietärer UUID fff1.

| Offset | Länge | Bedeutung |
| --- | --- | --- |
| 0 | 1 | Flags `06` Celsius, `07` Fahrenheit; Zeit und Typ vorhanden |
| 1 | 3 | signierte 24-Bit-Mantisse, little endian |
| 4 | 1 | signierter Dezimalexponent, beobachtet `fe` = −2 |
| 5 | 2 | Jahr, little endian |
| 7 | 1 | Monat |
| 8 | 1 | Tag |
| 9 | 1 | Stunde |
| 10 | 1 | Minute |
| 11 | 1 | Sekunde |
| 12 | 1 | Temperaturtyp, beobachtet `06` |

Temperatur = Mantisse × 10^Exponent. Das ist ein IEEE 11073 FLOAT, kein
IEEE-754-Float. Typ `06` ist standardseitig Mund; die tatsächliche
Messposition des Nutzers lässt sich daraus nicht ermitteln. Gerätezeitstempel
haben keine Zeitzone. Rohdaten und Einheit für Rundungs-/Zeitprüfungen erhalten.

## Current Time

Beobachtetes Format: Jahr LE16, Monat, Tag, Stunde, Minute, Sekunde,
Wochentag (1=Montag bis 7=Sonntag), Fractions256, AdjustReason.
Die App schreibt Datum und Uhrzeit. Die vollständige Auswertung aller Felder
durch die Firmware wurde nicht separat getestet; der Live-Tester synchronisiert
die Uhr nicht automatisch.

## Standardreferenzen

- [Bluetooth SIG Health Thermometer Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HTS_v1.0/out/en/index-en.html)
- [Bluetooth SIG Current Time Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/CTS_v1.0/out/en/index-en.html)
- [Bluetooth SIG Security Manager](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host/security-manager-specification.html)
- [BlueZ GATT-API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.GattCharacteristic.rst)
