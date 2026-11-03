// LiveCore Studio: a small C wrapper around the NDI® runtime, loaded at run time with dlopen.
// LiveCore does not ship the NDI library: it uses the runtime that NDI Tools (or the NDI Runtime
// installer) puts on the Mac. Without it, lc_ndi_load returns false and NDI stays off.
// NDI® is a registered trademark of Vizrt NDI AB.
#pragma once
#if defined(__APPLE__)
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Where the runtime can be downloaded when it is not installed.
#define LC_NDI_REDIST_URL "http://ndi.link/NDIRedistV6Apple"

/// Loads and initialises the NDI runtime once (thread-safe; later calls return the first result).
bool lc_ndi_load(void);
/// Path of the loaded library, or NULL.
const char *lc_ndi_loaded_path(void);
/// Runtime version string, or NULL when not loaded.
const char *lc_ndi_version(void);

typedef struct lc_ndi_sender lc_ndi_sender;
/// A sender announced on the network as "<computer name> (<name>)". NULL when the runtime is
/// not loaded or the sender could not be created.
lc_ndi_sender *lc_ndi_sender_create(const char *name);
void lc_ndi_sender_destroy(lc_ndi_sender *sender);
/// Sends one progressive BGRA frame (alpha ignored). Blocks while NDI compresses it; call from
/// one thread per sender.
void lc_ndi_send_video(lc_ndi_sender *sender, const void *bgra, int width, int height, int stride,
                       int fps_num, int fps_den);
/// Sends planar float audio (channel after channel, `samples` per channel).
void lc_ndi_send_audio(lc_ndi_sender *sender, const float *planar, int channels, int samples, int sample_rate);
/// Number of receivers connected right now.
int lc_ndi_connections(lc_ndi_sender *sender);

// Receiving side, used by `livecore-ndi-check` (CI) to prove another process sees our source.

/// Names of the NDI sources found within `timeout_ms`, separated by '\n', written to `out`
/// (always NUL-terminated). Returns the number of sources.
int lc_ndi_find_sources(char *out, int out_len, int timeout_ms);

typedef struct lc_ndi_receiver lc_ndi_receiver;
lc_ndi_receiver *lc_ndi_receiver_create(const char *source_name);
void lc_ndi_receiver_destroy(lc_ndi_receiver *receiver);
/// Waits for a video frame. Returns true with its size, FourCC and the BGRA value of its centre pixel.
bool lc_ndi_receive_video(lc_ndi_receiver *receiver, int timeout_ms, int *width, int *height,
                          uint32_t *fourcc, uint32_t *centre_bgra);

// Receiving side for NDI inputs (0.29.0).

typedef struct lc_ndi_finder lc_ndi_finder;
/// A long-lived source finder (also lists sources on this Mac). NULL without the runtime.
lc_ndi_finder *lc_ndi_finder_create(void);
void lc_ndi_finder_destroy(lc_ndi_finder *finder);
/// Waits up to `timeout_ms` for changes, then writes the current source names separated by
/// '\n' into `out` (always NUL-terminated). Returns the number of sources.
int lc_ndi_finder_sources(lc_ndi_finder *finder, char *out, int out_len, int timeout_ms);

/// Receiver for an input: BGRX/BGRA video, float audio. `low_bandwidth` asks for the source's
/// preview stream (less network and CPU).
lc_ndi_receiver *lc_ndi_input_create(const char *source_name, const char *receiver_name, bool low_bandwidth);

typedef struct {
    int width, height, stride;
    int fps_n, fps_d;
    bool has_alpha;            ///< BGRA with meaningful (straight) alpha; otherwise BGRX
    const uint8_t *data;
} lc_ndi_video;

typedef struct {
    int sample_rate, channels, samples, channel_stride;   ///< stride in bytes between planes
    const float *data;
} lc_ndi_audio;

/// Waits up to `timeout_ms` for the next frame. Returns 1 for video (valid until
/// `lc_ndi_release_video`), 2 for audio (valid until `lc_ndi_release_audio`), 0 for nothing
/// / other frames, -1 when the connection failed.
int lc_ndi_capture(lc_ndi_receiver *receiver, int timeout_ms, lc_ndi_video *video, lc_ndi_audio *audio);
void lc_ndi_release_video(lc_ndi_receiver *receiver);
void lc_ndi_release_audio(lc_ndi_receiver *receiver);
/// Copies the last captured video frame into a BGRA buffer; BGRX frames get alpha 255.
void lc_ndi_copy_video(const lc_ndi_video *video, uint8_t *dst, int dst_stride);
/// Senders this receiver is connected to right now (0 or 1).
int lc_ndi_receiver_connections(lc_ndi_receiver *receiver);

#ifdef __cplusplus
}
#endif
#endif
