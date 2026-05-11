#pragma once
#include <cstddef>
#include <cstring>
#include <vector>

class RingBuffer {
public:
    explicit RingBuffer(size_t capacity_frames, size_t frame_size = 1)
        : frame_size_(frame_size),
          capacity_(capacity_frames),
          buffer_(capacity_frames * frame_size, 0.0f) {}

    size_t available_read() const {
        return (write_pos_ - read_pos_ + capacity_) % capacity_;
    }

    size_t available_write() const {
        return capacity_ - 1 - available_read();
    }

    bool write(const float* data, size_t frames) {
        if (frames > available_write()) return false;
        for (size_t i = 0; i < frames; ++i) {
            size_t offset = write_pos_ * frame_size_;
            std::memcpy(&buffer_[offset], data + i * frame_size_, frame_size_ * sizeof(float));
            write_pos_ = (write_pos_ + 1) % capacity_;
        }
        return true;
    }

    bool read(float* data, size_t frames) {
        if (frames > available_read()) return false;
        for (size_t i = 0; i < frames; ++i) {
            size_t offset = read_pos_ * frame_size_;
            std::memcpy(data + i * frame_size_, &buffer_[offset], frame_size_ * sizeof(float));
            read_pos_ = (read_pos_ + 1) % capacity_;
        }
        return true;
    }

    bool peek(float* data, size_t frames) const {
        if (frames > available_read()) return false;
        size_t pos = read_pos_;
        for (size_t i = 0; i < frames; ++i) {
            size_t offset = pos * frame_size_;
            std::memcpy(data + i * frame_size_, &buffer_[offset], frame_size_ * sizeof(float));
            pos = (pos + 1) % capacity_;
        }
        return true;
    }

    void discard(size_t frames) {
        size_t to_discard = std::min(frames, available_read());
        read_pos_ = (read_pos_ + to_discard) % capacity_;
    }

    void reset() {
        read_pos_ = 0;
        write_pos_ = 0;
    }

private:
    size_t frame_size_;
    size_t capacity_;
    std::vector<float> buffer_;
    size_t read_pos_ = 0;
    size_t write_pos_ = 0;
};
