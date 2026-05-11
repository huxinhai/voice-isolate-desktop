#import "coreaudio_capture.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <atomic>
#include <cstring>
#include <vector>
#include <mutex>

class CoreAudioCapture : public AudioCapture {
public:
    ~CoreAudioCapture() override { stop(); }

    bool start(const AudioCaptureConfig& config, AudioCaptureCallback callback) override;
    void stop() override;
    bool is_running() const override { return running_.load(); }

private:
    static OSStatus mic_io_proc(AudioDeviceID device,
                                const AudioTimeStamp* now,
                                const AudioBufferList* input_data,
                                const AudioTimeStamp* input_time,
                                AudioBufferList* output_data,
                                const AudioTimeStamp* output_time,
                                void* client_data);

    bool setup_process_tap();
    bool setup_mic_capture();
    void teardown();

    AudioDeviceID find_default_input_device();
    AudioDeviceID find_default_output_device();
    CFStringRef get_device_uid(AudioDeviceID device);
    pid_t get_own_pid_object_id();

    AudioCaptureConfig config_;
    AudioCaptureCallback callback_;
    std::atomic<bool> running_{false};

    // Mic capture via default input device
    AudioDeviceID mic_device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID mic_io_proc_id_ = nullptr;

    // System audio via ProcessTap + Aggregate Device
    AudioObjectID process_tap_id_ = kAudioObjectUnknown;
    AudioDeviceID tap_aggregate_device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID tap_io_proc_id_ = nullptr;

    // Shared ring buffer for speaker data (written by tap callback, read by mic callback)
    std::mutex speaker_mutex_;
    std::vector<float> speaker_ring_;
    size_t speaker_write_pos_ = 0;
    size_t speaker_read_pos_ = 0;
    static constexpr size_t SPEAKER_RING_SIZE = 48000; // 1 second at 48kHz
};

AudioDeviceID CoreAudioCapture::find_default_input_device() {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);
    return device;
}

AudioDeviceID CoreAudioCapture::find_default_output_device() {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);
    return device;
}

CFStringRef CoreAudioCapture::get_device_uid(AudioDeviceID device) {
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(CFStringRef);
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &uid);
    return uid;
}

pid_t CoreAudioCapture::get_own_pid_object_id() {
    pid_t pid = getpid();
    AudioObjectID processObjectID = kAudioObjectUnknown;
    UInt32 size = sizeof(processObjectID);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 qualifierSize = sizeof(pid);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, qualifierSize, &pid, &size, &processObjectID);
    return processObjectID;
}

