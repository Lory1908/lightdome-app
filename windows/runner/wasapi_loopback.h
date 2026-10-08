#ifndef RUNNER_WASAPI_LOOPBACK_H_
#define RUNNER_WASAPI_LOOPBACK_H_

#include <flutter/binary_messenger.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace lightdome {

class WasapiLoopbackPlugin {
 public:
  explicit WasapiLoopbackPlugin(flutter::BinaryMessenger* messenger);
  ~WasapiLoopbackPlugin();

  WasapiLoopbackPlugin(const WasapiLoopbackPlugin&) = delete;
  WasapiLoopbackPlugin& operator=(const WasapiLoopbackPlugin&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace lightdome

#endif  // RUNNER_WASAPI_LOOPBACK_H_
