// ATL 的等价最小替身（本项目本地，2026-10-03）。
//
// 为什么会有这个文件：flutter_local_notifications_windows 3.1.1 的
// src/plugin.cpp 用了 ATL 的 CW2A（宽字符 → UTF-8 窄字符），而本机的
// VS Build Tools 装的时候没带 ATL 组件（Microsoft.VisualStudio.Component.VC.ATL），
// 于是整包构建卡在 `#include <atlbase.h>` 上（C1083）。
//
// 插件真正用到 ATL 的地方只有 3 行 CW2A，所以这里给出**行为等价**的实现：
// 用 Win32 的 WideCharToMultiByte 做同一件事（返回 UTF-8 的 std::string）。
// 它只影响「点开通知时」那一条回调里的字符串转换，其它一切不变。
//
// 上游没有这个头文件、也不需要这个头文件 —— 只有**这台没装 ATL 的机器**上
// 才会被用到（见 windows/CMakeLists.txt 里的说明）。等 ATL 装好之后，
// 那段 CMake 判断会自动不再注入这个目录，`#include <atlbase.h>` 回到系统那份。
#ifndef GRACELINK_ATL_SHIM_H_
#define GRACELINK_ATL_SHIM_H_

#include <windows.h>

#include <string>

namespace atl_shim {

/// 宽字符 → 指定代码页的窄字符（ATL 的 `CW2A(text, codePage)` 同一件事）
inline std::string WideToNarrow(const wchar_t* text, UINT code_page) {
  if (text == nullptr) return std::string();
  const int size = ::WideCharToMultiByte(code_page, 0, text, -1, nullptr, 0,
                                        nullptr, nullptr);
  if (size <= 0) return std::string();
  // size 含结尾的 NUL，去掉它（与 CW2A 的语义一致）
  std::string out(static_cast<size_t>(size - 1), '\0');
  ::WideCharToMultiByte(code_page, 0, text, -1, out.data(), size, nullptr,
                        nullptr);
  return out;
}

}  // namespace atl_shim

/// 与 ATL 的 `CW2A` 同名同形：构造即转换，能隐式变成 `const char*` / `std::string`
class CW2A {
 public:
  explicit CW2A(const wchar_t* text, UINT code_page = CP_ACP)
      : text_(atl_shim::WideToNarrow(text, code_page)) {}

  operator std::string() const { return text_; }
  const char* c_str() const { return text_.c_str(); }

 private:
  std::string text_;
};

#endif  // GRACELINK_ATL_SHIM_H_