bool CoreAudioCapture::setup_process_tap() {
    AudioDeviceID output_device = find_default_output_device();
    if (output_device == kAudioObjectUnknown) {
        fprintf(stderr, "Cannot find default output device\n");
        return false;
    }

    CFStringRef output_uid = get_device_uid(output_device);
    if (!output_uid) {
        fprintf(stderr, "Cannot get output device UID\n");
        return false;
    }

    // Get own process object ID to exclude from tap
    AudioObjectID own_process = get_own_pid_object_id();

    if (@available(macOS 14.2, *)) {
        CATapDescription *tapDesc = [[CATapDescription alloc] initMonoGlobalTapButExcludeProcesses:@[@(own_process)]];
        tapDesc.UUID = [NSUUID UUID];
        tapDesc.name = @"aec-recorder-tap";
        tapDesc.privateTap = YES;
        tapDesc.muteBehavior = CATapUnmuted;

        OSStatus err = AudioHardwareCreateProcessTap(tapDesc, &process_tap_id_);
        if (err != noErr) {
            fprintf(stderr, "Failed to create process tap: %d\n", (int)err);
            CFRelease(output_uid);
            return false;
        }

        // Read tap stream format
        AudioStreamBasicDescription tapFormat = {};
        UInt32 formatSize = sizeof(tapFormat);
        AudioObjectPropertyAddress formatAddr = {
            kAudioTapPropertyFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        err = AudioObjectGetPropertyData(process_tap_id_, &formatAddr, 0, nullptr, &formatSize, &tapFormat);
        if (err != noErr) {
            fprintf(stderr, "Failed to read tap format: %d\n", (int)err);
        } else {
            fprintf(stderr, "Tap format: sr=%.0f ch=%u\n", tapFormat.mSampleRate, tapFormat.mChannelsPerFrame);
        }

        // Create aggregate device with tap
        NSString *outputUIDStr = (__bridge NSString *)output_uid;
        NSString *tapUUIDStr = tapDesc.UUID.UUIDString;
        NSString *aggregateUID = [NSUUID UUID].UUIDString;

        NSDictionary *description = @{
            @(kAudioAggregateDeviceNameKey): @"aec-recorder-systap",
            @(kAudioAggregateDeviceUIDKey): aggregateUID,
            @(kAudioAggregateDeviceMainSubDeviceKey): outputUIDStr,
            @(kAudioAggregateDeviceIsPrivateKey): @YES,
            @(kAudioAggregateDeviceIsStackedKey): @NO,
            @(kAudioAggregateDeviceTapAutoStartKey): @YES,
            @(kAudioAggregateDeviceSubDeviceListKey): @[
                @{@(kAudioSubDeviceUIDKey): outputUIDStr},
            ],
            @(kAudioAggregateDeviceTapListKey): @[
                @{
                    @(kAudioSubTapDriftCompensationKey): @YES,
                    @(kAudioSubTapUIDKey): tapUUIDStr,
                },
            ],
        };

        err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &tap_aggregate_device_);
        CFRelease(output_uid);

        if (err != noErr) {
            fprintf(stderr, "Failed to create tap aggregate device: %d\n", (int)err);
            AudioHardwareDestroyProcessTap(process_tap_id_);
            process_tap_id_ = kAudioObjectUnknown;
            return false;
        }
        fprintf(stderr, "Tap aggregate device created: %u\n", (unsigned)tap_aggregate_device_);

        // Register IO proc for tap aggregate device (captures system audio)
        __block CoreAudioCapture* selfPtr = this;
        err = AudioDeviceCreateIOProcIDWithBlock(
            &tap_io_proc_id_,
            tap_aggregate_device_,
            nullptr,
            ^(const AudioTimeStamp* inNow,
              const AudioBufferList* inInputData,
              const AudioTimeStamp* inInputTime,
              AudioBufferList* outOutputData,
              const AudioTimeStamp* inOutputTime) {

                if (!selfPtr->running_.load()) return;
                if (!inInputData || inInputData->mNumberBuffers == 0) return;

                const float* data = (const float*)inInputData->mBuffers[0].mData;
                size_t frames = inInputData->mBuffers[0].mDataByteSize / sizeof(float);

                // Write to speaker ring buffer
                std::lock_guard<std::mutex> lock(selfPtr->speaker_mutex_);
                for (size_t i = 0; i < frames; ++i) {
                    selfPtr->speaker_ring_[selfPtr->speaker_write_pos_] = data[i];
                    selfPtr->speaker_write_pos_ = (selfPtr->speaker_write_pos_ + 1) % SPEAKER_RING_SIZE;
                }
            }
        );

        if (err != noErr) {
            fprintf(stderr, "Failed to create tap IO proc: %d\n", (int)err);
            AudioHardwareDestroyAggregateDevice(tap_aggregate_device_);
            tap_aggregate_device_ = kAudioObjectUnknown;
            AudioHardwareDestroyProcessTap(process_tap_id_);
            process_tap_id_ = kAudioObjectUnknown;
            return false;
        }

        err = AudioDeviceStart(tap_aggregate_device_, tap_io_proc_id_);
        if (err != noErr) {
            fprintf(stderr, "Failed to start tap device: %d\n", (int)err);
            AudioDeviceDestroyIOProcID(tap_aggregate_device_, tap_io_proc_id_);
            tap_io_proc_id_ = nullptr;
            AudioHardwareDestroyAggregateDevice(tap_aggregate_device_);
            tap_aggregate_device_ = kAudioObjectUnknown;
            AudioHardwareDestroyProcessTap(process_tap_id_);
            process_tap_id_ = kAudioObjectUnknown;
            return false;
        }

        fprintf(stderr, "Process tap started successfully\n");
        return true;
    } else {
        fprintf(stderr, "macOS 14.4+ required for ProcessTap\n");
        CFRelease(output_uid);
        return false;
    }
}

