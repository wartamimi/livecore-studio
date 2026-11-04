// LiveCore Studio: a small C wrapper that hosts VST 3 audio effects (0.60.0).
// Built on Steinberg's VST 3 plug-in interfaces (pluginterfaces, MIT licence since VST 3.8,
// vendored in sdk/pluginterfaces). Plug-ins are loaded in-process from their .vst3 bundles.
//
// Threads: lc_vst3_process runs on the audio render thread; everything else on the main thread
// (scan may run on any thread, normally in a separate scanner process).
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lc_vst3_plugin lc_vst3_plugin;

/// Lists the audio effect classes in a .vst3 bundle as a JSON array:
/// [{"cid":"<32 hex>","name":"…","vendor":"…","version":"…","subCategories":"Fx|Dynamics"}].
/// Returns a malloc'd string (free with lc_vst3_free) or NULL with the reason in err.
char *lc_vst3_scan(const char *bundle_path, char *err, int32_t err_cap);
void lc_vst3_free(void *ptr);

/// Creates, initialises and activates effect class `cid_hex` (stereo in/out where the plug-in
/// allows it, otherwise mono). NULL with the reason in err on failure.
lc_vst3_plugin *lc_vst3_open(const char *bundle_path, const char *cid_hex, double sample_rate,
                             int32_t max_frames, char *err, int32_t err_cap);
/// Stops processing and releases the plug-in. Never while lc_vst3_process may run.
void lc_vst3_close(lc_vst3_plugin *plugin);

/// Render thread: processes `frames` (≤ max_frames) stereo samples in place. 0 = ok,
/// otherwise the plug-in's error (the buffers then hold the unprocessed input).
int32_t lc_vst3_process(lc_vst3_plugin *plugin, float *left, float *right, int32_t frames);
/// Latency the plug-in reports, in samples.
int32_t lc_vst3_latency(lc_vst3_plugin *plugin);
/// Channels of the main input bus (1 = mono effect, 2 = stereo).
int32_t lc_vst3_channels(lc_vst3_plugin *plugin);

/// Component + controller state as one blob (malloc'd, free with lc_vst3_free).
bool lc_vst3_get_state(lc_vst3_plugin *plugin, uint8_t **out, int64_t *length);
bool lc_vst3_set_state(lc_vst3_plugin *plugin, const uint8_t *data, int64_t length);

/// Parameters, for the generic editor (plug-ins without their own window).
int32_t lc_vst3_param_count(lc_vst3_plugin *plugin);
/// flags bit 0 = can automate, bit 1 = read only, bit 2 = hidden/list.
bool lc_vst3_param_info(lc_vst3_plugin *plugin, int32_t index, uint32_t *id, char *title, int32_t title_cap,
                        char *units, int32_t units_cap, int32_t *steps, int32_t *flags);
double lc_vst3_param_get(lc_vst3_plugin *plugin, uint32_t id);
/// Sets a normalised value (0…1) on the controller and sends it to the processor.
void lc_vst3_param_set(lc_vst3_plugin *plugin, uint32_t id, double normalized);
void lc_vst3_param_display(lc_vst3_plugin *plugin, uint32_t id, double normalized, char *buf, int32_t cap);

/// The plug-in's own editor. `parent` is an NSView*. `resize` is called when the plug-in asks
/// for another size (the host resizes its window; the plug-in is told afterwards).
bool lc_vst3_has_editor(lc_vst3_plugin *plugin);
bool lc_vst3_editor_open(lc_vst3_plugin *plugin, void *parent, int32_t *width, int32_t *height,
                         void (*resize)(void *ctx, int32_t width, int32_t height), void *ctx);
bool lc_vst3_editor_can_resize(lc_vst3_plugin *plugin);
/// The host window was resized by the user; returns the size the plug-in accepts.
void lc_vst3_editor_set_size(lc_vst3_plugin *plugin, int32_t *width, int32_t *height);
void lc_vst3_editor_close(lc_vst3_plugin *plugin);

#ifdef __cplusplus
}
#endif
