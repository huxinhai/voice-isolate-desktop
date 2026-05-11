#include <csignal>
#include <cstdio>
#include <atomic>
#include <thread>
#include <chrono>
#include <mutex>
#include <vector>

#include "core/aec_processor.h"
#include "core/resampler.h"
#include "core/ring_buffer.h"
#include "output/wav_writer.h"
#include "platform/audio_capture.h"

#ifdef __APPLE__
#include "platform/macos/coreaudio_capture.h"
#endif

static std::atomic<bool> g_running{true};

static void signal_handler(int) {
    g_running = false;
}

int main(int argc, char* argv[]) {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    const int capture_rate = 48000;
    const int process_rate = 16000;
    const int channels = 1;
    const int capture_frame_ms = 10;
    const int capture_frames = capture_rate * capture_frame_ms / 1000; // 480
    const int process_frames = process_rate * capture_frame_ms / 1000; // 160

    // Output WAV files
    WavWriter mic_writer;
    WavWriter speaker_writer;
    WavWriter output_writer;

    if (!mic_writer.open("mic_raw.wav", process_rate, channels)) {
        fprintf(stderr, "Failed to open mic_raw.wav\n");
        return 1;
    }
    if (!speaker_writer.open("speaker_ref.wav", process_rate, channels)) {
        fprintf(stderr, "Failed to open speaker_ref.wav\n");
        return 1;
    }
    if (!output_writer.open("aec3_output.wav", process_rate, channels)) {
        fprintf(stderr, "Failed to open aec3_output.wav\n");
        return 1;
    }

    // Resamplers: 48k -> 16k
    Resampler mic_resampler(capture_rate, process_rate, channels);
    Resampler speaker_resampler(capture_rate, process_rate, channels);

    // AEC processor at 16kHz
    AecProcessor aec(process_rate, channels);

    // Buffers for resampled data
    std::vector<float> mic_16k(process_frames * 2);
    std::vector<float> speaker_16k(process_frames * 2);
    std::vector<float> aec_out(process_frames * 2);

    std::mutex process_mutex;

    // Audio capture callback
    auto capture_callback = [&](const float* mic_data, const float* speaker_data, size_t frames) {
        std::lock_guard<std::mutex> lock(process_mutex);

        // Resample mic 48k -> 16k
        size_t mic_out_frames = mic_resampler.process(mic_data, frames, mic_16k.data(), mic_16k.size());

        // Resample speaker 48k -> 16k
        size_t spk_out_frames = 0;
        if (speaker_data) {
            spk_out_frames = speaker_resampler.process(speaker_data, frames, speaker_16k.data(), speaker_16k.size());
        } else {
            // No speaker data available, fill with silence
            spk_out_frames = mic_out_frames;
            std::fill(speaker_16k.begin(), speaker_16k.begin() + spk_out_frames, 0.0f);
        }

        // Use the minimum of both for processing
        size_t proc_frames = std::min(mic_out_frames, spk_out_frames);

        // Feed speaker to AEC as reference
        aec.analyze_render(speaker_16k.data(), proc_frames);

        // Copy mic data for AEC processing (in-place)
        std::memcpy(aec_out.data(), mic_16k.data(), proc_frames * sizeof(float));
        aec.process_capture(aec_out.data(), proc_frames);

        // Write all three WAV files
        mic_writer.write_float(mic_16k.data(), proc_frames);
        speaker_writer.write_float(speaker_16k.data(), proc_frames);
        output_writer.write_float(aec_out.data(), proc_frames);
    };

    // Create and start audio capture
    auto capture = create_audio_capture();
    AudioCaptureConfig config;
    config.sample_rate = capture_rate;
    config.channels = channels;
    config.frames_per_buffer = capture_frames;

    printf("Starting AEC recorder...\n");
    printf("  Capture rate: %d Hz\n", capture_rate);
    printf("  Process rate: %d Hz\n", process_rate);
    printf("  Frame size: %d ms\n", capture_frame_ms);
    printf("  Output files: mic_raw.wav, speaker_ref.wav, aec3_output.wav\n");
    printf("  Press Ctrl+C to stop.\n\n");

    if (!capture->start(config, capture_callback)) {
        fprintf(stderr, "Failed to start audio capture\n");
        return 1;
    }

    // Main loop - wait for Ctrl+C
    while (g_running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    printf("\nStopping...\n");
    capture->stop();

    // Close WAV files (finalizes headers)
    mic_writer.close();
    speaker_writer.close();
    output_writer.close();

    printf("Done. Output files written.\n");
    return 0;
}
