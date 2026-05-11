# 面试场景实时AEC3音频输出方案设计

## Context

面试场景中，从麦克风录音里去除扬声器播放的声音（对方说话声），只保留自己的声音。

当前阶段只做本地音频采集、对齐、AEC3处理和音频文件输出。程序运行后需要输出3个音频文件：

1. 原始麦克风音频：`mic_raw.wav`
2. 扬声器参考音频：`speaker_ref.wav`
3. AEC3处理后的音频：`aec3_output.wav`

需要支持macOS和Windows双端。延迟要求仍以200ms以内为实时能力参考，但当前验收重点是三路音频能正确生成，并且 `aec3_output.wav` 中扬声器回声明显降低。

之前的方案（Swift层分别采集麦克风和系统音频再对齐）存在对齐困难的bug，导致消音效果差。

---

## 方案对比分析

### 方案A：C++层同步采集 + AEC处理

**原理：** 在同一个C++进程中，用同一个音频回调时钟同时采集麦克风和扬声器（loopback），保证帧级别对齐，然后做AEC。

**macOS实现：**
- 使用 `AudioHardwareCreateProcessTap`（macOS 14.4+）或 `kAudioDevicePropertyScopeOutput` 获取系统音频
- 使用 CoreAudio HAL 的 Aggregate Device 将麦克风和系统输出合并为一个设备
- 在同一个 `IOProc` 回调中同时拿到两路数据 → 天然对齐

**Windows实现：**
- 使用 WASAPI Loopback 模式捕获扬声器输出
- 使用 WASAPI 捕获麦克风输入
- 两者共享同一个 `IAudioClock`，或用 `QPC` 时间戳对齐

**AEC引擎选择：**
- WebRTC AEC3（开源，成熟，10ms帧处理）
- SpeexDSP（轻量，但效果不如WebRTC）

**优点：**
- 帧级别对齐，消音效果最好
- 完全可控，可以调参
- 跨平台统一架构（C++核心 + 平台采集层）

**缺点：**
- 开发量大，需要自己集成WebRTC AEC3
- macOS系统音频捕获需要权限（Screen Recording或AudioTap）
- Windows WASAPI Loopback有约10ms固有延迟

---

### 方案B：系统级回声消除（VoiceProcessingIO）

**原理：** 利用操作系统内置的回声消除能力。

**macOS实现：**
- 使用 `kAudioUnitSubType_VoiceProcessingIO`（VPIO）
- 这是macOS/iOS内置的回声消除AudioUnit
- 系统自动处理麦克风输入和扬声器输出的对齐和回声消除
- 输出就是干净的人声

**Windows实现：**
- 使用 `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` + `Voice Capture DSP`（MFT）
- 或者使用 Windows Audio Processing Object (APO) 的 AEC
- 或者 WebRTC 的 `AudioProcessing` 模块（内部用了Windows的AEC）

**优点：**
- 开发量小，系统帮你做对齐和AEC
- macOS上效果不错（FaceTime/Zoom都用这个）
- 不需要单独捕获系统音频

**缺点：**
- 黑盒，无法调参
- macOS VPIO 会自动启用AGC和噪声抑制，可能影响后续语音处理质量
- Windows上系统AEC质量参差不齐，依赖声卡驱动
- 某些场景下（外接音箱、蓝牙耳机）效果会下降

---

## 推荐方案：方案A（C++同步采集 + WebRTC AEC3 + 本地WAV输出）

**理由：**
1. 之前的问题就是对齐，方案A从根本上解决对齐问题
2. 面试场景对消音质量要求高，残留回声会混进目标人声
3. WebRTC AEC3是业界最成熟的开源方案
4. 跨平台统一架构，维护成本可控
5. 当前阶段先输出本地音频文件，方便直接检查波形和听感，降低验证复杂度

---

