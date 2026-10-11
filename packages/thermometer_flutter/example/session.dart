import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:thermometer_flutter/thermometer_flutter.dart';

/// Call after permissions, Bluetooth readiness and user-selected discovery.
Future<MeasurementTransfer> readOnce(
  FlutterReactiveBle ble,
  String deviceId,
) async {
  final mode = SessionMode.transferAndDisconnect;
  final transport = ReactiveBleTransport(ble: ble, deviceId: deviceId);
  final session = ThermometerSession(
    transport: transport,
    protocol: await RustProtocolSession.create(mode: mode),
    mode: mode,
  );
  try {
    // Optional explicit clock synchronization in this mode before the batch:
    // return await session.start(synchronizeClockTo: DateTime.now());
    return await session.start();
  } finally {
    await session.dispose();
    await transport.dispose();
  }
}

Future<void> configureAndRead(FlutterReactiveBle ble, String deviceId) async {
  final mode = SessionMode.stayConnected;
  final transport = ReactiveBleTransport(ble: ble, deviceId: deviceId);
  final session = ThermometerSession(
    transport: transport,
    protocol: await RustProtocolSession.create(mode: mode),
    mode: mode,
  );
  try {
    final initial = await session.start();
    await session.syncClock(); // local time write followed by blink ACK
    await session.changeSettings(
      DesiredSettings(
        unit: initial.currentSettings.unit,
        sound: false,
        vibration: true,
      ),
    ); // verified write followed by blink ACK
    final refreshed = await session.fetch(); // FFF3=02; settings included
    for (final reading in refreshed.measurements) {
      // Store/display reading.temperature, reading.unit and device-local time.
      // Do not treat reading.currentSettings as historical measurement metadata.
      consumeReading(reading);
    }
  } finally {
    await session.dispose();
    await transport.dispose();
  }
}

void consumeReading(Measurement reading) {
  /* Host application storage/UI. */
}
