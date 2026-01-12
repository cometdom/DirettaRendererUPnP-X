# Plan: Complete Reopen for DSD→PCM Transitions

## Problem
DSD→PCM format transitions cause noise/scratches on I2S Diretta targets. The current silence-flushing approach in `reopenForFormatChange()` is insufficient for I2S targets which are more timing-sensitive than USB.

## Root Cause
- DSD silence byte (0x69) vs PCM silence byte (0x00) mismatch
- I2S sends both data AND timing signal, requiring cleaner transitions
- Target's internal buffer (~10ms) may still contain DSD data when PCM starts

## Proposed Solution
Implement **complete close/reopen** specifically for DSD→PCM transitions, similar to Dominique's approach in dev-v1.3.0.

## Changes Required

### 1. DirettaSync.cpp - Modify `open()`

In the format change detection block (~line 363-372), add special handling:

```cpp
} else {
    // Format change detected
    bool wasDSD = m_previousFormat.isDSD;
    bool nowPCM = !format.isDSD;

    if (wasDSD && nowPCM) {
        // DSD→PCM: Complete close/reopen for clean transition
        std::cout << "[DirettaSync] DSD->PCM transition - full close/reopen" << std::endl;
        close();  // Full close (sends silence, disconnects properly)
        std::this_thread::sleep_for(std::chrono::milliseconds(600));
        // Continue to full open path below (needFullConnect = true)
    } else {
        // Other format changes: use existing reopenForFormatChange()
        std::cout << "[DirettaSync] Format change - reopen" << std::endl;
        if (!reopenForFormatChange()) {
            std::cerr << "[DirettaSync] Failed to reopen for format change" << std::endl;
            return false;
        }
    }
    needFullConnect = true;
}
```

### 2. DirettaSync.cpp - Ensure `close()` purges with correct silence

In `close()`, before sending shutdown silence, ensure ring buffer uses DSD silence if in DSD mode:

```cpp
void DirettaSync::close() {
    // ... existing code ...

    // Request shutdown silence with format-appropriate byte
    int silenceBuffers = m_isDsdMode.load(std::memory_order_acquire) ? 50 : 20;
    requestShutdownSilence(silenceBuffers);

    // ... rest of close() ...
}
```

This is already correct in current code.

### 3. Consider adding post-open stabilization delay

After DSD→PCM reopen completes, add extra stabilization:

```cpp
// After play() and waitForOnline() for DSD→PCM case:
if (wasDsdToPcmTransition) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}
```

## Transition Matrix

| From | To | Handling |
|------|-----|----------|
| PCM | Same PCM | Quick resume (buffer clear only) |
| PCM | Different PCM | `reopenForFormatChange()` |
| PCM | DSD | `reopenForFormatChange()` |
| DSD | Same DSD | Quick resume (buffer clear only) |
| DSD | Different DSD | `reopenForFormatChange()` |
| **DSD** | **PCM** | **Full `close()` + 600ms + fresh `open()`** |

## Timing Summary

- DSD→PCM transition total time: ~800-1000ms
  - close() with silence flush: ~150ms
  - Post-close delay: 600ms
  - Reconnect + setSink: ~200ms
  - Post-open stabilization: 200ms (optional)

## Files to Modify

1. `src/DirettaSync.cpp`:
   - `open()` - Add DSD→PCM detection and full close path
   - Possibly add a helper `bool isDsdToPcmTransition()` for clarity

## Testing

1. Play DSD512 file → immediately play 352.8kHz PCM file
2. Listen for clicks/scratches during transition
3. Test with I2S target (primary concern)
4. Verify USB target still works (regression test)

## Notes

- This approach trades transition speed for reliability on I2S targets
- USB targets may not need this, but using it universally is safer
- The 600ms delay matches Dominique's tested value
- Could make delay configurable via `DirettaConfig::dsdToPcmDelayMs` if needed
