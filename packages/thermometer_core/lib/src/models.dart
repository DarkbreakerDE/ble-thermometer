enum SessionMode {
  transferAndDisconnect('transfer_and_disconnect'),
  stayConnected('stay_connected');

  const SessionMode(this.wireName);
  final String wireName;
}

enum TemperatureUnit { celsius, fahrenheit }

class DesiredSettings {
  const DesiredSettings({
    required this.unit,
    required this.sound,
    required this.vibration,
  });
  final TemperatureUnit unit;
  final bool sound;
  final bool vibration;
  Map<String, Object> toJson() => {
    'unit': unit.name,
    'sound': sound,
    'vibration': vibration,
  };
}

class ThermometerSettings extends DesiredSettings {
  const ThermometerSettings({
    required super.unit,
    required super.sound,
    required super.vibration,
    required this.rawFlags,
  });
  factory ThermometerSettings.fromJson(Map<String, dynamic> json) =>
      ThermometerSettings(
        unit: TemperatureUnit.values.byName(json['unit'] as String),
        sound: json['sound'] as bool,
        vibration: json['vibration'] as bool,
        rawFlags: json['raw_flags'] as int,
      );
  final int rawFlags;
}

/// Device-local calendar fields, with no inferred UTC offset.
class MeasurementTime {
  MeasurementTime.fromJson(Map<String, dynamic> json)
    : year = json['year'] as int,
      month = json['month'] as int,
      day = json['day'] as int,
      hour = json['hour'] as int,
      minute = json['minute'] as int,
      second = json['second'] as int;
  final int year, month, day, hour, minute, second;
}

class Measurement {
  Measurement.fromJson(Map<String, dynamic> json)
    : temperature = (json['temperature'] as num).toDouble(),
      mantissa = json['mantissa'] as int,
      exponent = json['exponent'] as int,
      unit = TemperatureUnit.values.byName(json['unit'] as String),
      time = MeasurementTime.fromJson(json['time'] as Map<String, dynamic>),
      temperatureType = json['temperature_type'] as int,
      raw = List<int>.unmodifiable(json['raw'] as List),
      currentSettings = ThermometerSettings.fromJson(
        json['current_settings'] as Map<String, dynamic>,
      );
  final double temperature;
  final int mantissa, exponent, temperatureType;
  final TemperatureUnit unit;
  final MeasurementTime time;
  final List<int> raw;

  /// Current transfer settings, not settings used when the reading was taken.
  final ThermometerSettings currentSettings;
}

class MeasurementTransfer {
  MeasurementTransfer.fromJson(Map<String, dynamic> json)
    : measurements = List<Measurement>.unmodifiable(
        (json['measurements'] as List).map(
          (m) => Measurement.fromJson(m as Map<String, dynamic>),
        ),
      ),
      currentSettings = ThermometerSettings.fromJson(
        json['current_settings'] as Map<String, dynamic>,
      ),
      batteryPercent = json['battery_percent'] as int,
      reportedCount = json['reported_count'] as int;
  final List<Measurement> measurements;
  final ThermometerSettings currentSettings;
  final int batteryPercent, reportedCount;
}

class SettingsChange {
  SettingsChange.fromJson(Map<String, dynamic> json)
    : settings = ThermometerSettings.fromJson(
        json['settings'] as Map<String, dynamic>,
      ),
      changed = json['changed'] as bool,
      blinkCommandAccepted = json['blink_confirmed'] as bool;
  final ThermometerSettings settings;
  final bool changed;

  /// Confirms the ACK write; the LED itself cannot be observed over BLE.
  final bool blinkCommandAccepted;
}

class ThermometerException implements Exception {
  const ThermometerException(this.kind, this.message);
  final String kind, message;
  @override
  String toString() => 'ThermometerException($kind): $message';
}

class GattCharacteristic {
  const GattCharacteristic(this.serviceId, this.characteristicId);
  factory GattCharacteristic.fromJson(Map<String, dynamic> json) =>
      GattCharacteristic(
        json['service_id'] as String,
        json['characteristic_id'] as String,
      );
  final String serviceId, characteristicId;
  Map<String, Object> toJson() => {
    'service_id': serviceId,
    'characteristic_id': characteristicId,
  };
  @override
  bool operator ==(Object other) =>
      other is GattCharacteristic &&
      serviceId == other.serviceId &&
      characteristicId == other.characteristicId;
  @override
  int get hashCode => Object.hash(serviceId, characteristicId);
}
