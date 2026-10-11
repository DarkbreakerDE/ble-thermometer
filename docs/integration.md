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

## Sources for platform APIs

The adapter follows the [flutter_reactive_ble package documentation](https://pub.dev/packages/flutter_reactive_ble)
and [API reference](https://pub.dev/documentation/flutter_reactive_ble/latest/flutter_reactive_ble/FlutterReactiveBle-class.html).
Native Assets uses [flutter_rust_bridge hooks](https://pub.dev/packages/flutter_rust_bridge_hooks)
and [native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust).
