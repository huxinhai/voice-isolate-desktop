#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>

struct AudioCaptureConfig {
    int sample_rate = 48000;
    int channels = 1;
    int frames_per_buffer = 480; // 10ms at 48kHz
};

using AudioCaptureCallback = std::function<void(
    const float* mic_data,
    const float* speaker_data,
    size_t frames
)>;

class AudioCapture {
public:
    virtual ~AudioCapture() = default;
    virtual bool start(const AudioCaptureConfig& config, AudioCaptureCallback callback) = 0;
    virtual void stop() = 0;
    virtual bool is_running() const = 0;
};
