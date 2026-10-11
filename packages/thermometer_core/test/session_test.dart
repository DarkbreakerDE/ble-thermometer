import 'dart:async';
import 'package:test/test.dart';
import 'package:thermometer_core/thermometer_core.dart';

GattCharacteristic c(String short) => GattCharacteristic(
  '0000${short == '2a19'
      ? '180f'
      : short == '2a2b'
      ? '1805'
      : 'fff0'}-0000-1000-8000-00805f9b34fb',
  '0000$short-0000-1000-8000-00805f9b34fb',
);

class FakeBle implements BleTransport {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final writes = <List<int>>[];
  final writtenCharacteristics = <GattCharacteristic>[];
  List<GattCharacteristic> discovery = [];
  bool failClock = false, neverClock = false, disconnectClock = false;
  List<int> settings = [0, 3];
  bool connected = false, sendBatch = true, failAck = false, loseLink = false;
  bool neverConnect = false;
  int disconnects = 0;
  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  Future<void> connect(List<GattCharacteristic> discoveryProfile) async {
    if (neverConnect) await Completer<void>().future;
    connected = true;
    discovery = discoveryProfile;
  }

  @override
  Future<List<int>> read(GattCharacteristic characteristic) async {
    if (!connected) throw StateError('disconnected');
    return characteristic == c('fff4') ? List.of(settings) : [80];
  }

  void batch() {
    if (!sendBatch) return;
    if (loseLink) {
      controller.add(TransportDisconnected('simulated loss'));
      return;
    }
    final packet = settings[0] == 0
        ? [6, 0x74, 0x0e, 0, 0xfe, 0xe8, 7, 2, 29, 12, 34, 56, 6]
        : [7, 0x28, 0x26, 0, 0xfe, 0xe8, 7, 2, 29, 12, 34, 56, 6];
    // Events deliberately arrive before subscribe/write futures complete.
    controller.add(GattValue(c('fff1'), packet));
    controller.add(GattValue(c('fff2'), [1]));
  }

  @override
  Future<void> subscribe(GattCharacteristic characteristic) async {
    if (characteristic == c('fff2')) batch();
  }

  @override
  Future<void> write(GattCharacteristic characteristic, List<int> data) async {
    writes.add(List.of(data));
    writtenCharacteristics.add(characteristic);
    if (characteristic == c('2a2b')) {
      if (failClock) throw StateError('Clock write rejected');
      if (neverClock) await Completer<void>().future;
      if (disconnectClock) {
        controller.add(TransportDisconnected('clock link lost'));
      }
    }
    if (characteristic == c('fff4')) settings = List.of(data);
    if (characteristic == c('fff3') && data[0] == 2) batch();
    if (characteristic == c('fff3') && data[0] == 1 && failAck) {
      throw StateError('ACK rejected');
    }
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    connected = false;
  }
}

Future<ThermometerSession> session(
  FakeBle ble,
  SessionMode mode, {
  Duration timeout = const Duration(seconds: 2),
}) async => ThermometerSession(
  transport: ble,
  protocol: await RustProtocolSession.create(mode: mode),
  mode: mode,
  commandTimeout: timeout,
  transferTimeout: timeout,
);

