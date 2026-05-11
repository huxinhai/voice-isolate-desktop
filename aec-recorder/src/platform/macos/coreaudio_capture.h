#pragma once
#include "platform/audio_capture.h"
#include <memory>

std::unique_ptr<AudioCapture> create_audio_capture();
