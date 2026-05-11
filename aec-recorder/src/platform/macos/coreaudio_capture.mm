#import "coreaudio_capture.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
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
    static OSStatus io_proc(AudioDeviceID device,
                           const AudioTimeStamp* now,
                           const AudioBufferList* input_data,
                           const AudioTimeStamp* input_time,
                           AudioBufferList* output_data,
                           const AudioTimeStamp* output_time,
                           void* client_data);

    bool create_aggregate_device();
    void destroy_aggregate_device();
    AudioDeviceID find_default_input_device();
    AudioDeviceID find_default_output_device();

    AudioCaptureConfig config_;
    AudioCaptureCallback callback_;
    std::atomic<bool> running_{false};

    AudioDeviceID aggregate_device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID io_proc_id_ = nullptr;

    AudioDeviceID input_device_ = kAudioObjectUnknown;
    AudioDeviceID output_device_ = kAudioObjectUnknown;

    // Process tap for system audio
    AudioObjectID tap_id_ = kAudioObjectUnknown;

    int input_channels_ = 0;
    int output_channels_ = 0;
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
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);
    return device;
}

bool CoreAudioCapture::create_aggregate_device() {
    input_device_ = find_default_input_device();
    output_device_ = find_default_output_device();

    if (input_device_ == kAudioObjectUnknown || output_device_ == kAudioObjectUnknown) {
        fprintf(stderr, "Cannot find default input/output device\n");
        return false;
    }

    // Get device UIDs
    CFStringRef input_uid = nullptr;
    CFStringRef output_uid = nullptr;
    UInt32 size = sizeof(CFStringRef);

    AudioObjectPropertyAddress uid_addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyData(input_device_, &uid_addr, 0, nullptr, &size, &input_uid);
    AudioObjectGetPropertyData(output_device_, &uid_addr, 0, nullptr, &size, &output_uid);

    if (!input_uid || !output_uid) {
        fprintf(stderr, "Cannot get device UIDs\n");
        if (input_uid) CFRelease(input_uid);
        if (output_uid) CFRelease(output_uid);
        return false;
    }

    // Build aggregate device description
    CFMutableDictionaryRef agg_desc = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    CFStringRef agg_uid = CFSTR("com.aec-recorder.aggregate");
    CFDictionarySetValue(agg_desc, CFSTR(kAudioAggregateDeviceUIDKey), agg_uid);
    CFDictionarySetValue(agg_desc, CFSTR(kAudioAggregateDeviceNameKey), CFSTR("AEC Recorder Aggregate"));

    // Private aggregate device (not visible in system prefs)
    int is_private = 1;
    CFNumberRef private_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &is_private);
    CFDictionarySetValue(agg_desc, CFSTR(kAudioAggregateDeviceIsPrivateKey), private_val);
    CFRelease(private_val);

    // Sub-devices: input (mic) and output (speaker for tap)
    CFMutableArrayRef sub_devices = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    // Input sub-device
    CFMutableDictionaryRef input_sub = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFDictionarySetValue(input_sub, CFSTR(kAudioSubDeviceUIDKey), input_uid);
    CFArrayAppendValue(sub_devices, input_sub);
    CFRelease(input_sub);

    // Output sub-device
    CFMutableDictionaryRef output_sub = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFDictionarySetValue(output_sub, CFSTR(kAudioSubDeviceUIDKey), output_uid);
    CFArrayAppendValue(sub_devices, output_sub);
    CFRelease(output_sub);

    CFDictionarySetValue(agg_desc, CFSTR(kAudioAggregateDeviceSubDeviceListKey), sub_devices);
    CFRelease(sub_devices);

    // Create the aggregate device
    OSStatus status = AudioHardwareCreateAggregateDevice(agg_desc, &aggregate_device_);
    CFRelease(agg_desc);
    CFRelease(input_uid);
    CFRelease(output_uid);

    if (status != noErr) {
        fprintf(stderr, "Failed to create aggregate device: %d\n", (int)status);
        return false;
    }

    // The aggregate device combines mic input + output device as sub-devices.
    // The IOProc callback will receive both streams in input_data buffers.

    return true;
}

