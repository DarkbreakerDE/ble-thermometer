# Ovy OT35 BLE reverse engineering

Experimentelle Linux-Werkzeuge und eine aus Bluetooth-Aufzeichnungen sowie
Gerätetests abgeleitete Protokollbeschreibung.

- [`docs/protocol.md`](docs/protocol.md): bisher bestätigte Funktionen und Grenzen.
- [`analyse/live_ovy.py`](analyse/live_ovy.py): interaktiver BlueZ-Tester.
- [`analyse/decode_ovy.py`](analyse/decode_ovy.py): Offline-Decoder für ATT-TSV.

## Linux-Tester

Benötigt BlueZ, Python 3, `python3-dbus` und `python3-gi`. Im normalen
Laptop-Terminal ausführen; Zugriff auf den System-D-Bus muss möglich sein.
Das Gerät vorher mit `bluetoothctl` und einem `KeyboardDisplay`-Agent koppeln.
Die Bluetooth-Adresse des eigenen Geräts lokal ermitteln.

```sh
python3 analyse/live_ovy.py --address "<MAC-DEINES-THERMOMETERS>"
```

Nach der ausgegebenen Meldung `ready` können Befehle eingegeben werden.
`ready` ist selbst kein Befehl.

```text
status
read 2a19
read fff4
fetch
```

`fetch` abonniert Messungen und Abschluss/Anzahl. Nach abgeschlossenem
Transfer startet `control 02` bei bestehenden Abonnements einen Wiederabruf.
`settings 0003` stellt Celsius mit Ton und Vibration ein. `quit` trennt die
Verbindung. Pairing-Schlüssel verwaltet BlueZ; der Tester koppelt nicht selbst.

Die experimentellen Writes `control 00` und `settings 0004` haben keine
zugeordnete Funktion; sie gehören nicht zum normalen Abrufablauf.

Logs werden standardmäßig lokal nach `analyse/live-ovy.jsonl` geschrieben.
Bugreports, Mitschnitte, Kopplungsdaten, Gerätekennungen und persönliche
Messdaten sind durch `.gitignore` vom vorgesehenen Commit ausgeschlossen.
Es werden keine persönlichen Beispieldaten mitgeliefert.

## Offline-Decoder

Die Standarddatei `analyse/att.tsv` ist eine lokale Eingabedatei und wird
nicht mitgeliefert. Sie kann beispielsweise mit Wireshark CLI erzeugt werden:

```sh
tshark -r <LOKALER-HCI-MITSCHNITT> -Y btatt -T fields -E header=y -E separator=/t \
  -e frame.number -e frame.time -e bthci_acl.chandle -e btatt.opcode \
  -e btatt.handle -e btatt.value -e _ws.col.Info > analyse/att.tsv
python3 analyse/decode_ovy.py
```

Der Decoder setzt die in der Protokollbeschreibung beobachteten Handles
voraus. Andere Geräte-/Firmwarevarianten können davon abweichen.

## Clock hardware test (tests branch)

The existing Linux tester supports `clock-test` using Python alone, with BlueZ,
`python3-dbus` and `python3-gi`. Rust, Cargo, Flutter and the library project are
not required. Copy `analyse/live_ovy.py` and `analyse/decode_ovy.py` together to
use the tester separately. The Python codec implements the observed ten-byte
Current Time format, followed by the known FFF3=01 blink command.

After `ready` is printed, enter `clock-test` (do not enter `ready` itself).
This explicitly sets the device clock to the laptop's local time. The tester reads
Current Time before writing and twice afterward, two seconds apart, checking the
weekday and a two-second tolerance. Observe the two LED flashes separately.
A successful write followed by a failed read does not restore the old clock.
Use `quit` to disconnect. To verify persistence, power-cycle the thermometer,
reconnect and use `read 2a2b` before issuing another `clock-test`. Actual
measurement timestamps after restart still require separate verification.

Real clock readbacks and logs remain ignored; do not add them to Git.

Sanitized hardware results: [clock test results](docs/clock-test-results.md).

## Datum gezielt schreiben und prüfen

Nach der Meldung `ready` eingeben:

```text
date-test
```

Der Tester wählt ein vom Geräte-Readback abweichendes Datum (normalerweise
morgen), schreibt Datum und Uhrzeit, sendet den Blinkbefehl und prüft zwei
Readbacks einschließlich Wochentag. Anschließend stellt er die aktuelle
Laptopzeit wieder her und prüft sie ebenfalls. Optional lässt sich das Testdatum
mit `date-test 2024-02-29` vorgeben. Ein identisches oder ungültiges Testdatum
wird vor dem Write abgelehnt. Währenddessen keine Messung starten.

Erfolg: `date_write_verified`, `clock_restore_verified`, `date_test_passed`.
Bei `clock_restore_failed` nach erneutem Verbinden `clock-test` ausführen,
bevor wieder gemessen wird. Der Test prüft keine Neustart-Persistenz.
Die Writes beim Test und bei der Wiederherstellung senden jeweils einen Blink-ACK.
