#include "resampler.h"
#include <cmath>

Resampler::Resampler(int from_rate, int to_rate, int channels)
    : from_rate_(from_rate), to_rate_(to_rate), channels_(channels),
      ratio_(static_cast<double>(from_rate) / to_rate) {}

size_t Resampler::output_frames_for(size_t input_frames) const {
    return static_cast<size_t>(std::ceil(input_frames / ratio_));
}

size_t Resampler::process(const float* input, size_t input_frames, float* output, size_t output_capacity) {
    if (from_rate_ == to_rate_) {
        size_t n = std::min(input_frames, output_capacity);
        for (size_t i = 0; i < n * channels_; ++i) {
            output[i] = input[i];
        }
        return n;
    }

    size_t out_frames = 0;

    for (size_t i = 0; i < input_frames && out_frames < output_capacity; ++i) {
        float current = input[i * channels_];

        while (phase_ < 1.0 && out_frames < output_capacity) {
            float interpolated = last_sample_ + static_cast<float>(phase_) * (current - last_sample_);
            output[out_frames * channels_] = interpolated;
            ++out_frames;
            phase_ += ratio_;
        }
        phase_ -= 1.0;
        last_sample_ = current;
    }

    return out_frames;
}

void Resampler::reset() {
    phase_ = 0.0;
    last_sample_ = 0.0f;
}
