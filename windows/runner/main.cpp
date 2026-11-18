#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// ───── In-app update guard ─────
//
// The in-app updater (lib/services/windows_self_update.dart) renames each
// installed file to "<file>.fnold", moves the new one in, and records every
// step in %LOCALAPPDATA%\FetchNet\update-journal.txt:
//
//   FETCHNET-UPDATE 1
//   state=applying | applied
//   launches=<starts since the update>
//   version=<new version>
//   exe=<FetchNet.exe>
//   <installed file>|<its .fnold backup, empty for a new file>
//
// Once the new version is up, Dart deletes the journal. Until then, this
// runs before Flutter starts (so it works even when the new version can't):
// an update cut off part-way, or one that failed to start twice, is rolled
// back and the previous version started instead.

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        &wide[0], size);
  return wide;
}

std::wstring UpdateJournalPath() {
  wchar_t base[MAX_PATH];
  const DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return std::wstring();
  return std::wstring(base) + L"\\FetchNet\\update-journal.txt";
}

// Seconds since the journal was last written.
double JournalAgeSeconds(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return 0;
  FILETIME now;
  ::GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER written, current;
  written.LowPart = data.ftLastWriteTime.dwLowDateTime;
  written.HighPart = data.ftLastWriteTime.dwHighDateTime;
  current.LowPart = now.dwLowDateTime;
  current.HighPart = now.dwHighDateTime;
  if (current.QuadPart < written.QuadPart) return 0;
  return static_cast<double>(current.QuadPart - written.QuadPart) / 1e7;
}

// Returns true when it rolled an update back and started the previous
// version: this process should then quit.
bool GuardInAppUpdate() {
  const std::wstring path = UpdateJournalPath();
  if (path.empty()) return false;
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  std::vector<std::string> lines;
  for (std::string line; std::getline(in, line);) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    lines.push_back(line);
  }
  in.close();
  if (lines.empty() || lines[0] != "FETCHNET-UPDATE 1") return false;

  std::string state;
  int launches = 0;
  std::wstring exe;
  std::vector<std::pair<std::wstring, std::wstring>> moves;
  for (size_t i = 1; i < lines.size(); ++i) {
    const std::string& line = lines[i];
    if (line.rfind("state=", 0) == 0) {
      state = line.substr(6);
    } else if (line.rfind("launches=", 0) == 0) {
      launches = std::atoi(line.substr(9).c_str());
    } else if (line.rfind("exe=", 0) == 0) {
      exe = Utf8ToWide(line.substr(4));
    } else {
      const size_t bar = line.find('|');
      if (bar != std::string::npos) {
        moves.emplace_back(Utf8ToWide(line.substr(0, bar)),
                           Utf8ToWide(line.substr(bar + 1)));
      }
    }
  }

  bool roll_back = false;
  if (state == "applying") {
    // Still being written by a running FetchNet? Leave it alone.
    roll_back = JournalAgeSeconds(path) > 120;
  } else if (state == "applied") {
    ++launches;
    if (launches >= 3) {
      roll_back = true;
    } else {
      std::ofstream out(path, std::ios::binary | std::ios::trunc);
      for (size_t i = 0; i < lines.size(); ++i) {
        if (lines[i].rfind("launches=", 0) == 0) {
          out << "launches=" << launches << "\r\n";
        } else if (!lines[i].empty()) {
          out << lines[i] << "\r\n";
        }
      }
    }
  }
  if (!roll_back) return false;

  for (auto it = moves.rbegin(); it != moves.rend(); ++it) {
    const std::wstring& target = it->first;
    const std::wstring& backup = it->second;
    if (::GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES) {
      // Renaming works even for this running executable.
      ::MoveFileExW(target.c_str(), (target + L".fnfailed").c_str(),
                    MOVEFILE_REPLACE_EXISTING);
    }
    if (!backup.empty()) {
      ::MoveFileExW(backup.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING);
    }
  }
  ::DeleteFileW(path.c_str());
  if (exe.empty()) return false;

  STARTUPINFOW startup = {sizeof(startup)};
  PROCESS_INFORMATION process = {};
  std::wstring command = L"\"" + exe + L"\"";
  if (::CreateProcessW(exe.c_str(), &command[0], nullptr, nullptr, FALSE, 0,
                       nullptr, nullptr, &startup, &process)) {
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
    return true;
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // An in-app update that didn't take: back to the previous version.
  if (GuardInAppUpdate()) return EXIT_SUCCESS;

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"FetchNet", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
