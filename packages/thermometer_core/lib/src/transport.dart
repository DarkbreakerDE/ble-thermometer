import 'models.dart';

sealed class TransportEvent {}

class GattValue extends TransportEvent {
  GattValue(this.characteristic, List<int> data)
    : data = List<int>.unmodifiable(data);
  final GattCharacteristic characteristic;
  final List<int> data;
}

class TransportDisconnected extends TransportEvent {
  TransportDisconnected(this.reason);
  final String reason;
}

class SubscriptionFailed extends TransportEvent {
  SubscriptionFailed(this.reason);
  final String reason;
}

/// All BLE operations live outside Rust. A transport belongs to one session.
abstract interface class BleTransport {
  Stream<TransportEvent> get events;
  Future<void> connect(List<GattCharacteristic> discoveryProfile);
  Future<List<int>> read(GattCharacteristic characteristic);
  Future<void> write(GattCharacteristic characteristic, List<int> data);

  /// Installs a listener. Some BLE SDKs cannot confirm the remote CCCD write.
  Future<void> subscribe(GattCharacteristic characteristic);
  Future<void> disconnect();
}