bool CoreAudioCapture::setup_mic_capture() {
    mic_device_ = find_default_input_device();
    if (mic_device_ == kAudioObjectUnknown) {
        fprintf(stderr, "No input device available\n");
        return false;
    }

    // Set buffer size
    UInt32 buffer_frames = static_cast<UInt32>(config_.frames_per_buffer);
    UInt32 size = sizeof(buffer_frames);
    AudioObjectPropertyAddress buffer_addr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectSetPropertyData(mic_device_, &buffer_addr, 0, nullptr, size, &buffer_frames);

    OSStatus status = AudioDeviceCreateIOProcID(mic_device_, mic_io_proc, this, &mic_io_proc_id_);
    if (status != noErr) {
        fprintf(stderr, "Failed to create mic IO proc: %d\n", (int)status);
        return false;
    }

    status = AudioDeviceStart(mic_device_, mic_io_proc_id_);
    if (status != noErr) {
        fprintf(stderr, "Failed to start mic device: %d\n", (int)status);
        AudioDeviceDestroyIOProcID(mic_device_, mic_io_proc_id_);
        mic_io_proc_id_ = nullptr;
        return false;
    }

    fprintf(stderr, "Mic capture started\n");
    return true;
}

OSStatus CoreAudioCapture::mic_io_proc(AudioDeviceID device,
                                        const AudioTimeStamp* now,
                                        const AudioBufferList* input_data,
                                        const AudioTimeStamp* input_time,
                                        AudioBufferList* output_data,
                                        const AudioTimeStamp* output_time,
                                        void* client_data) {
    auto* self = static_cast<CoreAudioCapture*>(client_data);
    if (!self->running_.load()) return noErr;
    if (!input_data || input_data->mNumberBuffers == 0) return noErr;

    const float* mic_data = static_cast<const float*>(input_data->mBuffers[0].mData);
    size_t frames = input_data->mBuffers[0].mDataByteSize / sizeof(float);

    // Read matching speaker data from ring buffer
    std::vector<float> speaker_data(frames, 0.0f);
    {
        std::lock_guard<std::mutex> lock(self->speaker_mutex_);
        size_t available = (self->speaker_write_pos_ - self->speaker_read_pos_ + SPEAKER_RING_SIZE) % SPEAKER_RING_SIZE;
        size_t to_read = std::min(frames, available);
        for (size_t i = 0; i < to_read; ++i) {
            speaker_data[i] = self->speaker_ring_[self->speaker_read_pos_];
            self->speaker_read_pos_ = (self->speaker_read_pos_ + 1) % SPEAKER_RING_SIZE;
        }
    }

    if (self->callback_) {
        self->callback_(mic_data, speaker_data.data(), frames);
    }

    return noErr;
}

bool CoreAudioCapture::start(const AudioCaptureConfig& config, AudioCaptureCallback callback) {
    if (running_.load()) return false;

    config_ = config;
    callback_ = callback;
    speaker_ring_.resize(SPEAKER_RING_SIZE, 0.0f);
    speaker_write_pos_ = 0;
    speaker_read_pos_ = 0;

    running_ = true;

    if (!setup_mic_capture()) {
        running_ = false;
        teardown();
        return false;
    }

    bool tap_ok = setup_process_tap();
    if (!tap_ok) {
        fprintf(stderr, "Warning: system audio capture unavailable, speaker_ref will be silent\n");
    }

    return true;
}

void CoreAudioCapture::stop() {
    if (!running_.load()) return;
    running_ = false;
    teardown();
}

void CoreAudioCapture::teardown() {
    if (mic_io_proc_id_) {
        AudioDeviceStop(mic_device_, mic_io_proc_id_);
        AudioDeviceDestroyIOProcID(mic_device_, mic_io_proc_id_);
        mic_io_proc_id_ = nullptr;
    }

    if (tap_io_proc_id_) {
        AudioDeviceStop(tap_aggregate_device_, tap_io_proc_id_);
        AudioDeviceDestroyIOProcID(tap_aggregate_device_, tap_io_proc_id_);
        tap_io_proc_id_ = nullptr;
    }

    if (tap_aggregate_device_ != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(tap_aggregate_device_);
        tap_aggregate_device_ = kAudioObjectUnknown;
    }

    if (process_tap_id_ != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(process_tap_id_);
        process_tap_id_ = kAudioObjectUnknown;
    }
}

std::unique_ptr<AudioCapture> create_audio_capture() {
    return std::make_unique<CoreAudioCapture>();
}
