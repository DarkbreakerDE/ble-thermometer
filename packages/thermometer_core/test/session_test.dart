import 'dart:async';
import 'package:test/test.dart';
import 'package:thermometer_core/thermometer_core.dart';

GattCharacteristic c(String short) => GattCharacteristic(
  '0000${short == '2a19' ? '180f' : 'fff0'}-0000-1000-8000-00805f9b34fb',
  '0000$short-0000-1000-8000-00805f9b34fb',
);

class FakeBle implements BleTransport {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final writes = <List<int>>[];
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
