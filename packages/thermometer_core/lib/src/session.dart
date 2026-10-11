import 'dart:async';
import 'models.dart';
import 'protocol.dart';
import 'transport.dart';

/// Serializes protocol input while allowing indications during pending writes.
class ThermometerSession {
  ThermometerSession({
    required this.transport,
    required this.protocol,
    required this.mode,
    this.commandTimeout = const Duration(seconds: 15),
    this.transferTimeout = const Duration(seconds: 30),
  }) {
    _subscription = transport.events.listen(
      _onTransportEvent,
      onError: (Object error) =>
          _enqueue({'type': 'disconnected', 'reason': '$error'}),
    );
  }
  final BleTransport transport;
  final ProtocolSession protocol;
  final SessionMode mode;
  final Duration commandTimeout, transferTimeout;
  final _transfers = StreamController<MeasurementTransfer>.broadcast();
  final _errors = StreamController<ThermometerException>.broadcast();
  final _states = StreamController<String>.broadcast();
  late final StreamSubscription<TransportEvent> _subscription;
  Future<void> _tail = Future.value();
  Completer<Object>? _operation;
  Completer<void>? _closing;
  MeasurementTransfer? _lastTransfer;
  Timer? _transferTimer;
  String _state = 'disconnected';
  bool _disposed = false;
  int _epoch = 0;

  String get state => _state;
  Stream<MeasurementTransfer> get transfers => _transfers.stream;
  Stream<ThermometerException> get errors => _errors.stream;
  Stream<String> get states => _states.stream;

  Future<MeasurementTransfer> start() =>
      _request<MeasurementTransfer>({'type': 'start'});
  Future<MeasurementTransfer> fetch() =>
      _request<MeasurementTransfer>({'type': 'fetch'});
  Future<SettingsChange> changeSettings(DesiredSettings settings) =>
      _request<SettingsChange>({
        'type': 'set_settings',
        'settings': settings.toJson(),
      });

  Future<T> _request<T>(Map<String, Object?> input) async {
    if (_disposed) throw StateError('Session disposed');
    if (_operation != null || _closing != null) {
      throw const ThermometerException('busy', 'Another operation is active');
    }
    final operation = Completer<Object>();
    _operation = operation;
    _lastTransfer = null;
    _enqueue(input);
    return await operation.future as T;
  }

  void _complete(Object value) {
    final operation = _operation;
    _operation = null;
    if (operation != null && !operation.isCompleted) operation.complete(value);
  }

  void _fail(ThermometerException error) {
    _errors.add(error);
    final operation = _operation;
    _operation = null;
    if (operation != null && !operation.isCompleted) {
      operation.completeError(error);
    }
  }

  void _onTransportEvent(TransportEvent event) {
    if (_disposed) return;
    switch (event) {
      case GattValue():
        _enqueue({
          'type': 'notification',
          'characteristic': event.characteristic.toJson(),
          'data': event.data,
        });
      case TransportDisconnected():
        _epoch++;
        _enqueue({'type': 'disconnected', 'reason': event.reason});
      case SubscriptionFailed():
        _fail(ThermometerException('transport', event.reason));
        _enqueue({'type': 'close'});
    }
  }

  void _enqueue(Map<String, Object?> input) {
    if (_disposed) return;
    _tail = _tail
        .then((_) async {
          if (_disposed) return;
          final output = await protocol.dispatch(input);
          _state = output['state'] as String;
          _states.add(_state);
          for (final raw in output['events'] as List) {
            final event = raw as Map<String, dynamic>;
            switch (event['type']) {
              case 'transfer_completed':
                final transfer = MeasurementTransfer.fromJson(
                  event['transfer'] as Map<String, dynamic>,
                );
                _transfers.add(transfer);
                if (mode == SessionMode.stayConnected) {
                  _complete(transfer);
                } else {
                  _lastTransfer = transfer;
                }
              case 'settings_changed':
                _complete(SettingsChange.fromJson(event));
              case 'error':
                _fail(
                  ThermometerException(
                    event['kind'] as String,
                    event['message'] as String,
                  ),
                );
            }
          }
          _transferTimer?.cancel();
          if (output['waiting_for_transfer'] == true) {
            _transferTimer = Timer(
              transferTimeout,
              () => _enqueue({'type': 'transfer_timeout'}),
            );
          }
          if (_state == 'disconnected' || _state == 'failed') {
            final transfer = _lastTransfer;
            _lastTransfer = null;
            if (_state == 'disconnected' && transfer != null) {
              _complete(transfer);
            }
            _closing?.complete();
            _closing = null;
          }
          for (final raw in output['commands'] as List) {
            unawaited(_execute(raw as Map<String, dynamic>));
          }
        })
        .catchError((Object error, StackTrace trace) async {
          _transferTimer?.cancel();
          _fail(ThermometerException('bridge', '$error'));
          _state = 'failed';
          _states.add(_state);
          _epoch++;
          try {
            await transport.disconnect().timeout(commandTimeout);
          } catch (_) {
            /* original error retained */
          }
          _closing?.complete();
          _closing = null;
        });
  }

  Future<void> _execute(Map<String, dynamic> command) async {
    final id = command['id'] as int;
    if (command['type'] == 'connect' || command['type'] == 'disconnect') {
      _epoch++;
    }
    final epoch = _epoch;
    try {
      final data = await _perform(command).timeout(commandTimeout);
      if (!_disposed && epoch == _epoch) {
        _enqueue({
          'type': 'command_result',
          'command_id': id,
          'data': data,
          'error': null,
        });
      }
    } on TimeoutException {
      if (!_disposed && epoch == _epoch) {
        _enqueue({'type': 'command_timeout', 'command_id': id});
      }
    } catch (error) {
      if (!_disposed && epoch == _epoch) {
        _enqueue({
          'type': 'command_result',
          'command_id': id,
          'error': '$error',
        });
      }
    }
  }

  Future<List<int>> _perform(Map<String, dynamic> command) async {
    switch (command['type']) {
      case 'connect':
        await transport.connect(
          (command['characteristics'] as List)
              .map(
                (c) => GattCharacteristic.fromJson(c as Map<String, dynamic>),
              )
              .toList(),
        );
      case 'read':
        return transport.read(
          GattCharacteristic.fromJson(
            command['characteristic'] as Map<String, dynamic>,
          ),
        );
      case 'write':
        await transport.write(
          GattCharacteristic.fromJson(
            command['characteristic'] as Map<String, dynamic>,
          ),
          List<int>.from(command['data'] as List),
        );
      case 'subscribe':
        await transport.subscribe(
          GattCharacteristic.fromJson(
            command['characteristic'] as Map<String, dynamic>,
          ),
        );
      case 'disconnect':
        await transport.disconnect();
      default:
        throw StateError('Unknown transport command ${command['type']}');
    }
    return const [];
  }

  Future<void> close() async {
    if (_disposed) return;
    if (_closing != null) return _closing!.future;
    if (_operation != null) {
      _fail(const ThermometerException('cancelled', 'Session closed'));
    }
    final closing = Completer<void>();
    _closing = closing;
    _enqueue({'type': 'close'});
    await closing.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    _epoch++;
    _transferTimer?.cancel();
    await _subscription.cancel();
    await _tail;
    await protocol.dispose();
    await _transfers.close();
    await _errors.close();
    await _states.close();
  }
}
