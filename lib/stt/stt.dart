// Whisper runs through FFI, so the real implementation is io-only;
// web builds get inert stubs
export 'stt_stub.dart' if (dart.library.io) 'stt_io.dart';
