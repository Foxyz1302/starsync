import 'dart:io';
import 'dart:typed_data';

abstract class MediaSource {
  Future<int> get size;
  String get displayName;
  Future<Uint8List> read(int start, int length);
  Future<void> close();
}

class FileMediaSource implements MediaSource {  final File file;
  RandomAccessFile? _handle;

  FileMediaSource(this.file);

  @override
  String get displayName => file.path.split(Platform.pathSeparator).last;

  @override
  Future<int> get size async => file.length();

  @override
  Future<Uint8List> read(int start, int length) async {
    _handle ??= await file.open();
    await _handle!.setPosition(start);
    return _handle!.read(length);
  }

  @override
  Future<void> close() async {
    await _handle?.close();
    _handle = null;
  }
}

class RangeRequest {
  final int start;
  final int? end;
  final int size;
  const RangeRequest({required this.start, required this.end, required this.size});

  int get contentLength => (end ?? (size - 1)) - start + 1;

  String get contentRange => 'bytes $start-${end ?? size - 1}/$size';

  static RangeRequest? parse(String? header, int size) {
    if (header == null || header.isEmpty) return null;
    final value = header.trim();
    if (!value.startsWith('bytes=')) return null;
    final spec = value.substring(6);
    if (spec.startsWith('-')) {
      final suffix = int.tryParse(spec.substring(1));
      if (suffix == null || suffix <= 0) return null;
      final start = (size - suffix).clamp(0, size);
      return RangeRequest(start: start, end: null, size: size);
    }
    final parts = spec.split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0].trim());
    if (start == null || start < 0 || start >= size) return null;
    if (parts[1].trim().isEmpty) return RangeRequest(start: start, end: null, size: size);
    final end = int.tryParse(parts[1].trim());
    if (end == null || end < start) return null;
    return RangeRequest(start: start, end: end.clamp(0, size - 1), size: size);
  }
}

String contentTypeForFile(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot).toLowerCase();
  switch (ext) {
    case '.mkv':
      return 'video/x-matroska';
    case '.mp4':
    case '.m4v':
      return 'video/mp4';
    case '.webm':
      return 'video/webm';
    case '.avi':
      return 'video/x-msvideo';
    case '.mov':
      return 'video/quicktime';
    case '.ts':
      return 'video/mp2t';
    case '.mp3':
      return 'audio/mpeg';
    case '.mka':
      return 'audio/x-matroska';
    default:
      return 'application/octet-stream';
  }
}
