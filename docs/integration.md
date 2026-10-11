# Integrating with an Android/iOS Flutter application

Add a local path dependency on `packages/thermometer_flutter`. Use the Flutter
version selected by FVM. `thermometer_core` builds the native Rust library through
Flutter/Dart Native Assets; no separately maintained Kotlin/Swift BLE layer is
introduced. Native bootstrap resolves the bundled library path via `dladdr` on
Android/iOS and the Linux test host, then initializes flutter_rust_bridge.

The app owns Bluetooth permissions, Bluetooth power prompts, discovery UI and OS
pairing prompts. Wait for `FlutterReactiveBle.statusStream` to report `BleStatus.ready`
after permissions are granted. Stop the scan after selecting a device. Discovery
IDs are opaque: Android can return a MAC address, iOS a CoreBluetooth UUID. Do not
hardcode an address or match a device solely by an assumed advertised name.

## Android

Declare permissions in the host app's `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

Request the applicable runtime permissions before scanning or connecting.
`neverForLocation` is appropriate when the app does not use scans for physical
location; Android can filter some advertising packets under this flag. Older
Android devices may also require location services to be enabled for scanning.
Use a host minSdk of at least 23 and an installed NDK supporting the selected
Flutter version. The Rust hook selects the build ABI; configure the host's ABI
filters consistently with `rust-toolchain.toml`.

## iOS

Use iOS 13 or later and add a meaningful `NSBluetoothAlwaysUsageDescription` in
the host `Info.plist`. Run the build on macOS with Xcode and the selected Rust
Apple target. A BLE hardware test requires a physical device. The library makes
no promise of background operation; if the product requires background BLE,
configure CoreBluetooth background modes and test the OS lifecycle separately.

## Lifecycle and failures

Each `ReactiveBleTransport` belongs to a single `ThermometerSession`. Subscribe to
`session.errors` and `session.states` before starting. Await `start()`, `fetch()`
and `changeSettings()`, and handle `ThermometerException`. Concurrent requests are
rejected as busy. Dispose the session and then the transport on leaving the flow.
A failed setting ACK can occur after settings have already been applied; the
exception explicitly reports this and the connection is cleaned up.

The coordinator serializes Rust inputs while BLE operations run asynchronously,
so an indication received before its triggering write completes is retained.
Command timeouts and transfer inactivity timeouts cause cleanup. Stale command
completions are ignored. Unexpected disconnects cancel the active operation and
release subscriptions before the session can restart. Recovery requires an
explicit new `start()`; no hidden reconnect or pairing removal is attempted.

`flutter_reactive_ble` installs subscription listeners but does not expose a
remote CCCD-completion future. Listener installation is therefore not claimed as
confirmed CCCD readiness. Subscription stream failures and missing transfer
completion are surfaced through errors/timeouts. Initial FFF1/FFF2 subscription
starts a memory transfer on the tested device; subsequent fetches use FFF3=02.

The thermometer was observed to require a physical off/on cycle to start a new
measurement after transmission mode. Disconnecting BLE alone does not promise a
return to measurement mode. Pairing/passkey entry remains an OS/user interaction.

## Clock synchronization

`session.syncClock()` writes the current local time in an idle stay-connected
session. Pass `time: someDateTime` to supply a specific time. In either session
mode, `start(synchronizeClockTo: someDateTime)` synchronizes immediately after
connecting and before reading the stored measurement batch. Ordinary `start()`
does not write the clock. Listen to `clockSynchronizations` for successful clock
operations, including those performed during startup.

Dart converts UTC inputs to the host's local timezone and passes calendar fields
and microseconds within the second to Rust. Rust validates the calendar, computes
the Gregorian weekday (Monday=1, Sunday=7), and encodes ten bytes: year LE16,
month, day, hour, minute, second, weekday, Fractions256, AdjustReason. Fractions256
is truncated from microseconds; AdjustReason is `01`, matching the observed app
writes. The BLE transport writes with response to service `1805`, characteristic
`2A2B`. After a successful time write, Rust sends `FFF3=01` for the blink ACK.

`ClockSyncResult.requestedTime` is the requested local time, not a readback.
`blinkCommandAccepted` confirms the ACK write. A failed ACK can occur after the
clock write was already accepted; the exception reports this partial success.
Write failures, timeouts and disconnects clean up the connection. No readback
comparison, automatic resync or clock persistence guarantee is implemented.
Device-side use of Fractions256/AdjustReason still needs hardware verification.
The supplied time is captured at the call, so startup connection delay and
Bluetooth transport latency are not compensated. No UTC offset is transmitted.

The write and payload were observed in the original app's capture and align with
the [Bluetooth Current Time Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/CTS_v1.0/out/en/index-en.html).
Public tests use synthetic times rather than values copied from the private capture.

## Sources for platform APIs

The adapter follows the [flutter_reactive_ble package documentation](https://pub.dev/packages/flutter_reactive_ble)
and [API reference](https://pub.dev/documentation/flutter_reactive_ble/latest/flutter_reactive_ble/FlutterReactiveBle-class.html).
Native Assets uses [flutter_rust_bridge hooks](https://pub.dev/packages/flutter_rust_bridge_hooks)
and [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust).
