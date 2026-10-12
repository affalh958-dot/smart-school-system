#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// يكتب رسالة خطأ في ملف بجانب البرنامج حتى نعرف سبب عدم الفتح
// (المستخدم لا يرى console في نسخة Release).
void WriteStartupLog(const std::string& message) {
  wchar_t exe_path[MAX_PATH];
  DWORD n = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (n == 0) return;
  std::wstring path(exe_path, n);
  size_t slash = path.find_last_of(L"\\/");
  std::wstring dir = (slash == std::wstring::npos) ? L"." : path.substr(0, slash);
  std::wstring log_path = dir + L"\\school_startup_error.log";

  HANDLE file = ::CreateFileW(log_path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  ::WriteFile(file, message.c_str(), (DWORD)message.size(), &written, nullptr);
  ::WriteFile(file, "\r\n", 2, &written, nullptr);
  ::CloseHandle(file);
}

// يعرض نافذة خطأ واضحة + يسجّل السبب، ثم يخرج.
int FailWithMessage(const std::string& message) {
  WriteStartupLog(message);
  ::MessageBoxA(nullptr, message.c_str(),
                "نظام إدارة المدرسة الذكي — تعذّر بدء التشغيل",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
  return EXIT_FAILURE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  if (!window.Create(L"school_app", origin, size)) {
    // أشهر سبب: تحريك الملف التنفيذي وحده دون مجلد data وملفات dll المجاورة،
    // أو غياب مكتبات Visual C++. نوضّح ذلك للمستخدم بدل الفشل الصامت.
    return FailWithMessage(
        "تعذّر تشغيل البرنامج.\n\n"
        "تأكد من فكّ ضغط الحزمة كاملة وتشغيل school_app.exe من داخل مجلده "
        "مع بقاء المجلد data وملفات dll (مثل flutter_windows.dll) بجانبه.\n\n"
        "إن تكرر الخطأ ثبّت حزمة Microsoft Visual C++ Redistributable (x64).");
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
