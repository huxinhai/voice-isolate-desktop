#include "wav_writer.h"
#include <algorithm>
#include <cstring>

bool WavWriter::open(const std::string& path, int sample_rate, int channels, int bits_per_sample) {
    close();
    file_ = fopen(path.c_str(), "wb");
    if (!file_) return false;

    sample_rate_ = sample_rate;
    channels_ = channels;
    bits_per_sample_ = bits_per_sample;
    data_bytes_written_ = 0;

    write_header();
    return true;
}

bool WavWriter::write_samples(const int16_t* data, size_t num_samples) {
    if (!file_) return false;
    size_t bytes = num_samples * sizeof(int16_t);
    size_t written = fwrite(data, 1, bytes, file_);
    data_bytes_written_ += static_cast<uint32_t>(written);
    return written == bytes;
}

bool WavWriter::write_float(const float* data, size_t num_samples) {
    if (!file_) return false;

    const size_t chunk = 512;
    int16_t buf[chunk];

    size_t remaining = num_samples;
    const float* ptr = data;

    while (remaining > 0) {
        size_t n = std::min(remaining, chunk);
        for (size_t i = 0; i < n; ++i) {
            float s = ptr[i];
            if (s > 1.0f) s = 1.0f;
            if (s < -1.0f) s = -1.0f;
            buf[i] = static_cast<int16_t>(s * 32767.0f);
        }
        size_t bytes = n * sizeof(int16_t);
        size_t written = fwrite(buf, 1, bytes, file_);
        data_bytes_written_ += static_cast<uint32_t>(written);
        if (written != bytes) return false;
        ptr += n;
        remaining -= n;
    }
    return true;
}

void WavWriter::close() {
    if (!file_) return;
    finalize_header();
    fclose(file_);
    file_ = nullptr;
}

void WavWriter::write_header() {
    uint8_t header[44] = {};

    // RIFF chunk
    memcpy(header, "RIFF", 4);
    // file size - 8, placeholder
    uint32_t file_size = 0;
    memcpy(header + 4, &file_size, 4);
    memcpy(header + 8, "WAVE", 4);

    // fmt sub-chunk
    memcpy(header + 12, "fmt ", 4);
    uint32_t fmt_size = 16;
    memcpy(header + 16, &fmt_size, 4);
    uint16_t audio_format = 1; // PCM
    memcpy(header + 20, &audio_format, 2);
    uint16_t num_channels = static_cast<uint16_t>(channels_);
    memcpy(header + 22, &num_channels, 2);
    uint32_t sr = static_cast<uint32_t>(sample_rate_);
    memcpy(header + 24, &sr, 4);
    uint32_t byte_rate = sr * num_channels * (bits_per_sample_ / 8);
    memcpy(header + 28, &byte_rate, 4);
    uint16_t block_align = static_cast<uint16_t>(num_channels * (bits_per_sample_ / 8));
    memcpy(header + 32, &block_align, 2);
    uint16_t bps = static_cast<uint16_t>(bits_per_sample_);
    memcpy(header + 34, &bps, 2);

    // data sub-chunk
    memcpy(header + 36, "data", 4);
    uint32_t data_size = 0; // placeholder
    memcpy(header + 40, &data_size, 4);

    fwrite(header, 1, 44, file_);
}

void WavWriter::finalize_header() {
    if (!file_) return;

    // Update data chunk size
    fseek(file_, 40, SEEK_SET);
    fwrite(&data_bytes_written_, 4, 1, file_);

    // Update RIFF chunk size
    uint32_t riff_size = data_bytes_written_ + 36;
    fseek(file_, 4, SEEK_SET);
    fwrite(&riff_size, 4, 1, file_);

    fseek(file_, 0, SEEK_END);
}
