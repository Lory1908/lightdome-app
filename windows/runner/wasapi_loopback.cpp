#include "wasapi_loopback.h"

#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

namespace lightdome {
namespace {

using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Sink = flutter::EventSink<Value>;

constexpr size_t kFrameSamples = 1024;
constexpr UINT kDispatchMessage = WM_APP + 0x4D;

struct PlatformEvent {
  enum class Kind { kFrame, kError };
  Kind kind;
  UINT32 sample_rate = 0;
  std::vector<double> samples;
  std::string error;
};

std::string HResultMessage(HRESULT result) {
  char buffer[32];
  snprintf(buffer, sizeof(buffer), "0x%08lX",
           static_cast<unsigned long>(result));
  return std::string(buffer);
}

struct CaptureFormat {
  UINT32 sample_rate = 0;
  WORD channels = 0;
  WORD container_bits = 0;
  WORD valid_bits = 0;
  bool is_float = false;
};

bool ParseFormat(const WAVEFORMATEX* wave, CaptureFormat* output) {
  if (!wave || !output || wave->nSamplesPerSec < 8000 ||
      wave->nSamplesPerSec > 384000 || wave->nChannels == 0 ||
      wave->nChannels > 32) {
    return false;
  }
  output->sample_rate = wave->nSamplesPerSec;
  output->channels = wave->nChannels;
  output->container_bits = wave->wBitsPerSample;
  output->valid_bits = wave->wBitsPerSample;
  if (wave->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    output->is_float = true;
  } else if (wave->wFormatTag == WAVE_FORMAT_PCM) {
    output->is_float = false;
  } else if (wave->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
             wave->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) -
                                 sizeof(WAVEFORMATEX)) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wave);
    output->valid_bits = extensible->Samples.wValidBitsPerSample;
    if (output->valid_bits == 0) output->valid_bits = wave->wBitsPerSample;
    if (IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
      output->is_float = true;
    } else if (IsEqualGUID(extensible->SubFormat,
                           KSDATAFORMAT_SUBTYPE_PCM)) {
      output->is_float = false;
    } else {
      return false;
    }
  } else {
    return false;
  }
  if (output->is_float) return output->container_bits == 32;
  return output->container_bits == 16 || output->container_bits == 24 ||
         output->container_bits == 32;
}

double DecodePcmSample(const BYTE* data, const CaptureFormat& format) {
  if (format.is_float) {
    float value = 0;
    memcpy(&value, data, sizeof(value));
    return std::clamp(static_cast<double>(value), -1.0, 1.0);
  }
  if (format.container_bits == 16) {
    int16_t value = 0;
    memcpy(&value, data, sizeof(value));
    return static_cast<double>(value) / 32768.0;
  }
  if (format.container_bits == 24) {
    int32_t value = static_cast<int32_t>(data[0]) |
                    (static_cast<int32_t>(data[1]) << 8) |
                    (static_cast<int32_t>(data[2]) << 16);
    if ((value & 0x00800000) != 0) value |= static_cast<int32_t>(0xFF000000);
    return static_cast<double>(value) / 8388608.0;
  }
  int32_t value = 0;
  memcpy(&value, data, sizeof(value));
  const auto valid = std::clamp<WORD>(format.valid_bits, 1, 32);
  if (valid < 32) value >>= (32 - valid);
  return static_cast<double>(value) /
         std::ldexp(1.0, static_cast<int>(valid) - 1);
}

}  // namespace