## 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    应用层 (CLI/测试程序)                    │
├─────────────────────────────────────────────────────────┤
│                  C++ 核心库 (libaec_recorder)              │
│                                                           │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐ │
│  │ Platform Audio│   │  AEC Engine  │   │ Audio Writer │ │
│  │   Capture    │──>│  (WebRTC)    │──>│    (WAV)     │ │
│  │              │   │              │   │              │ │
│  │ • Mic Input  │   │ • analyze()  │   │ • mic_raw    │ │
│  │ • Speaker Out│   │ • process()  │   │ • speaker_ref│ │
│  │              │   │              │   │ • aec3_output│ │
│  └──────────────┘   └──────────────┘   └──────────────┘ │
├─────────────────────────────────────────────────────────┤
│              平台抽象层 (Platform Abstraction)              │
│                                                           │
│  macOS:                        Windows:                   │
│  • CoreAudio Aggregate Device  • WASAPI Capture           │
│  • 或 AudioTap + HAL Input     • WASAPI Loopback          │
│  • 同一IOProc回调              • 共享QPC时钟对齐           │
└─────────────────────────────────────────────────────────┘
```

---

## 关键模块设计

### 1. 平台音频采集层

#### macOS: CoreAudio Aggregate Device 方案

核心思路：创建一个Aggregate Device，包含麦克风(input)和系统输出(output)，在同一个IOProc中同时获取两路数据 → 零延迟对齐。

**关键API：**
- `AudioHardwareCreateAggregateDevice` — 创建聚合设备
- `AudioDeviceCreateIOProcID` — 注册IO回调
- 回调中 `inInputData` 包含麦克风，通过 tap 获取 render 数据

**备选方案（更简单）：**
- 使用 `kAudioUnitSubType_HALOutput` 的全双工模式
- Input scope 接麦克风，Output scope 接扬声器
- 在 render callback 中同时拿到两路

#### Windows: WASAPI 双流方案

核心思路：用两个WASAPI流，共享QPC时钟。Loopback流捕获扬声器输出，Capture流捕获麦克风，用QPC时间戳做帧级对齐（精度<1ms）。

**关键API：**
- `IAudioClient::Initialize` (AUDCLNT_STREAMFLAGS_LOOPBACK) — 扬声器捕获
- `IAudioClient::Initialize` (标准捕获) — 麦克风
- `IAudioCaptureClient::GetBuffer` + `GetPosition` — 带时间戳的数据

**对齐策略：**
- 两个流都用 `IAudioClock::GetPosition` 获取设备时间
- 或用 `QueryPerformanceCounter` 在每次 GetBuffer 时打时间戳
- 用环形缓冲区 + 时间戳匹配做帧对齐
- WebRTC AEC3 内部也有延迟估计，可以容忍±几ms的偏差

### 2. AEC引擎（WebRTC AEC3）

```cpp
// 核心接口
class AecProcessor {
public:
    AecProcessor(int sample_rate = 16000, int channels = 1);
    
    // 喂入扬声器数据（参考信号）
    void AnalyzeRender(const float* data, int frames);
    
    // 处理麦克风数据，输出消除回声后的干净音频
    void ProcessCapture(float* data, int frames);
};
```

**参数选择：**
- 采样率：16000Hz（语音处理常用规格，降低计算量）
- 帧大小：160 samples（10ms）
- 通道：单声道

**为什么用16kHz而不是48kHz：**
- 人声频段下16kHz已经足够验证AEC效果
- AEC在16kHz下计算量是48kHz的1/9
- 输出文件更小，便于快速验证
- 从48kHz采集后重采样到16kHz即可

### 3. 音频文件输出模块

```
输出格式：WAV / PCM16 / 16kHz / mono
输出文件：
- mic_raw.wav：原始麦克风输入
- speaker_ref.wav：扬声器/系统声音参考信号
- aec3_output.wav：WebRTC AEC3处理后的音频
```

**写入策略：**
- 每处理完一帧10ms音频，同时写入三路WAV
- 录制开始时先写占位WAV头
- 录制结束时回填 `RIFF` 和 `data` 长度
- 三个文件必须使用同样的采样率、通道数和起始时间，方便后续波形对比
- 如果采集端是48kHz，建议同时保留内部48kHz处理链路，再统一输出16kHz PCM16

---

## 延迟分析

当前阶段只输出本地文件，延迟主要用于评估后续实时化可行性。

```
采集延迟:     ~10ms (音频硬件buffer)
重采样:       ~1ms  (48k→16k)
AEC处理:      ~10ms (WebRTC AEC3 一帧)
文件写入:      ~1ms  (顺序写WAV)
─────────────────────────────────
单帧链路:     ~22ms < 200ms ✓
```

---

## 文件结构规划

```
docs/
└── aec3/
    └── AEC_REALTIME_PLAN.md       # 当前方案文档

