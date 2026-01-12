# CLAUDE.md - DirettaRendererUPnP-X Project Brief

## Overview

DirettaRendererUPnP-X is a community fork of DirettaRendererUPnP - a native UPnP/DLNA audio renderer that streams high-resolution audio (up to DSD1024/PCM 1536kHz) using the Diretta protocol for bit-perfect playback.

**Key differentiation from upstream (v1.2.1):**
- Inherits `DIRETTA::Sync` directly (vs `DIRETTA::SyncBuffer`) for finer timing control
- `getNewStream()` callback (pull model) vs SDK-managed push model
- Extracted `DirettaRingBuffer` class for lock-free SPSC operations
- Lock-free audio hot path with `RingAccessGuard` pattern
- Full format transition control with silence buffers and reopening
- DSD byte swap support for little-endian targets

## Architecture

```
┌─────────────────────────────┐
│  UPnP Control Point         │  (JPlay, BubbleUPnP, Roon, etc.)
└─────────────┬───────────────┘
              │ UPnP/DLNA Protocol (HTTP/SOAP/SSDP)
              ▼
┌───────────────────────────────────────────────────────────────┐
│  DirettaRendererUPnP-X                                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────┐  │
│  │   UPnPDevice    │─▶│ DirettaRenderer │─▶│  AudioEngine  │  │
│  │ (discovery,     │  │ (orchestrator,  │  │ (FFmpeg       │  │
│  │  transport)     │  │  threading)     │  │  decode)      │  │
│  └─────────────────┘  └────────┬────────┘  └───────┬───────┘  │
│                                │                   │          │
│                                ▼                   ▼          │
│                  ┌─────────────────────────────────────────┐  │
│                  │           DirettaSync                   │  │
│                  │  ┌───────────────────────────────────┐  │  │
│                  │  │       DirettaRingBuffer           │  │  │
│                  │  │  (lock-free SPSC, format conv.)   │  │  │
│                  │  └───────────────────────────────────┘  │  │
│                  │              │                          │  │
│                  │              ▼ getNewStream() callback  │  │
│                  │  ┌───────────────────────────────────┐  │  │
│                  │  │      DIRETTA::Sync (SDK)          │  │  │
│                  │  └───────────────────────────────────┘  │  │
│                  └─────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
              │ Diretta Protocol (UDP/Ethernet)
              ▼
┌─────────────────────────────┐
│      Diretta TARGET         │  (Memory Play, GentooPlayer, etc.)
└─────────────┬───────────────┘
              ▼
┌─────────────────────────────┐
│            DAC              │
└─────────────────────────────┘
```

## Key Files

| File | Purpose | Hot Path? |
|------|---------|-----------|
| `src/DirettaSync.cpp/h` | Inherits `DIRETTA::Sync`, manages ring buffer, format config | Yes |
| `src/DirettaRingBuffer.h` | Lock-free SPSC ring buffer with format conversion methods | **Critical** |
| `src/DirettaRenderer.cpp/h` | Orchestrates playback, UPnP callbacks, threading | Partial |
| `src/AudioEngine.cpp/h` | FFmpeg decode, format detection, sample reading | No |
| `src/UPnPDevice.cpp/hpp` | UPnP/DLNA protocol, SSDP discovery, HTTP server | No |
| `src/ProtocolInfoBuilder.h` | UPnP protocol info generation | No |
| `src/main.cpp` | CLI parsing, initialization, signal handling | No |

## Diretta SDK Reference

**SDK Location:** `../DirettaHostSDK_147_19/` (v1.47.19)

### Key SDK Headers

| Header | Purpose |
|--------|---------|
| `Host/Sync.hpp` | Base class `DIRETTA::Sync` - stream transmission, thread modes |
| `Host/Format.hpp` | `FormatID`, `FormatConfigure` - 64-bit format bitmasks |
| `Host/Find.hpp` | Target discovery |
| `Host/Stream.hpp` | `DIRETTA::Stream` data structure |
| `Host/Profile.hpp` | Transmission profiles |
| `Host/Connection.hpp` | Base connection class |

### SDK Thread Modes (`DIRETTA::Sync::THRED_MODE`)

```cpp
CRITICAL = 1       // High priority sending thread
NOSHORTSLEEP = 2   // Busy loop for short waits
NOSLEEP4CORE = 4   // Disable busy loop if <4 cores
OCCUPIED = 16      // Pin thread to CPU
NOSLEEPFORCE = 2048// Force busy loop
NOJUMBOFRAME = 8192// Disable jumbo frames
```

### SDK Format Bitmasks (from `Format.hpp`)

