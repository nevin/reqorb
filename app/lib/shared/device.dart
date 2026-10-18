import 'package:flutter/services.dart';
import 'package:reqorb/src/rust/api/core.dart';

/// What the device has, where the platform says: on iPad, its memory and
/// the space free on its disk. Elsewhere each answer is null, and nothing
/// is held back for want of it.
abstract final class Device {
  static const _channel = MethodChannel('reqorb/device');

  /// Memory at or below this is a device short of it, such as an iPad
  /// Air 2 or a fifth-generation iPad, with 2 GB.
  static const lowMemory = 3 * 1024 * 1024 * 1024;

  /// How large a response is held in memory on such a device before it
  /// goes to a file, rather than 16 MB.
  static const lowMemorySpill = 8 * 1024 * 1024;

  /// How much memory the device has, in bytes.
  static Future<int?> physicalMemory() => _ask<int>('physicalMemory');

  /// How many bytes are free on the disk that holds [path].
  static Future<int?> freeSpace(String path) => _ask<int>('freeSpace', path);

  static Future<T?> _ask<T>(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<T>(method, argument);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// How large a response to hold in memory on a device with [memory]
  /// bytes of it; null to keep the engine's own size.
  static int? spillFor(int? memory) =>
      memory != null && memory <= lowMemory ? lowMemorySpill : null;

  /// Keeps less of a response in memory on a device short of memory.
  static Future<void> fitToMemory() async {
    if (spillFor(await physicalMemory()) case final bytes?) {
      setSpillBytes(bytes: bytes);
    }
  }
}

/// Why there is no room for about [bytes] more in the folder at [path],
/// to [what]; null when there is, or the platform does not say.
Future<String?> lackOfRoom(String path, int bytes, String what) async {
  final free = await Device.freeSpace(path);
  if (free == null || free >= bytes) return null;
  String mb(int n) => '${(n / (1024 * 1024)).ceil()} MB';
  return 'Not enough free space to $what: it needs about ${mb(bytes)}, '
      'and ${mb(free)} is free.';
}
