import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Direct Dart -> Rust boundary for portable identity/MLS operations.
///
/// Android's foreground service may use the same shared library through its
/// native background adapter while Flutter owns the public Dart API.
class TorchatFfi {
  TorchatFfi._();

  static final TorchatFfi instance = TorchatFfi._();
  ffi.DynamicLibrary? _library;
  bool _attemptedLoad = false;

  ffi.DynamicLibrary? get _lib {
    if (_attemptedLoad) return _library;
    _attemptedLoad = true;
    try {
      if (Platform.isAndroid) {
        _library = ffi.DynamicLibrary.open('libtorchat_core.so');
      } else if (Platform.isWindows) {
        _library = ffi.DynamicLibrary.open('torchat_core.dll');
      } else if (Platform.isLinux) {
        _library = ffi.DynamicLibrary.open('libtorchat_core.so');
      } else if (Platform.isMacOS || Platform.isIOS) {
        _library = ffi.DynamicLibrary.open('libtorchat_core.dylib');
      }
    } on Object {
      _library = null;
    }
    return _library;
  }

  bool get isAvailable => _lib != null;

  bool? validateContactInvite(String value) {
    final library = _lib;
    if (library == null) return null;
    final function = library.lookupFunction<_ValidateNative, _ValidateDart>(
      'torchat_validate_contact_invite',
    );
    final bytes = utf8.encode(value);
    final buffer = calloc<ffi.Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      return function(buffer, bytes.length) == 1;
    } finally {
      calloc.free(buffer);
    }
  }

  String? lastError() {
    final library = _lib;
    if (library == null) return null;
    final function = library.lookupFunction<_LastErrorNative, _LastErrorDart>(
      'torchat_last_error',
    );
    final pointer = function();
    if (pointer == ffi.nullptr) return null;
    final value = pointer.cast<Utf8>().toDartString();
    library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'torchat_free_string',
    )(pointer);
    return value;
  }
}

typedef _ValidateNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.UintPtr);
typedef _ValidateDart = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef _LastErrorNative = ffi.Pointer<ffi.Char> Function();
typedef _LastErrorDart = ffi.Pointer<ffi.Char> Function();
typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi.Char>);
