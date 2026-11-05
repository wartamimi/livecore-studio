// LiveCore Studio: a small C wrapper around Blackmagic Design's DeckLink API (capture only).
// LiveCore does not ship the DeckLink runtime: the API is loaded from
// /Library/Frameworks/DeckLinkAPI.framework, which Blackmagic Desktop Video installs together
// with the driver. Without it, lc_decklink_available returns false and the input says so.
#pragma once
#if defined(__APPLE__)
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LC_DECKLINK_DOWNLOAD_URL "https://www.blackmagicdesign.com/support/family/capture-and-playback"

/// True when the Desktop Video API framework is installed (does not need a card).
bool lc_decklink_available(void);
/// Desktop Video API version ("12.4.1"), empty when unavailable.
void lc_decklink_api_version(char *buf, int32_t cap);

/// Capture-capable devices (DeckLink, UltraStudio, Intensity). Order follows the driver.
int32_t lc_decklink_device_count(void);
/// Display name of device `index`; false when there is no such device.
bool lc_decklink_device_name(int32_t index, char *buf, int32_t cap);
/// Video input connections the device has (BMDVideoConnection bits: 1 SDI, 2 HDMI, 4 optical
/// SDI, 8 component, 16 composite, 32 S-Video) and whether it can detect the input format.
bool lc_decklink_device_caps(int32_t index, int64_t *connections, bool *formatDetection);

typedef struct {
    uint32_t mode;          // BMDDisplayMode four-character code
    int32_t width, height;
    double fps;
    bool interlaced;
    char name[64];
} lc_decklink_mode;
/// Input display modes of device `index`; returns how many were written (≤ cap).
int32_t lc_decklink_modes(int32_t index, lc_decklink_mode *out, int32_t cap);

typedef struct {
    /// Video frame (DeckLink thread). pixel_format is '2vuy' (8-bit 4:2:2) or 'BGRA'.
    /// no_signal is true when the card sees no input (bytes then hold the card's black/default).
    void (*video)(void *ctx, const uint8_t *bytes, int32_t width, int32_t height, int32_t row_bytes,
                  uint32_t pixel_format, bool no_signal);
    /// Interleaved 16-bit audio, 48 kHz (DeckLink thread).
    void (*audio)(void *ctx, const int16_t *samples, int32_t frames, int32_t channels);
    /// Input format detected / changed (DeckLink thread).
    void (*format)(void *ctx, uint32_t mode, int32_t width, int32_t height, double fps, bool rgb);
} lc_decklink_callbacks;

typedef struct lc_decklink_capture lc_decklink_capture;

/// Starts capturing from device `index`. mode 0 = detect the format (falls back to the first
/// mode when the device cannot detect). connection 0 = keep the card's setting. audio_channels
/// 0 = no audio, else 2, 8 or 16. On failure returns NULL and writes the reason into err.
lc_decklink_capture *lc_decklink_open(int32_t index, uint32_t mode, int64_t connection, int32_t audio_channels,
                                      lc_decklink_callbacks callbacks, void *ctx, char *err, int32_t err_cap);
/// Stops capturing; no callback runs after it returns.
void lc_decklink_close(lc_decklink_capture *capture);

#ifdef __cplusplus
}
#endif
#endif
