# 面试场景实时AEC + WebSocket方案设计

## Context

面试场景中，从麦克风录音里去除扬声器播放的声音（对方说话声），只保留自己的声音，实时通过WebSocket发送到后端做ASR。延迟要求200ms以内。需要支持macOS和Windows双端。

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
- macOS VPIO 会自动启用AGC和噪声抑制，可能影响ASR质量
- Windows上系统AEC质量参差不齐，依赖声卡驱动
- 某些场景下（外接音箱、蓝牙耳机）效果会下降

---

## 推荐方案：方案A（C++同步采集 + WebRTC AEC3）

**理由：**
1. 之前的问题就是对齐，方案A从根本上解决对齐问题
2. 面试场景对消音质量要求高（残留回声会被ASR识别为噪声文本）
3. WebRTC AEC3是业界最成熟的开源方案
4. 跨平台统一架构，维护成本可控
5. 200ms延迟预算充裕（AEC处理本身只需10-20ms）

---

## 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    应用层 (Electron/CLI)                   │
├─────────────────────────────────────────────────────────┤
│                  C++ 核心库 (libaec_stream)                │
│                                                           │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────┐  │
│  │ Platform Audio│   │  AEC Engine  │   │  WebSocket  │  │
│  │   Capture    │──>│  (WebRTC)    │──>│   Sender    │  │
│  │              │   │              │   │             │  │
│  │ • Mic Input  │   │ • analyze()  │   │ • PCM16/Opus│  │
│  │ • Speaker Out│   │ • process()  │   │ • 实时推送   │  │
│  └──────────────┘   └──────────────┘   └─────────────┘  │
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
- 采样率：16000Hz（ASR标准，降低计算量）
- 帧大小：160 samples（10ms）
- 通道：单声道

**为什么用16kHz而不是48kHz：**
- ASR后端通常接受16kHz
- AEC在16kHz下计算量是48kHz的1/9
- 减少WebSocket带宽
- 从48kHz采集后重采样到16kHz即可

### 3. WebSocket发送模块

```
数据格式：PCM16 @ 16kHz mono
发送间隔：每100ms发送一次（1600 samples = 3200 bytes）
协议：二进制WebSocket帧

帧格式：
[4 bytes: timestamp_ms][N bytes: PCM16 data]
```

**可选：Opus编码**
- 如果带宽有限，可以用Opus编码（20ms帧，约3.2kbps @ 16kbps bitrate）
- 但会增加约5ms编码延迟
- 建议先用PCM16，带宽不是问题时最简单

---

## 延迟分析

```
采集延迟:     ~10ms (音频硬件buffer)
重采样:       ~1ms  (48k→16k)
AEC处理:      ~10ms (WebRTC AEC3 一帧)
缓冲+打包:    ~100ms (攒够100ms数据发送)
WebSocket传输: ~5ms  (局域网/本地)
─────────────────────────────────
总计:         ~126ms < 200ms ✓
```

---

## 文件结构规划

```
aec-stream/
├── CMakeLists.txt                 # 顶层构建
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
│   ├── transport/
│   │   └── ws_sender.h/cpp        # WebSocket发送
│   └── main.cpp                   # 入口/CLI
├── third_party/
│   └── webrtc/                    # WebRTC AEC3 模块（精简提取）
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
3. 验证两路数据对齐（输出到WAV文件，人工检查波形）

### Phase 2: 集成WebRTC AEC3（1-2天）
4. 提取WebRTC AEC3模块（或用预编译库）
5. 实现48k→16k重采样
6. 接入AEC处理，验证消音效果

### Phase 3: WebSocket传输（半天）
7. 集成轻量WebSocket库（如 libwebsockets 或 ixwebsocket）
8. 实现PCM16实时推送
9. 写一个简单的后端接收端验证

### Phase 4: Windows移植（2-3天）
10. 实现WASAPI双流采集
11. 实现QPC时间戳对齐
12. 验证跨平台构建

---

## 验证方法

1. **对齐验证：** 播放已知信号（如chirp），同时录制麦克风和loopback，检查两路波形的时间偏移是否<1ms
2. **AEC效果验证：** 播放音乐/语音，同时对着麦克风说话，检查输出中是否只有自己的声音
3. **延迟验证：** 在后端记录收到音频的时间戳，与说话时间对比
4. **ASR验证：** 将输出接入ASR引擎，检查识别准确率
