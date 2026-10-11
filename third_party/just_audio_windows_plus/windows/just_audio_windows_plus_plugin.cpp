#pragma comment(lib, "windowsapp")

#include "include/just_audio_windows_plus/just_audio_windows_plus_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <vector>

#include "platform_thread.hpp"
#include "player.hpp"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

class JustAudioWindowsPlusPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  JustAudioWindowsPlusPlugin();

  virtual ~JustAudioWindowsPlusPlugin();

 private:
  std::vector<std::shared_ptr<AudioPlayer>> players_;
  std::shared_ptr<PlatformThreadDispatcher> dispatcher_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      flutter::BinaryMessenger* messenger);

  void DisposePlayerByPlayerId(const std::string& id);
};

// static
void JustAudioWindowsPlusPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.ryanheise.just_audio.methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<JustAudioWindowsPlusPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get(), messenger_pointer = registrar->messenger()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result), messenger_pointer);
      });

  plugin->channel_ = std::move(channel);
  registrar->AddPlugin(std::move(plugin));
}

JustAudioWindowsPlusPlugin::JustAudioWindowsPlusPlugin()
    : dispatcher_(std::make_shared<PlatformThreadDispatcher>()) {}

// ⚠️ 本地补丁（gracelinkim S12.24 / 2026-10-04）：原版这里有一句
//   `if (channel_) channel_->SetMethodCallHandler(nullptr);`
// —— 反注册通道。但 Flutter 3.44 的引擎拆引擎时**先**把 messenger 的 engine
// 摘空（`FlutterDesktopMessenger::SetEngine`）、**后面**才销毁插件（见调用链）：
//
//   ~FlutterWindowsEngine → PluginRegistrarManager::OnRegistrarDestroyed
//     → PluginRegistrar::ClearPlugins → ~JustAudioWindowsPlusPlugin
//       → MethodChannel::SetMethodCallHandler(nullptr)
//         → BinaryMessengerImpl::SetMessageHandler → FlutterDesktopMessengerSetCallback
//           → messenger->engine == nullptr → 读偏移 0x1e8 → c0000005 AV
//
// 后果是**任何一次引擎销毁都带崩进程**：关主窗口、关独立窗口（灵听 / 文章 /
// 媒体号）都会（实测 WER：flutter_windows.dll +0x14f37）。
// 而反注册本身是多余的 —— 这颗引擎马上跟着一起销毁，注册表随之没了。
// 上游 0.5.3（最新）仍是这样；这里是本仓的 vendored 副本（third_party/），
// 等上游修掉再把 pubspec 换回 pub 版。
JustAudioWindowsPlusPlugin::~JustAudioWindowsPlusPlugin() {
  // 本地补丁（同下）：先给每个 player 打一声招呼「引擎在拆了」，它们的
  // Dispose() 里对 player_channel_ / 事件通道的反注册才会跳过 —— 不跳过
  // 就是上面那条调用链上的 AV（实测 c0000005 @ flutter_windows.dll+0x14f37）。
  for (auto& player : players_) player->PrepareForEngineTeardown();
  for (auto& player : players_) player->Dispose();
  players_.clear();
  dispatcher_->Shutdown();
  dispatcher_.reset();
}

void JustAudioWindowsPlusPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    flutter::BinaryMessenger* messenger) {
  const auto* args = method_call.arguments() ? std::get_if<flutter::EncodableMap>(method_call.arguments()) : nullptr;
  if (!args) {
    result->Error("argument_error", "arguments must be a map");
    return;
  }

  if (method_call.method_name().compare("init") == 0) {
    const auto* id = jaw::Get<std::string>(*args, "id");
    if (!id) {
      return result->Error("argument_error", "id argument missing");
    }
    // Clean up any pre-existing instance with the same ID to prevent orphaned channels or leaks.
    DisposePlayerByPlayerId(*id);

    try {
      auto player = std::make_shared<AudioPlayer>(*id, messenger, dispatcher_);
      player->Initialize();
      players_.push_back(std::move(player));
      result->Success(flutter::EncodableMap());
    } catch (const winrt::hresult_error& error) {
      return result->Error("init_error", winrt::to_string(error.message()));
    } catch (const std::exception& error) {
      return result->Error("init_error", error.what());
    } catch (...) {
      return result->Error("init_error", "Unknown error initializing player");
    }
  } else if (method_call.method_name().compare("disposePlayer") == 0) {
    const auto* id = jaw::Get<std::string>(*args, "id");
    if (!id) {
      return result->Error("argument_error", "id argument missing");
    }
    DisposePlayerByPlayerId(*id);
    result->Success(flutter::EncodableMap());
  } else if (method_call.method_name().compare("disposeAllPlayers") == 0) {
    for (auto& player : players_) player->Dispose();
    players_.clear();
    result->Success(flutter::EncodableMap());
  } else {
    result->NotImplemented();
  }
}

void JustAudioWindowsPlusPlugin::DisposePlayerByPlayerId(const std::string& id) {
  for (auto it = players_.begin(); it != players_.end(); ++it) {
    if ((*it)->HasPlayerId(id)) {
      (*it)->Dispose();
      players_.erase(it);
      return;
    }
  }
}

}  // namespace

void JustAudioWindowsPlusPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  JustAudioWindowsPlusPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
