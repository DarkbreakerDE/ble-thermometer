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
