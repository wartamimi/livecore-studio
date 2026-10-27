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

#ifdef __cplusplus
}
#endif
#endif
