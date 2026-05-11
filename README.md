# Voice Isolate Desktop

Prototype desktop audio recorder for isolating microphone speech from speaker playback.

The current goal is simple: capture microphone audio and system speaker audio, process them through the echo-cancellation pipeline, and write three local WAV files for inspection.

## Outputs

Running the recorder creates these files in the current working directory:

- `mic_raw.wav`: raw microphone input
- `speaker_ref.wav`: captured speaker/system audio reference
- `aec3_output.wav`: processed output from the echo-cancellation pipeline

All outputs are written as 16 kHz mono PCM WAV files.

## Current Status

- macOS prototype is implemented with CoreAudio microphone capture and ProcessTap-based system audio capture.
- The audio pipeline captures at 48 kHz, resamples to 16 kHz, and writes synchronized WAV outputs.
- The WebRTC AEC3 integration is not complete yet. The current `AecProcessor` contains a placeholder processing path so the capture, resampling, and file-output pipeline can be tested end to end.
- Windows support is planned in the architecture, but the current repository only contains the macOS capture implementation.

## Requirements

- CMake 3.20 or newer
- A C++17 compiler
- macOS for the current prototype
- macOS system audio capture permission when using ProcessTap

## Build

```bash
cmake -S . -B build
cmake --build build
```

The executable is generated at:

```bash
build/aec-recorder
```

## Run

```bash
./build/aec-recorder
```

Press `Ctrl+C` to stop recording. The program finalizes the WAV headers before exiting.

For a useful test, play speech or music through the speakers while speaking into the microphone, then compare `mic_raw.wav`, `speaker_ref.wav`, and `aec3_output.wav` in an audio editor.

## Repository Layout

```text
.
├── CMakeLists.txt
├── docs/
│   └── aec3/
│       └── AEC_REALTIME_PLAN.md
├── src/
│   ├── core/
│   │   ├── aec_processor.*
│   │   ├── resampler.*
│   │   └── ring_buffer.*
│   ├── output/
│   │   └── wav_writer.*
│   ├── platform/
│   │   ├── audio_capture.h
│   │   └── macos/
│   │       └── coreaudio_capture.*
│   └── main.cpp
└── README.md
```

## Design Notes

The detailed design plan is in:

```text
docs/aec3/AEC_REALTIME_PLAN.md
```

The planned production direction is to replace the placeholder processor with WebRTC AEC3 while keeping the same three-output validation flow.
