import 'dart:ffi';

import 'package:ffi/ffi.dart';

// The few Win32 calls the app makes itself (no package wraps them for
// us without a new dependency). Only ever called on Windows.

/// HKEY_CURRENT_USER as the API takes it (sign-extended 0x80000001).
const _hkeyCurrentUser = -0x7FFFFFFF;
const _regSz = 1;
const _rrfRtRegSz = 0x2;

typedef _AllowNative = Int32 Function(Uint32 pid);
typedef _Allow = int Function(int pid);

/// Lets process [pid] take the foreground (a second start does this for
/// the running app before handing over its link: Windows only lets a
/// process that got the user's click bring a window up).
void allowSetForegroundWindow(int pid) {
  final user32 = DynamicLibrary.open('user32.dll');
  user32.lookupFunction<_AllowNative, _Allow>('AllowSetForegroundWindow')(pid);
}

typedef _SetNative = Int32 Function(
    IntPtr key, Pointer<Utf16> subKey, Pointer<Utf16> name, Uint32 type, Pointer<Void> data, Uint32 size);
typedef _Set = int Function(
    int key, Pointer<Utf16> subKey, Pointer<Utf16> name, int type, Pointer<Void> data, int size);
typedef _GetNative = Int32 Function(IntPtr key, Pointer<Utf16> subKey, Pointer<Utf16> name, Uint32 flags,
    Pointer<Uint32> type, Pointer<Void> data, Pointer<Uint32> size);
typedef _Get = int Function(int key, Pointer<Utf16> subKey, Pointer<Utf16> name, int flags,
    Pointer<Uint32> type, Pointer<Void> data, Pointer<Uint32> size);

DynamicLibrary get _advapi => DynamicLibrary.open('advapi32.dll');

/// The string value [name] ('' = the key's default) of
/// HKEY_CURRENT_USER\[subKey]; null when missing.
String? readUserRegistryString(String subKey, String name) {
  final get = _advapi.lookupFunction<_GetNative, _Get>('RegGetValueW');
  return using((arena) {
    final key = subKey.toNativeUtf16(allocator: arena);
    final value = name.isEmpty ? nullptr : name.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>()..value = 0;
    if (get(_hkeyCurrentUser, key, value, _rrfRtRegSz, nullptr, nullptr, size) != 0) return null;
    final data = arena<Uint16>(size.value ~/ 2 + 1);
    if (get(_hkeyCurrentUser, key, value, _rrfRtRegSz, nullptr, data.cast(), size) != 0) return null;
    return data.cast<Utf16>().toDartString();
  });
}

/// Sets the string value [name] ('' = the key's default) of
/// HKEY_CURRENT_USER\[subKey], creating the key; false when refused.
bool writeUserRegistryString(String subKey, String name, String data) {
  final set = _advapi.lookupFunction<_SetNative, _Set>('RegSetKeyValueW');
  return using((arena) {
    final key = subKey.toNativeUtf16(allocator: arena);
    final value = name.isEmpty ? nullptr : name.toNativeUtf16(allocator: arena);
    final bytes = data.toNativeUtf16(allocator: arena);
    return set(_hkeyCurrentUser, key, value.cast(), _regSz, bytes.cast(), (data.length + 1) * 2) == 0;
  });
}
