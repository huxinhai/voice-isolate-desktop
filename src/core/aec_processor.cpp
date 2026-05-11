#include "aec_processor.h"
#include <cstring>
#include <vector>

#ifdef AEC_USE_WEBRTC
// TODO: include webrtc aec3 headers and link library
#endif

struct AecState {
    std::vector<float> render_buf;
    int frame_size;
};

AecProcessor::AecProcessor(int sample_rate, int channels)
    : sample_rate_(sample_rate), channels_(channels) {
    auto* s = new AecState();
    s->frame_size = sample_rate / 100; // 10ms
    s->render_buf.resize(s->frame_size, 0.0f);
    state_ = s;
}

AecProcessor::~AecProcessor() {
    delete static_cast<AecState*>(state_);
}

void AecProcessor::analyze_render(const float* data, size_t frames) {
    auto* s = static_cast<AecState*>(state_);
    size_t copy_frames = std::min(frames, static_cast<size_t>(s->frame_size));
    std::memcpy(s->render_buf.data(), data, copy_frames * sizeof(float));

#ifdef AEC_USE_WEBRTC
    // TODO: call webrtc AnalyzeRender
#endif
}

void AecProcessor::process_capture(float* data, size_t frames) {
#ifdef AEC_USE_WEBRTC
    // TODO: call webrtc ProcessCapture
#else
    // Stub: simple spectral subtraction placeholder
    // In production, replace with WebRTC AEC3
    auto* s = static_cast<AecState*>(state_);
    size_t process_frames = std::min(frames, static_cast<size_t>(s->frame_size));
    for (size_t i = 0; i < process_frames; ++i) {
        // Naive subtraction (for testing pipeline only, not real AEC)
        data[i] = data[i] - 0.8f * s->render_buf[i];
    }
#endif
}

void AecProcessor::reset() {
    auto* s = static_cast<AecState*>(state_);
    std::fill(s->render_buf.begin(), s->render_buf.end(), 0.0f);
}