modules/
└── aec3-recorder/
    ├── CMakeLists.txt             # AEC3录音模块构建
    ├── include/
    │   └── aec3_recorder/
    │       ├── recorder.h         # 对外入口
    │       └── audio_frame.h      # 统一音频帧结构
    ├── src/
    │   ├── core/
    │   │   ├── aec_processor.h/cpp    # WebRTC AEC3 封装
    │   │   ├── resampler.h/cpp        # 48k→16k 重采样
    │   │   └── ring_buffer.h/cpp      # 环形缓冲区
    │   ├── platform/
    │   │   ├── audio_capture.h        # 平台抽象接口
    │   │   ├── macos/
    │   │   │   └── coreaudio_capture.mm  # macOS CoreAudio实现
    │   │   └── windows/
    │   │       └── wasapi_capture.cpp    # Windows WASAPI实现
    │   ├── output/
    │   │   └── wav_writer.h/cpp       # 三路WAV文件输出
    │   └── cli/
    │       └── main.cpp               # 测试CLI入口
    ├── third_party/
    │   └── webrtc/                # WebRTC AEC3 模块（精简提取）
    └── scripts/
        ├── build_mac.sh
        └── build_win.bat
```

---

## macOS 对齐方案详细设计（核心难点）

之前对不齐的根本原因：**麦克风和系统音频在不同的回调线程/时钟域中采集**。

### 解决方案：单IOProc全双工

```
1. 创建 Aggregate Device = 默认麦克风 + 默认输出设备
2. 注册一个 IOProc
3. 在 IOProc 回调中：
   - inInputData → 麦克风数据（capture）
   - 通过 AudioDeviceRead 或 tap → 扬声器数据（render）
4. 两路数据在同一回调中获得 → 天然对齐，无需时间戳匹配
```

### 备选方案：VPIO + 手动render注入

```
1. 使用 VoiceProcessingIO AudioUnit
2. 它自动做AEC，但我们可以关闭内置AEC
3. 用它的全双工能力保证对齐
4. 自己做AEC处理
```

### 最推荐：CoreAudio HAL 全双工 + ProcessTap

```
1. 用 AudioHardwareCreateProcessTap 捕获系统音频（render参考）
2. 用 HAL Input 捕获麦克风
3. 关键：两者都挂在同一个 AudioDevice 的 IOProc 上
4. 如果设备不同，用 Aggregate Device 合并
5. IOProc 的 inTimeStamp 保证两路数据的时间对齐
```

---

## 实施步骤

### Phase 1: macOS 原型（1-2天）
1. 搭建CMake项目骨架
2. 实现CoreAudio全双工采集（Aggregate Device方案）
3. 实现WAV输出模块
4. 输出 `mic_raw.wav` 和 `speaker_ref.wav`，人工检查两路波形是否对齐

### Phase 2: 集成WebRTC AEC3（1-2天）
5. 提取WebRTC AEC3模块（或用预编译库）
6. 实现48k→16k重采样
7. 接入AEC处理，输出 `aec3_output.wav`
8. 对比三路音频，验证消音效果

### Phase 3: Windows移植（2-3天）
9. 实现WASAPI双流采集
10. 实现QPC时间戳对齐
11. 输出同样的三路WAV文件
12. 验证跨平台构建和音频效果

---

## 验证方法

1. **对齐验证：** 播放已知信号（如chirp），同时录制麦克风和loopback，检查两路波形的时间偏移是否<1ms
2. **输出文件验证：** 每次运行后必须生成 `mic_raw.wav`、`speaker_ref.wav`、`aec3_output.wav` 三个文件
3. **AEC效果验证：** 播放音乐/语音，同时对着麦克风说话，检查 `aec3_output.wav` 中是否主要保留自己的声音
4. **波形验证：** 用Audacity等工具对比三路波形，确认 `aec3_output.wav` 中扬声器参考信号被明显压低
