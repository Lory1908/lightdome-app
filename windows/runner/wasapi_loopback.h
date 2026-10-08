#ifndef RUNNER_WASAPI_LOOPBACK_H_
#define RUNNER_WASAPI_LOOPBACK_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace lightdome {

class WasapiLoopbackPlugin {
 public:
  WasapiLoopbackPlugin(flutter::BinaryMessenger* messenger, HWND window);
  ~WasapiLoopbackPlugin();

  WasapiLoopbackPlugin(const WasapiLoopbackPlugin&) = delete;
  WasapiLoopbackPlugin& operator=(const WasapiLoopbackPlugin&) = delete;

  // Must be called by the owning window on its platform thread.
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam,
                           LRESULT* result);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lightdome

#endif  // RUNNER_WASAPI_LOOPBACK_H_
