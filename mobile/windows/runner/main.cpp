#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kWindowTitle[] = L"torchat_mobile";
constexpr const wchar_t kSingleInstanceMutex[] =
    L"Local\\TorChatDesktopSingleInstance";

HWND FindExistingTorChatWindow() {
  // The first process may own the mutex slightly before its top-level window is
  // registered. Give it a short opportunity to finish startup before deciding
  // that the mutex belongs to an orphaned/headless instance.
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (HWND existing = ::FindWindowW(kWindowClassName, kWindowTitle)) {
      return existing;
    }
    ::Sleep(100);
  }
  return nullptr;
}

void ActivateExistingWindow(HWND window) {
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window);
}

void CloseSingleInstanceHandle(HANDLE handle, bool owns_mutex) {
  if (handle == nullptr) {
    return;
  }
  if (owns_mutex) {
    ::ReleaseMutex(handle);
  }
  ::CloseHandle(handle);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance == nullptr) {
    return EXIT_FAILURE;
  }

  bool owns_single_instance = ::GetLastError() != ERROR_ALREADY_EXISTS;
  if (!owns_single_instance) {
    if (HWND existing = FindExistingTorChatWindow()) {
      ActivateExistingWindow(existing);
      CloseSingleInstanceHandle(single_instance, false);
      return EXIT_SUCCESS;
    }

    // A process can disappear after creating the mutex or can be left headless
    // by an abnormal window teardown. Do not make that stale coordination state
    // permanently prevent the visible client from starting.
    CloseSingleInstanceHandle(single_instance, false);
    single_instance = nullptr;
  }

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
  // Closing the window hides it in the tray. Actual window destruction always
  // terminates the process so no headless mutex-owning instance can remain.
  window.SetQuitOnClose(false);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CoUninitialize();
    CloseSingleInstanceHandle(single_instance, owns_single_instance);
    return EXIT_FAILURE;
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseSingleInstanceHandle(single_instance, owns_single_instance);
  return EXIT_SUCCESS;
}
