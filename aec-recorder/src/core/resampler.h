#pragma once
#include <cstddef>
#include <vector>

class Resampler {
public:
    Resampler(int from_rate, int to_rate, int channels = 1);

    // Returns number of output frames produced
    size_t process(const float* input, size_t input_frames, float* output, size_t output_capacity);

    // How many output frames will N input frames produce
    size_t output_frames_for(size_t input_frames) const;

    void reset();

private:
    int from_rate_;
    int to_rate_;
    int channels_;
    double ratio_;
    double phase_ = 0.0;
    float last_sample_ = 0.0f;
};
