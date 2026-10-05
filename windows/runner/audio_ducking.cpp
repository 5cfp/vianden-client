#include "audio_ducking.h"

#include <audiopolicy.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <memory>

using Microsoft::WRL::ComPtr;

namespace {

// Opts out the app's default audio session (the one WebRTC's streams use) on the default
// device for one direction (speakers or microphone) and one role.
bool OptOut(IMMDeviceEnumerator* enumerator, EDataFlow flow, ERole role) {
  ComPtr<IMMDevice> device;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, role, &device))) {
    return false;  // e.g. no microphone connected
  }
  ComPtr<IAudioSessionManager> manager;
  if (FAILED(device->Activate(__uuidof(IAudioSessionManager), CLSCTX_ALL,
                              nullptr,
                              reinterpret_cast<void**>(manager.GetAddressOf())))) {
    return false;
  }
  // nullptr = the process's default session: streams that do not name a session
  // (WebRTC's) belong to it.
  ComPtr<IAudioSessionControl> control;
  if (FAILED(manager->GetAudioSessionControl(nullptr, 0, &control))) {
    return false;
  }
  ComPtr<IAudioSessionControl2> control2;
  if (FAILED(control.As(&control2))) {
    return false;
  }
  return SUCCEEDED(control2->SetDuckingPreference(TRUE));
}

}  // namespace

int OptOutOfDucking() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              IID_PPV_ARGS(&enumerator)))) {
    return 0;
  }
  int updated = 0;
  for (EDataFlow flow : {eRender, eCapture}) {
    for (ERole role : {eCommunications, eConsole}) {
      if (OptOut(enumerator.Get(), flow, role)) {
        updated++;
      }
    }
  }
  return updated;
}

void RegisterAudioChannel(flutter::BinaryMessenger* messenger) {
  // Kept alive for the life of the app (the window owns the engine).
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "vianden/audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "disableDucking") {
          result->Success(flutter::EncodableValue(OptOutOfDucking()));
        } else {
          result->NotImplemented();
        }
      });
}
