#include "flutter_window.h"

#include <filesystem>
#include <mmsystem.h>
#include <optional>
#include <thread>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  notification_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "org.torchat/desktop-notifications",
          &flutter::StandardMethodCodec::GetInstance());
  const HWND notification_window = GetHandle();
  notification_channel_->SetMethodCallHandler(
      [notification_window](const auto& call, auto result) {
        if (call.method_name() != "pagerBeep") {
          result->NotImplemented();
          return;
        }
        std::thread([notification_window] {
          if (IsWindow(notification_window)) {
            FLASHWINFO flash = {};
            flash.cbSize = sizeof(FLASHWINFO);
            flash.hwnd = notification_window;
            flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
            flash.uCount = 5;
            flash.dwTimeout = 0;
            FlashWindowEx(&flash);
          }
          MessageBeep(MB_ICONASTERISK);
          Sleep(130);
          MessageBeep(MB_ICONASTERISK);
        }).detach();
        result->Success();
      });
  audio_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "org.torchat/audio",
          &flutter::StandardMethodCodec::GetInstance());
  audio_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "playIntro") {
      result->NotImplemented();
      return;
    }
    wchar_t executable_path[MAX_PATH] = {};
    const DWORD length =
        GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
    if (length == 0 || length == MAX_PATH) {
      result->Error("AUDIO", "Could not resolve application directory");
      return;
    }
    const auto intro_path =
        std::filesystem::path(executable_path).parent_path() / L"data" /
        L"flutter_assets" / L"assets" / L"audio" / L"intro.mp3";
    std::thread([intro_path] {
      mciSendStringW(L"close torchat_intro", nullptr, 0, nullptr);
      const std::wstring open_command =
          L"open \"" + intro_path.wstring() +
          L"\" type mpegvideo alias torchat_intro";
      if (mciSendStringW(open_command.c_str(), nullptr, 0, nullptr) == 0) {
        mciSendStringW(L"play torchat_intro", nullptr, 0, nullptr);
      }
    }).detach();
    result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