class WasapiLoopbackPlugin::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, HWND window)
      : method_channel_(std::make_unique<flutter::MethodChannel<Value>>(
            messenger, "lightdome/windows_audio_commands",
            &flutter::StandardMethodCodec::GetInstance())),
        event_channel_(std::make_unique<flutter::EventChannel<Value>>(
            messenger, "lightdome/windows_audio_frames",
            &flutter::StandardMethodCodec::GetInstance())),
        window_(window) {
    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<Value>& call,
               std::unique_ptr<flutter::MethodResult<Value>> result) {
          if (call.method_name() == "start") {
            std::string error;
            if (Start(&error)) {
              result->Success();
            } else {
              result->Error("wasapi_start_failed", error);
            }
          } else if (call.method_name() == "stop") {
            Stop();
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<Value>>(
            [this](const Value*, std::unique_ptr<Sink>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const Value*)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              Stop();
              sink_.reset();
              return nullptr;
            }));
  }

  ~Impl() {
    shutting_down_.store(true);
    Stop();
    DrainPostedEvents();
    method_channel_->SetMethodCallHandler(nullptr);
    event_channel_->SetStreamHandler(nullptr);
  }

  bool HandleWindowMessage(UINT message, LPARAM lparam, LRESULT* result) {
    if (message != kDispatchMessage) return false;
    std::unique_ptr<PlatformEvent> event(
        reinterpret_cast<PlatformEvent*>(lparam));
    if (event && !shutting_down_.load() && sink_) {
      if (event->kind == PlatformEvent::Kind::kFrame) {
        flutter::EncodableMap value;
        value[Value("sampleRateHz")] =
            Value(static_cast<int32_t>(event->sample_rate));
        value[Value("samples")] = Value(std::move(event->samples));
        sink_->Success(Value(std::move(value)));
      } else {
        sink_->Error("wasapi_capture_failed", event->error);
      }
    }
    if (result) *result = 0;
    return true;
  }

 private:
  bool Start(std::string* error) {
    std::unique_lock<std::mutex> lock(state_mutex_);
    if (capture_thread_.joinable()) {
      if (ready_) return true;
      *error = failure_.empty() ? "Avvio WASAPI già in corso" : failure_;
      return false;
    }
    stop_requested_.store(false);
    ready_ = false;
    initialized_ = false;
    failure_.clear();
    capture_thread_ = std::thread([this] { CaptureMain(); });
    const bool signaled = state_cv_.wait_for(
        lock, std::chrono::seconds(5),
        [this] { return initialized_; });
    if (!signaled || !ready_) {
      *error = !signaled ? "Timeout durante l’avvio WASAPI" : failure_;
      lock.unlock();
      Stop();
      return false;
    }
    return true;
  }

  void Stop() {
    stop_requested_.store(true);
    state_cv_.notify_all();
    if (capture_thread_.joinable() &&
        capture_thread_.get_id() != std::this_thread::get_id()) {
      capture_thread_.join();
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    ready_ = false;
    initialized_ = false;
  }

  void Fail(HRESULT result, const char* operation) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    failure_ = std::string(operation) + " (" + HResultMessage(result) + ")";
    initialized_ = true;
    ready_ = false;
    state_cv_.notify_all();
  }

  void FailText(const std::string& message) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    failure_ = message;
    initialized_ = true;
    ready_ = false;
    state_cv_.notify_all();
  }

  void SignalReady() {
    std::lock_guard<std::mutex> lock(state_mutex_);
    initialized_ = true;
    ready_ = true;
    state_cv_.notify_all();
  }

  void PostFrame(const std::vector<double>& samples, UINT32 sample_rate) {
    auto event = std::make_unique<PlatformEvent>();
    event->kind = PlatformEvent::Kind::kFrame;
    event->sample_rate = sample_rate;
    event->samples = samples;
    PostEvent(std::move(event));
  }

  void PostError(const std::string& message) {
    auto event = std::make_unique<PlatformEvent>();
    event->kind = PlatformEvent::Kind::kError;
    event->error = message;
    PostEvent(std::move(event));
  }

  void PostEvent(std::unique_ptr<PlatformEvent> event) {
    if (shutting_down_.load() || !window_) return;
    PlatformEvent* raw = event.release();
    if (!PostMessage(window_, kDispatchMessage, 0,
                     reinterpret_cast<LPARAM>(raw))) {
      delete raw;
    }
  }

  void DrainPostedEvents() {
    if (!window_) return;
    MSG message;
    while (PeekMessage(&message, window_, kDispatchMessage, kDispatchMessage,
                       PM_REMOVE)) {
      delete reinterpret_cast<PlatformEvent*>(message.lParam);
    }
  }

  void CaptureMain() {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) {
      Fail(com_result, "Impossibile inizializzare COM");
      return;
    }
    const bool uninitialize_com = SUCCEEDED(com_result);

    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                      CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(result)) {
      Fail(result, "Impossibile enumerare le uscite audio");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    ComPtr<IMMDevice> endpoint;
    result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                  &endpoint);
    if (FAILED(result)) {
      Fail(result, "Nessuna uscita audio Windows predefinita");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    ComPtr<IAudioClient> audio_client;
    result = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                &audio_client);
    if (FAILED(result)) {
      Fail(result, "Impossibile aprire l’uscita audio Windows");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    WAVEFORMATEX* raw_format = nullptr;
    result = audio_client->GetMixFormat(&raw_format);
    if (FAILED(result) || !raw_format) {
      Fail(result, "Impossibile leggere il formato audio Windows");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    CaptureFormat format;
    if (!ParseFormat(raw_format, &format)) {
      CoTaskMemFree(raw_format);
      FailText("Il formato dell’uscita audio Windows non è supportato");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    constexpr REFERENCE_TIME kBufferDuration = 1000000;  // 100 ms.
    result = audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_NOPERSIST,
        kBufferDuration, 0, raw_format, nullptr);
    CoTaskMemFree(raw_format);
    if (FAILED(result)) {
      Fail(result, "Impossibile avviare WASAPI loopback");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    ComPtr<IAudioCaptureClient> capture_client;
    result = audio_client->GetService(IID_PPV_ARGS(&capture_client));
    if (FAILED(result)) {
      Fail(result, "Impossibile creare la cattura WASAPI");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    result = audio_client->Start();
    if (FAILED(result)) {
      Fail(result, "Impossibile iniziare la cattura audio");
      if (uninitialize_com) CoUninitialize();
      return;
    }
    SignalReady();

    const size_t bytes_per_sample = format.container_bits / 8;
    const size_t bytes_per_frame = bytes_per_sample * format.channels;
    std::vector<double> output;
    output.reserve(kFrameSamples);
    bool failed = false;
    std::string runtime_error;
    while (!stop_requested_.load()) {
      UINT32 packet_frames = 0;
      result = capture_client->GetNextPacketSize(&packet_frames);
      if (FAILED(result)) {
        failed = true;
        runtime_error = "L’uscita audio Windows non è più disponibile (" +
                        HResultMessage(result) + ")";
        break;
      }
      if (packet_frames == 0) {
        std::unique_lock<std::mutex> lock(state_mutex_);
        state_cv_.wait_for(lock, std::chrono::milliseconds(8),
                           [this] { return stop_requested_.load(); });
        continue;
      }
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      result = capture_client->GetBuffer(&data, &frames, &flags, nullptr,
                                         nullptr);
      if (FAILED(result)) {
        failed = true;
        runtime_error = "Errore durante la lettura audio Windows (" +
                        HResultMessage(result) + ")";
        break;
      }
      const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      for (UINT32 frame = 0; frame < frames; ++frame) {
        double mono = 0;
        if (!silent && data) {
          const BYTE* frame_data = data + frame * bytes_per_frame;
          for (WORD channel = 0; channel < format.channels; ++channel) {
            mono += DecodePcmSample(frame_data + channel * bytes_per_sample,
                                    format);
          }
          mono /= format.channels;
        }
        output.push_back(std::clamp(mono, -1.0, 1.0));
        if (output.size() == kFrameSamples) {
          PostFrame(output, format.sample_rate);
          output.clear();
        }
      }
      result = capture_client->ReleaseBuffer(frames);
      if (FAILED(result)) {
        failed = true;
        runtime_error = "Errore nel rilascio del buffer audio Windows (" +
                        HResultMessage(result) + ")";
        break;
      }
    }
    audio_client->Stop();
    if (failed && !stop_requested_.load()) PostError(runtime_error);
    if (uninitialize_com) CoUninitialize();
  }

  std::unique_ptr<flutter::MethodChannel<Value>> method_channel_;
  std::unique_ptr<flutter::EventChannel<Value>> event_channel_;
  std::unique_ptr<Sink> sink_;
  HWND window_ = nullptr;
  std::atomic<bool> shutting_down_{false};

  std::thread capture_thread_;
  std::atomic<bool> stop_requested_{false};
  std::mutex state_mutex_;
  std::condition_variable state_cv_;
  bool initialized_ = false;
  bool ready_ = false;
  std::string failure_;
};

WasapiLoopbackPlugin::WasapiLoopbackPlugin(
    flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}

WasapiLoopbackPlugin::~WasapiLoopbackPlugin() = default;

bool WasapiLoopbackPlugin::HandleWindowMessage(UINT message, WPARAM,
                                               LPARAM lparam,
                                               LRESULT* result) {
  return impl_->HandleWindowMessage(message, lparam, result);
}

}  // namespace lightdome
