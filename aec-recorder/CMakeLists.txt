cmake_minimum_required(VERSION 3.20)
project(aec-recorder LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(AEC_ENABLE_WEBRTC "Enable WebRTC AEC3 backend" OFF)

set(CORE_SOURCES
    src/core/ring_buffer.cpp
    src/core/resampler.cpp
    src/core/aec_processor.cpp
)

set(OUTPUT_SOURCES
    src/output/wav_writer.cpp
)

if(APPLE)
    set(PLATFORM_SOURCES
        src/platform/macos/coreaudio_capture.mm
    )
elseif(WIN32)
    set(PLATFORM_SOURCES
        src/platform/windows/wasapi_capture.cpp
    )
endif()

add_executable(aec-recorder
    src/main.cpp
    ${CORE_SOURCES}
    ${OUTPUT_SOURCES}
    ${PLATFORM_SOURCES}
)

target_include_directories(aec-recorder PRIVATE src)

if(APPLE)
    target_link_libraries(aec-recorder PRIVATE
        "-framework CoreAudio"
        "-framework AudioToolbox"
        "-framework CoreFoundation"
    )
    target_compile_options(aec-recorder PRIVATE -fobjc-arc)
elseif(WIN32)
    target_link_libraries(aec-recorder PRIVATE
        ole32
        winmm
        ksuser
    )
endif()

if(AEC_ENABLE_WEBRTC)
    target_compile_definitions(aec-recorder PRIVATE AEC_USE_WEBRTC=1)
    # TODO: link webrtc aec3 library
endif()