void main() {
  test('clock sync uses local fields, exact CTS bytes and ACK', () async {
    final ble = FakeBle();
    final s = await session(ble, SessionMode.stayConnected);
    await s.start();
    expect(ble.discovery, contains(c('2a2b')));
    final result = await s.syncClock(
      time: DateTime(2024, 2, 29, 12, 34, 56, 500),
    );
    expect(ble.writtenCharacteristics, [c('2a2b'), c('fff3')]);
    expect(ble.writes, [
      [0xe8, 7, 2, 29, 12, 34, 56, 4, 128, 1],
      [1],
    ]);
    expect(result.blinkCommandAccepted, isTrue);
    expect(result.requestedTime.localTime.hour, 12);
    expect(result.requestedTime.microsecond, 500000);
    expect(s.state, 'ready');
    await s.fetch();
    await s.dispose();
    await ble.controller.close();
  });
  test(
    'startup clock sync preserves batch result in both session modes',
    () async {
      for (final mode in SessionMode.values) {
        final ble = FakeBle();
        final s = await session(ble, mode);
        final clockEvent = s.clockSynchronizations.first;
        final batch = await s.start(
          synchronizeClockTo: DateTime(2024, 2, 29, 12, 34, 56),
        );
        expect(batch.reportedCount, 1);
        expect((await clockEvent).requestedTime.localTime.year, 2024);
        expect(ble.writes, [
          [0xe8, 7, 2, 29, 12, 34, 56, 4, 0, 1],
          [1],
        ]);
        expect(ble.connected, mode == SessionMode.stayConnected);
        await s.dispose();
        await ble.controller.close();
      }
    },
  );
  test('UTC input is converted to local calendar fields', () {
    final utc = DateTime.utc(2024, 2, 29, 12, 34, 56, 999, 999);
    final local = utc.toLocal();
    final clock = DeviceClockTime.fromDateTime(utc);
    expect(clock.localTime.hour, local.hour);
    expect(clock.localTime.day, local.day);
    expect(clock.microsecond, 999999);
    expect(
      () => DeviceClockTime.fromDateTime(DateTime(1500)),
      throwsArgumentError,
    );
  });
  test('rejected clock write disconnects and sends no ACK', () async {
    final ble = FakeBle()..failClock = true;
    final s = await session(ble, SessionMode.stayConnected);
    await s.start();
    await expectLater(
      s.syncClock(),
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'transport'),
      ),
    );
    await s.close();
    expect(ble.writtenCharacteristics, [c('2a2b')]);
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
  test('clock ACK failure describes partial success', () async {
    final ble = FakeBle()..failAck = true;
    final s = await session(ble, SessionMode.stayConnected);
    await s.start();
    await expectLater(
      s.syncClock(),
      throwsA(
        isA<ThermometerException>().having(
          (e) => e.message,
          'message',
          contains('Clock write was accepted'),
        ),
      ),
    );
    await s.close();
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
  test('clock write timeout cleans up without ACK', () async {
    final ble = FakeBle()..neverClock = true;
    final s = await session(
      ble,
      SessionMode.stayConnected,
      timeout: const Duration(milliseconds: 30),
    );
    await s.start();
    await expectLater(
      s.syncClock(),
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'timeout'),
      ),
    );
    await s.close();
    expect(ble.writtenCharacteristics, [c('2a2b')]);
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
  test(
    'disconnect during clock write cancels operation and permits restart',
    () async {
      final ble = FakeBle()..disconnectClock = true;
      final s = await session(ble, SessionMode.stayConnected);
      await s.start();
      await expectLater(
        s.syncClock(),
        throwsA(
          isA<ThermometerException>().having(
            (e) => e.kind,
            'kind',
            'disconnected',
          ),
        ),
      );
      await s.close();
      expect(ble.writtenCharacteristics, [c('2a2b')]);
      ble.disconnectClock = false;
      await s.start();
      await s.syncClock();
      await s.dispose();
      await ble.controller.close();
    },
  );

  test(
    'native bridge: transfer includes settings and disconnects before return',
    () async {
      final ble = FakeBle();
      final s = await session(ble, SessionMode.transferAndDisconnect);
      final batch = await s.start();
      expect(batch.measurements.single.temperature, 37);
      expect(batch.currentSettings.sound, isTrue);
      expect(batch.measurements.single.currentSettings.vibration, isTrue);
      expect(batch.measurements.single.time.year, 2024);
      expect(ble.connected, isFalse);
      expect(s.state, 'disconnected');
      await s.dispose();
      await ble.controller.close();
    },
  );
  test(
    'stay connected: setting verification then ACK and repeatable Fahrenheit fetch',
    () async {
      final ble = FakeBle();
      final s = await session(ble, SessionMode.stayConnected);
      await s.start();
      expect(ble.connected, isTrue);
      final change = await s.changeSettings(
        const DesiredSettings(
          unit: TemperatureUnit.fahrenheit,
          sound: false,
          vibration: true,
        ),
      );
      expect(change.changed, isTrue);
      expect(change.blinkCommandAccepted, isTrue);
      expect(ble.writes, [
        [1, 1],
        [1],
      ]);
      final batch = await s.fetch();
      expect(batch.measurements.single.unit, TemperatureUnit.fahrenheit);
      expect(batch.currentSettings.sound, isFalse);
      expect(ble.writes.last, [2]);
      await s.fetch();
      expect(ble.writes.last, [2]);
      final unchanged = await s.changeSettings(
        const DesiredSettings(
          unit: TemperatureUnit.fahrenheit,
          sound: false,
          vibration: true,
        ),
      );
      expect(unchanged.changed, isFalse);
      expect(ble.writes.length, 4);
      await s.dispose();
      expect(ble.connected, isFalse);
      await ble.controller.close();
    },
  );
  test('ACK failure reports already applied settings and cleans up', () async {
    final ble = FakeBle()..failAck = true;
    final s = await session(ble, SessionMode.stayConnected);
    await s.start();
    await expectLater(
      s.changeSettings(
        const DesiredSettings(
          unit: TemperatureUnit.celsius,
          sound: false,
          vibration: false,
        ),
      ),
      throwsA(
        isA<ThermometerException>().having(
          (e) => e.message,
          'message',
          contains('applied and verified'),
        ),
      ),
    );
    await s.close();
    expect(ble.settings, [0, 0]);
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
  test('incomplete transfer times out and disconnects', () async {
    final ble = FakeBle()..sendBatch = false;
    final s = await session(
      ble,
      SessionMode.stayConnected,
      timeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      s.start(),
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'timeout'),
      ),
    );
    await s.close();
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
  test('unexpected disconnect cleans up and allows restart', () async {
    final ble = FakeBle()..loseLink = true;
    final s = await session(ble, SessionMode.stayConnected);
    await expectLater(
      s.start(),
      throwsA(
        isA<ThermometerException>().having(
          (e) => e.kind,
          'kind',
          'disconnected',
        ),
      ),
    );
    await s.close();
    expect(ble.connected, isFalse);
    ble.loseLink = false;
    expect((await s.start()).reportedCount, 1);
    await s.dispose();
    await ble.controller.close();
  });
  test('connect timeout closes the transport', () async {
    final ble = FakeBle()..neverConnect = true;
    final s = await session(
      ble,
      SessionMode.stayConnected,
      timeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      s.start(),
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'timeout'),
      ),
    );
    await s.close();
    expect(ble.disconnects, greaterThan(0));
    await s.dispose();
    await ble.controller.close();
  });
  test('busy and explicit close cancel pending transfer', () async {
    final ble = FakeBle()..sendBatch = false;
    final s = await session(ble, SessionMode.stayConnected);
    final started = s.start();
    final cancelled = expectLater(
      started,
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'cancelled'),
      ),
    );
    await expectLater(
      s.fetch(),
      throwsA(
        isA<ThermometerException>().having((e) => e.kind, 'kind', 'busy'),
      ),
    );
    await s.close();
    await cancelled;
    expect(ble.connected, isFalse);
    await s.dispose();
    await ble.controller.close();
  });
}
