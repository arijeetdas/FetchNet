import 'dart:ffi';
import 'dart:io';

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcess = int Function();
typedef _TerminateProcessNative = Int32 Function(IntPtr process, Uint32 exitCode);
typedef _TerminateProcess = int Function(int process, int exitCode);

/// Ends FetchNet right away (desktop).
///
/// On Windows, [exit] runs the DLLs' unload code, and a plugin DLL can spin
/// in it forever once the other threads are gone: FetchNet.exe then stays in
/// the background without a window, at full CPU, keeping its files locked so
/// the installer and in-app updates can't replace them. TerminateProcess
/// skips that code (windows/runner/main.cpp does the same when the window
/// closes).
Never quitApp([int code = 0]) {
  if (Platform.isWindows) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final current = kernel32.lookupFunction<_GetCurrentProcessNative, _GetCurrentProcess>('GetCurrentProcess');
      final terminate = kernel32.lookupFunction<_TerminateProcessNative, _TerminateProcess>('TerminateProcess');
      terminate(current(), code);
    } catch (_) {
      // Fall back to a normal exit.
    }
  }
  exit(code);
}
