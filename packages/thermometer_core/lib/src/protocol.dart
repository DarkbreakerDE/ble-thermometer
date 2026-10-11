import 'dart:convert';
import 'models.dart';
import 'native_library.dart';
import 'rust/api.dart' as api;
import 'rust/frb_generated.dart';

abstract interface class ProtocolSession {
  Future<Map<String, dynamic>> dispatch(Map<String, Object?> input);
  Future<void> dispose();
}

class RustProtocolSession implements ProtocolSession {
  RustProtocolSession._(this._id);
  final int _id;
  static Future<void>? _initialization;
  static Future<RustProtocolSession> create({
    String model = 'ovy_ot35',
    required SessionMode mode,
  }) async {
    await (_initialization ??= RustLib.init(
      externalLibrary: loadNativeLibrary(),
    ));
    return RustProtocolSession._(
      await api.createSession(model: model, mode: mode.wireName),
    );
  }

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, Object?> input) async =>
      jsonDecode(await api.dispatch(sessionId: _id, input: jsonEncode(input)))
          as Map<String, dynamic>;
  @override
  Future<void> dispose() => api.disposeSession(sessionId: _id);
}