```cpp
// Channels
CHA_2 = 0x02  // Stereo

// PCM formats
FMT_PCM_SIGNED_16 = 0x0200
FMT_PCM_SIGNED_24 = 0x0400
FMT_PCM_SIGNED_32 = 0x0800

// DSD formats
FMT_DSD1 = 0x010000      // DSD 1-bit
FMT_DSD_LSB = 0x100000   // DSF (LSB first)
FMT_DSD_MSB = 0x200000   // DFF (MSB first)
FMT_DSD_LITTLE = 0x400000
FMT_DSD_BIG = 0x800000
FMT_DSD_SIZ_32 = 0x02000000  // 32-bit grouping

// Sample rates (multipliers of 44.1k/48k base)
RAT_44100 = 0x0200_00000000
RAT_48000 = 0x0400_00000000
RAT_MP2 = 0x1000_00000000    // 2x (88.2/96k)
RAT_MP4 = 0x2000_00000000    // 4x (176.4/192k)
// ... up to RAT_MP4096 for DSD1024
```

## Audio Hot Path

The following functions are in the critical audio path:

```
AudioEngine::readSamples()
    └─▶ DirettaSync::sendAudio()
            └─▶ RingAccessGuard (atomic increment)
            └─▶ DirettaRingBuffer::push*()
                    └─▶ std::memcpy / byte manipulation

DirettaSync::getNewStream()  [SDK callback, runs in SDK thread]
    └─▶ DirettaRingBuffer::pop()
            └─▶ std::memcpy
```

**Rules for hot path code:**
- No heap allocations
- No mutex locks (use atomics via `RingAccessGuard`)
- Bitmask modulo (power-of-2 buffer size)
- Predictable branch patterns

## Lock-Free Patterns

### Ring Buffer Access (readers - `sendAudio()`)
```cpp
// From DirettaSync.cpp
class RingAccessGuard {
    RingAccessGuard(std::atomic<int>& users, const std::atomic<bool>& reconfiguring)
        : users_(users), active_(false) {
        if (reconfiguring.load(std::memory_order_acquire)) return;
        users_.fetch_add(1, std::memory_order_acq_rel);
        if (reconfiguring.load(std::memory_order_acquire)) {
            users_.fetch_sub(1, std::memory_order_acq_rel);
            return;
        }
        active_ = true;
    }
    ~RingAccessGuard() {
        if (active_) users_.fetch_sub(1, std::memory_order_acq_rel);
    }
    bool active() const { return active_; }
};
```

### Reconfiguration (writer - format changes)
```cpp
class ReconfigureGuard {
    explicit ReconfigureGuard(DirettaSync& sync) : sync_(sync) {
        sync_.beginReconfigure();  // Sets m_reconfiguring = true, waits for m_ringUsers == 0
    }
    ~ReconfigureGuard() { sync_.endReconfigure(); }
};
```

## Format Support

| Format | Bit Depth | Sample Rates | Ring Buffer Method |
|--------|-----------|--------------|-------------------|
| PCM | 16-bit | 44.1kHz - 384kHz | `push16To32()` |
| PCM | 24-bit | 44.1kHz - 384kHz | `push24BitPacked()` (auto-detects LSB/MSB alignment) |
| PCM | 32-bit | 44.1kHz - 384kHz | `push()` |
| DSD | 1-bit | DSD64 - DSD512 | `pushDSDPlanar()` (planar→interleaved, optional bit reversal & byte swap) |

### S24 Format Auto-Detection

The ring buffer auto-detects 24-bit sample alignment on first push:
- **LSB-aligned**: bytes 0-2 contain data (standard S24_LE)
- **MSB-aligned**: bytes 1-3 contain data (S24_32BE-style)

## Buffer Configuration

From `DirettaSync.h`:

```cpp
namespace DirettaBuffer {
    constexpr float DSD_BUFFER_SECONDS = 0.8f;
    constexpr float PCM_BUFFER_SECONDS = 1.0f;

    constexpr size_t DSD_PREFILL_MS = 200;
    constexpr size_t PCM_PREFILL_MS = 50;
    constexpr size_t PCM_LOWRATE_PREFILL_MS = 100;

    constexpr unsigned int DAC_STABILIZATION_MS = 100;
    constexpr unsigned int ONLINE_WAIT_MS = 2000;
    constexpr unsigned int FORMAT_SWITCH_DELAY_MS = 800;
    constexpr unsigned int POST_ONLINE_SILENCE_BUFFERS = 50;

    constexpr size_t MIN_BUFFER_BYTES = 3072000;  // ~2 seconds at 192kHz
    constexpr size_t MAX_BUFFER_BYTES = 16777216; // 16MB
}
```

## Coding Conventions

- **Language:** C++17
- **Member prefix:** `m_` for instance members
- **Constants:** `constexpr` in namespace or `static constexpr` in class
- **Atomics:** Use `std::memory_order_acquire`/`release` appropriately
- **Alignment:** `alignas(64)` for cache-line separation on atomics
- **Indentation:** 4 spaces
- **Line length:** max 120 characters
- **Logging format:** `[ComponentName] Message`

### Commit Messages

```
type: short description

Longer explanation if needed.

Co-Authored-By: Claude <noreply@anthropic.com>
```

Types: `feat`, `fix`, `perf`, `refactor`, `test`, `chore`, `docs`

## Build & Run

