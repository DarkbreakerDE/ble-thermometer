# Bluetooth thermometer library (Flutter + Rust)

Android/iOS BLE transport with a transport-independent Rust protocol driver for
Ovy OT35. Unsupported device operations return an error rather than guessed writes.

- `crates/thermometer_protocol`: common driver trait, OT35 decoding and state machine.
- `packages/thermometer_core`: typed Dart API, asynchronous session coordinator,
  generated flutter_rust_bridge bindings and Native Assets build hook.
- `packages/thermometer_flutter`: scanning and GATT transport using flutter_reactive_ble.

`transferAndDisconnect` reads the stored batch with current settings and battery,
then disconnects BLE before resolving `start()`. The OS bond is retained.
`stayConnected` reads the initial batch and permits settings changes and repeated
`fetch()` calls without reconnecting. A real settings change follows read baseline,
write FFF4, verify FFF4, then write FFF3=01 to request the observed two LED flashes.
An unchanged setting sends neither a write nor an ACK. `blinkCommandAccepted`
confirms the GATT write, not visual observation of the LED.

Measurements carry current settings at transfer time, not historical settings.
Repeated fetches use the observed FFF3=02 command. Unknown settings bits are not
overwritten. Starting a measurement, deleting history and selecting a stored index
are not implemented. The thermometer may need a physical
off/on cycle to leave transmission mode and start a new measurement.

Clock synchronization uses the observed Current Time Service write to `1805/2A2B`:

```dart
await session.syncClock(); // current local time; requires stayConnected/ready
// Or synchronize before the first batch, in either session mode:
final batch = await session.start(synchronizeClockTo: DateTime.now());
```

The time write is followed by the blink ACK. Synchronization is opt-in; ordinary
`start()` leaves the clock unchanged. Results confirm accepted writes, not verified
clock accuracy or persistence. See [clock details](docs/integration.md#clock-synchronization).

## Setup

Consume `packages/thermometer_flutter` as a local path dependency from this
checkout. The Rust crates depend on the repository Cargo workspace, so keep
this directory structure. Publishing standalone packages requires adjusting
these Rust dependencies.

Flutter is pinned in `.fvmrc`; Rust in the bridge crate's `rust-toolchain.toml`.
Install Rust via rustup. Android requires an NDK; iOS builds require macOS/Xcode.
The native build hook builds and bundles the Rust library automatically.

```sh
fvm install
cd packages/thermometer_flutter
fvm flutter pub get
```

See [platform integration](docs/integration.md) for permissions and lifecycle
handling, and the [usage example](packages/thermometer_flutter/example/session.dart).
The app owns permission requests, discovery UI and OS pairing/passkey prompts.

## Validation and limits

The Rust protocol and Dart session coordinator were checked on Linux using
synthetic packets and the real native bridge. The Flutter BLE adapter passes
static analysis with its resolved dependencies. Android/iOS build and device
validation remain outstanding.

Unit and integration tests use synthetic packets and are included in this repository.
Run `cargo test --workspace` from the repository root and `fvm dart test` from
`packages/thermometer_core`. The generated bridge can be regenerated with
`flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml`
using codegen version 2.13.0 and an installed `cargo-expand`.

Analysis tools, protocol investigation records, private bugreports, pairing captures
and real measurement histories remain excluded from `main`. Private captures and
build caches are excluded by `.gitignore`.

## License

Licensed under the [MIT License](LICENSE). Third-party dependencies retain their
own licenses.

## Tools on the tests branch


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
