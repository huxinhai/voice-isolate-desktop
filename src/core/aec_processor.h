#pragma once
#include <cstddef>

class AecProcessor {
public:
    AecProcessor(int sample_rate = 16000, int channels = 1);
    ~AecProcessor();

    // Feed speaker/render data as reference signal
    void analyze_render(const float* data, size_t frames);

    // Process mic/capture data, output echo-cancelled audio in-place
    void process_capture(float* data, size_t frames);

    void reset();

private:
    int sample_rate_;
    int channels_;
    void* state_ = nullptr;
};