```bash
# Build (auto-detects architecture)
make

# Build with specific variant
make ARCH_NAME=x64-linux-15zen4   # AMD Zen 4
make ARCH_NAME=x64-linux-15v3     # x64 with AVX2 (most common)
make ARCH_NAME=aarch64-linux-15   # Raspberry Pi 4 (4KB pages)
make ARCH_NAME=aarch64-linux-15k16 # Raspberry Pi 5 (16KB pages)

# Production build (disables SDK logging)
make NOLOG=1

# Clean and rebuild
make clean && make

# Show build info
make info

# Run with target selection
sudo ./bin/DirettaRendererUPnP --list-targets
sudo ./bin/DirettaRendererUPnP --target 1 --verbose
```

**Note:** Building requires Linux. macOS builds are not supported due to missing FFmpeg/libupnp compatibility.

## SDK Library Variants

Located in `../DirettaHostSDK_147_19/lib/`:

| Pattern | Description |
|---------|-------------|
| `x64-linux-15v2` | x86-64 baseline |
| `x64-linux-15v3` | x86-64 with AVX2 |
| `x64-linux-15v4` | x86-64 with AVX-512 |
| `x64-linux-15zen4` | AMD Zen 4 optimized |
| `aarch64-linux-15` | ARM64 (4KB pages) |
| `aarch64-linux-15k16` | ARM64 (16KB pages, Pi 5) |
| `riscv64-linux-15` | RISC-V 64-bit |
| `*-musl*` | musl libc variants |
| `*-nolog` | Logging disabled |

## Dependencies

- **Diretta Host SDK v1.47** - Proprietary (personal use only)
- **FFmpeg** - libavformat, libavcodec, libavutil, libswresample
- **libupnp** - UPnP/DLNA implementation
- **pthread** - Threading

Install on Fedora:
```bash
sudo dnf install gcc-c++ make ffmpeg-free-devel libupnp-devel
```

Install on Ubuntu/Debian:
```bash
sudo apt install build-essential libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libupnp-dev
```

## Current Work & Plans

### Completed
- [x] Lock-free audio path with `RingAccessGuard`
- [x] Power-of-2 bitmask modulo in ring buffer (`mask_ = size_ - 1`)
- [x] Cache-line separated atomics (`alignas(64)`)
- [x] S24 pack mode auto-detection
- [x] DSD byte swap for little-endian targets
- [x] Full format transition with `reopenForFormatChange()`

### In Progress
- [ ] DSD→PCM transition optimization (see `PLAN-DSD-PCM-TRANSITION.md`)

### Potential Future Work
- [ ] SIMD optimizations for format conversion (AVX2 24-bit packing, 16-to-32 upsampling)
- [ ] SIMD DSD interleaving
- [ ] Low-latency buffer mode (~300ms)

## Format Transition Handling

From `PLAN-DSD-PCM-TRANSITION.md`:

| From | To | Handling |
|------|-----|----------|
| PCM | Same PCM | Quick resume (buffer clear) |
| PCM | Different PCM | `reopenForFormatChange()` |
| PCM | DSD | `reopenForFormatChange()` |
| DSD | Same DSD | Quick resume (buffer clear) |
| DSD | Different DSD | `reopenForFormatChange()` |
| **DSD** | **PCM** | **Full `close()` + 600ms + fresh `open()`** (I2S targets) |

## Troubleshooting

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| No audio | Target not running | `--list-targets` |
| Dropouts | Buffer underrun | Increase buffer, check network |
| Pink noise (DSD) | Bit reversal wrong | Check DSF vs DFF detection |
| Gapless gaps | Format change | Expected for sample rate changes |
| DSD→PCM clicks | I2S target sensitivity | See `PLAN-DSD-PCM-TRANSITION.md` |

## Key Constraints

1. **No commercial use** - Diretta SDK is personal use only
2. **Linux only** - No Windows/macOS support
3. **Root required** - Network operations need elevated privileges
4. **Jumbo frames recommended** - 9000+ MTU for hi-res audio

## Working with This Codebase

When modifying this codebase:

1. **Check if hot path** - `DirettaRingBuffer`, `sendAudio()`, `getNewStream()` need extra scrutiny
2. **Test with DSD** - DSD is more timing-sensitive than PCM
3. **Verify lock-free** - No mutex in audio path
4. **Check alignment** - New buffers should be `alignas(64)` if atomics are involved
5. **Test format transitions** - PCM↔DSD transitions are most problematic

## Reference Documents

| Document | Purpose |
|----------|---------|
| `FORK_CHANGES.md` | Detailed diff from original v1.2.1 |
| `PLAN-DSD-PCM-TRANSITION.md` | DSD→PCM transition fix plan |
| `README.md` | User documentation |
| `docs/TROUBLESHOOTING.md` | User troubleshooting guide |
| `docs/CONFIGURATION.md` | Configuration reference |

## Credits

- Original DirettaRendererUPnP by Dominique COMET (cometdom)
- MPD Diretta Output Plugin v0.4.0 for `DIRETTA::Sync` API patterns
- Diretta Host SDK by Yu Harada
- Claude Code for refactoring assistance
