import 'dart:convert';
import 'dart:ffi';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

// Native Assets resolves this symbol on Android, iOS and the Linux test host.
@Native<Pointer<Char> Function()>(symbol: 'thermometer_asset_path')
external Pointer<Char> _assetPath();

ExternalLibrary loadNativeLibrary() {
  final path = _assetPath();
  if (path == nullptr) {
    throw StateError('Cannot resolve bundled Rust library path');
  }
  final bytes = <int>[];
  final chars = path.cast<Uint8>();
  for (var i = 0; chars[i] != 0; i++) {
    bytes.add(chars[i]);
  }
  return ExternalLibrary.open(utf8.decode(bytes));
}
