import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:thermometer_core/thermometer_core.dart';

/// Scanning is transport-side. IDs are opaque, including CoreBluetooth UUIDs.
Stream<DiscoveredDevice> scanThermometers(
  FlutterReactiveBle ble, {
  List<Uuid> withServices = const [],
}) => ble.scanForDevices(
  withServices: withServices,
  scanMode: ScanMode.lowLatency,
);

class ReactiveBleTransport implements BleTransport {
  ReactiveBleTransport({
    required this.ble,
    required this.deviceId,
    this.connectionTimeout = const Duration(seconds: 12),
  });
  final FlutterReactiveBle ble;
  final String deviceId;
  final Duration connectionTimeout;
  final _events = StreamController<TransportEvent>.broadcast();
  final Map<GattCharacteristic, StreamSubscription<List<int>>> _notifications =
      {};
  StreamSubscription<ConnectionStateUpdate>? _connection;
  Completer<void>? _connecting;
  bool _connected = false;
  int _generation = 0;
  @override
  Stream<TransportEvent> get events => _events.stream;

  QualifiedCharacteristic _qualified(GattCharacteristic c) =>
      QualifiedCharacteristic(
        serviceId: Uuid.parse(c.serviceId),
        characteristicId: Uuid.parse(c.characteristicId),
        deviceId: deviceId,
      );

  @override
  Future<void> connect(List<GattCharacteristic> discoveryProfile) async {
    if (_connection != null) {
      throw StateError('Transport already has a connection');
    }
    final generation = ++_generation;
    final ready = Completer<void>();
    var disconnectReported = false;
    _connecting = ready;
    final profile = <Uuid, List<Uuid>>{};
    for (final c in discoveryProfile) {
      profile
          .putIfAbsent(Uuid.parse(c.serviceId), () => [])
          .add(Uuid.parse(c.characteristicId));
    }
    _connection = ble
        .connectToDevice(
          id: deviceId,
          servicesWithCharacteristicsToDiscover: profile,
          connectionTimeout: connectionTimeout,
        )
        .listen(
          (update) {
            if (generation != _generation) {
              return;
            }
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                _connected = true;
                if (!ready.isCompleted) {
                  ready.complete();
                }
              case DeviceConnectionState.disconnected:
                if (disconnectReported) {
                  return;
                }
                disconnectReported = true;
                _connected = false;
                final reason = '${update.failure ?? 'BLE connection closed'}';
                if (!ready.isCompleted) {
                  ready.completeError(StateError(reason));
                }
                _events.add(TransportDisconnected(reason));
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object error) {
            if (generation != _generation) {
              return;
            }
            if (disconnectReported) {
              return;
            }
            disconnectReported = true;
            _connected = false;
            if (!ready.isCompleted) {
              ready.completeError(error);
            }
            _events.add(TransportDisconnected('$error'));
          },
          onDone: () {
            if (generation != _generation) {
              return;
            }
            if (disconnectReported) {
              return;
            }
            disconnectReported = true;
            _connected = false;
            if (!ready.isCompleted) {
              ready.completeError(StateError('BLE connection stream ended'));
            }
            _events.add(TransportDisconnected('BLE connection stream ended'));
          },
        );
    await ready.future;
    _connecting = null;
  }

  void _requireConnection() {
    if (!_connected) {
      throw StateError('BLE device disconnected');
    }
  }

  @override
  Future<List<int>> read(GattCharacteristic characteristic) {
    _requireConnection();
    return ble.readCharacteristic(_qualified(characteristic));
  }

  @override
  Future<void> write(GattCharacteristic characteristic, List<int> data) {
    _requireConnection();
    return ble.writeCharacteristicWithResponse(
      _qualified(characteristic),
      value: data,
    );
  }

  @override
  Future<void> subscribe(GattCharacteristic characteristic) async {
    _requireConnection();
    if (_notifications.containsKey(characteristic)) {
      return;
    }
    final generation = _generation;
    _notifications[characteristic] = ble
        .subscribeToCharacteristic(_qualified(characteristic))
        .listen(
          (data) {
            if (generation == _generation) {
              _events.add(GattValue(characteristic, data));
            }
          },
          onError: (Object error) {
            if (generation == _generation) {
              _events.add(SubscriptionFailed('$error'));
            }
          },
          onDone: () {
            if (generation == _generation && _connected) {
              _events.add(SubscriptionFailed('GATT subscription ended'));
            }
          },
        );
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    _connected = false;
    final connecting = _connecting;
    _connecting = null;
    if (connecting != null && !connecting.isCompleted) {
      connecting.completeError(StateError('Connection cancelled'));
    }
    final notifications = _notifications.values.toList();
    _notifications.clear();
    final connection = _connection;
    _connection = null;
    try {
      await Future.wait(notifications.map((s) => s.cancel()));
    } finally {
      await connection?.cancel();
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}