void CoreAudioCapture::destroy_aggregate_device() {
    if (aggregate_device_ != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregate_device_);
        aggregate_device_ = kAudioObjectUnknown;
    }
}

OSStatus CoreAudioCapture::io_proc(AudioDeviceID device,
                                   const AudioTimeStamp* now,
                                   const AudioBufferList* input_data,
                                   const AudioTimeStamp* input_time,
                                   AudioBufferList* output_data,
                                   const AudioTimeStamp* output_time,
                                   void* client_data) {
    auto* self = static_cast<CoreAudioCapture*>(client_data);
    if (!self->running_.load()) return noErr;

    // The aggregate device provides both mic and system audio in input_data
    // Buffer 0 = mic input, Buffer 1 = system audio (from tap/output device)
    const float* mic_data = nullptr;
    const float* speaker_data = nullptr;
    size_t frames = 0;

    if (input_data && input_data->mNumberBuffers >= 2) {
        mic_data = static_cast<const float*>(input_data->mBuffers[0].mData);
        speaker_data = static_cast<const float*>(input_data->mBuffers[1].mData);
        frames = input_data->mBuffers[0].mDataByteSize / sizeof(float);
    } else if (input_data && input_data->mNumberBuffers == 1) {
        // Interleaved or single buffer - treat as mic only
        mic_data = static_cast<const float*>(input_data->mBuffers[0].mData);
        frames = input_data->mBuffers[0].mDataByteSize / sizeof(float);
    }

    if (mic_data && frames > 0 && self->callback_) {
        self->callback_(mic_data, speaker_data, frames);
    }

    // Silence output to avoid feedback
    if (output_data) {
        for (UInt32 i = 0; i < output_data->mNumberBuffers; ++i) {
            memset(output_data->mBuffers[i].mData, 0, output_data->mBuffers[i].mDataByteSize);
        }
    }

    return noErr;
}

bool CoreAudioCapture::start(const AudioCaptureConfig& config, AudioCaptureCallback callback) {
    if (running_.load()) return false;

    config_ = config;
    callback_ = callback;

    if (!create_aggregate_device()) {
        fprintf(stderr, "Failed to create aggregate device, falling back to mic-only\n");
        // Fallback: use default input device directly
        aggregate_device_ = find_default_input_device();
        if (aggregate_device_ == kAudioObjectUnknown) {
            fprintf(stderr, "No input device available\n");
            return false;
        }
    }

    // Set buffer size
    UInt32 buffer_frames = static_cast<UInt32>(config_.frames_per_buffer);
    UInt32 size = sizeof(buffer_frames);
    AudioObjectPropertyAddress buffer_addr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectSetPropertyData(aggregate_device_, &buffer_addr, 0, nullptr, size, &buffer_frames);

    // Register IO proc
    OSStatus status = AudioDeviceCreateIOProcID(aggregate_device_, io_proc, this, &io_proc_id_);
    if (status != noErr) {
        fprintf(stderr, "Failed to create IO proc: %d\n", (int)status);
        destroy_aggregate_device();
        return false;
    }

    // Start the device
    status = AudioDeviceStart(aggregate_device_, io_proc_id_);
    if (status != noErr) {
        fprintf(stderr, "Failed to start audio device: %d\n", (int)status);
        AudioDeviceDestroyIOProcID(aggregate_device_, io_proc_id_);
        io_proc_id_ = nullptr;
        destroy_aggregate_device();
        return false;
    }

    running_ = true;
    return true;
}

void CoreAudioCapture::stop() {
    if (!running_.load()) return;
    running_ = false;

    if (io_proc_id_) {
        AudioDeviceStop(aggregate_device_, io_proc_id_);
        AudioDeviceDestroyIOProcID(aggregate_device_, io_proc_id_);
        io_proc_id_ = nullptr;
    }

    destroy_aggregate_device();
}

std::unique_ptr<AudioCapture> create_audio_capture() {
    return std::make_unique<CoreAudioCapture>();
}
