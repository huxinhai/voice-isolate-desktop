#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

class WavWriter {
public:
    WavWriter() = default;
    ~WavWriter() { close(); }

    bool open(const std::string& path, int sample_rate, int channels, int bits_per_sample = 16);
    bool write_samples(const int16_t* data, size_t num_samples);
    bool write_float(const float* data, size_t num_samples);
    void close();

private:
    void write_header();
    void finalize_header();

    FILE* file_ = nullptr;
    int sample_rate_ = 16000;
    int channels_ = 1;
    int bits_per_sample_ = 16;
    uint32_t data_bytes_written_ = 0;
};
