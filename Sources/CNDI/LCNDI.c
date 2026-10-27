// LiveCore Studio: NDI runtime loader and sender/receiver wrapper. See include/LCNDI.h.
#if defined(__APPLE__)
#include "LCNDI.h"
#include "ndi/Processing.NDI.Lib.h"
#include <dlfcn.h>
#include <glob.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t load_once = PTHREAD_ONCE_INIT;
static const NDIlib_v6 *ndi;
static char loaded_path[1024];

/// Opens `path` and returns the runtime's function table (NDI 6, else 5).
static const NDIlib_v6 *try_open(const char *path) {
    void *h = dlopen(path, RTLD_LOCAL | RTLD_LAZY);
    if (!h) return NULL;
    typedef const NDIlib_v6 *(*load_fn)(void);
    load_fn load = (load_fn)dlsym(h, "NDIlib_v6_load");
    if (!load) load = (load_fn)dlsym(h, "NDIlib_v5_load");
    const NDIlib_v6 *lib = load ? load() : NULL;
    if (!lib || !lib->initialize || !lib->initialize()) { dlclose(h); return NULL; }
    snprintf(loaded_path, sizeof loaded_path, "%s", path);
    return lib;
}

static void load_runtime(void) {
    char path[1024];
    // 1. The folder the NDI installer names in the environment.
    const char *dir = getenv(NDILIB_REDIST_FOLDER);
    if (dir && *dir) {
        snprintf(path, sizeof path, "%s/%s", dir, NDILIB_LIBRARY_NAME);
        if ((ndi = try_open(path))) return;
    }
    // 2. Where the NDI Runtime / NDI Tools installers, the SDK and Homebrew put it.
    static const char *fixed[] = {
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "/opt/homebrew/lib/libndi.dylib",
    };
    for (size_t i = 0; i < sizeof fixed / sizeof fixed[0]; i++)
        if ((ndi = try_open(fixed[i]))) return;
    // 3. A copy inside an installed NDI app.
    static const char *patterns[] = {
        "/Applications/NDI*.app/Contents/Frameworks/libndi*.dylib",
        "/Applications/NDI*/NDI*.app/Contents/Frameworks/libndi*.dylib",
    };
    for (size_t p = 0; p < sizeof patterns / sizeof patterns[0]; p++) {
        glob_t g;
        if (glob(patterns[p], 0, NULL, &g) == 0) {
            for (size_t i = 0; i < g.gl_pathc && !ndi; i++) ndi = try_open(g.gl_pathv[i]);
            globfree(&g);
            if (ndi) return;
        }
    }
}

bool lc_ndi_load(void) {
    pthread_once(&load_once, load_runtime);
    return ndi != NULL;
}

const char *lc_ndi_loaded_path(void) { return lc_ndi_load() ? loaded_path : NULL; }

const char *lc_ndi_version(void) {
    return lc_ndi_load() && ndi->version ? ndi->version() : NULL;
}

struct lc_ndi_sender { NDIlib_send_instance_t inst; };

lc_ndi_sender *lc_ndi_sender_create(const char *name) {
    if (!lc_ndi_load()) return NULL;
    NDIlib_send_create_t c;
    memset(&c, 0, sizeof c);
    c.p_ndi_name = name;
    // LiveCore paces frames itself; NDI must not block to re-clock them.
    c.clock_video = false;
    c.clock_audio = false;
    NDIlib_send_instance_t inst = ndi->send_create(&c);
    if (!inst) return NULL;
    lc_ndi_sender *s = calloc(1, sizeof *s);
    if (!s) { ndi->send_destroy(inst); return NULL; }
    s->inst = inst;
    return s;
}

void lc_ndi_sender_destroy(lc_ndi_sender *s) {
    if (!s) return;
    ndi->send_destroy(s->inst);
    free(s);
}

void lc_ndi_send_video(lc_ndi_sender *s, const void *bgra, int width, int height, int stride,
                       int fps_num, int fps_den) {
    if (!s || !bgra) return;
    NDIlib_video_frame_v2_t f;
    memset(&f, 0, sizeof f);
    f.xres = width;
    f.yres = height;
    f.FourCC = NDIlib_FourCC_video_type_BGRX;
    f.frame_rate_N = fps_num;
    f.frame_rate_D = fps_den;
    f.picture_aspect_ratio = height > 0 ? (float)width / (float)height : 0;
    f.frame_format_type = NDIlib_frame_format_type_progressive;
    f.timecode = NDIlib_send_timecode_synthesize;
    f.p_data = (uint8_t *)bgra;
    f.line_stride_in_bytes = stride;
    ndi->send_send_video_v2(s->inst, &f);
}

void lc_ndi_send_audio(lc_ndi_sender *s, const float *planar, int channels, int samples, int sample_rate) {
    if (!s || !planar || samples <= 0) return;
    NDIlib_audio_frame_v2_t a;
    memset(&a, 0, sizeof a);
    a.sample_rate = sample_rate;
    a.no_channels = channels;
    a.no_samples = samples;
    a.timecode = NDIlib_send_timecode_synthesize;
    a.p_data = (float *)planar;
    a.channel_stride_in_bytes = samples * (int)sizeof(float);
    ndi->send_send_audio_v2(s->inst, &a);
}

int lc_ndi_connections(lc_ndi_sender *s) {
    return s ? ndi->send_get_no_connections(s->inst, 0) : 0;
}

int lc_ndi_find_sources(char *out, int out_len, int timeout_ms) {
    if (out_len > 0) out[0] = 0;
    if (!lc_ndi_load()) return 0;
    NDIlib_find_create_t c;
    memset(&c, 0, sizeof c);
    c.show_local_sources = true;
    NDIlib_find_instance_t f = ndi->find_create_v2(&c);
    if (!f) return 0;
    ndi->find_wait_for_sources(f, (uint32_t)timeout_ms);
    uint32_t n = 0;
    const NDIlib_source_t *src = ndi->find_get_current_sources(f, &n);
    int used = 0;
    for (uint32_t i = 0; i < n && out_len > 0; i++) {
        int w = snprintf(out + used, (size_t)(out_len - used), "%s%s", i ? "\n" : "", src[i].p_ndi_name ? src[i].p_ndi_name : "");
        if (w < 0 || used + w >= out_len) break;
        used += w;
    }
    ndi->find_destroy(f);
    return (int)n;
}

struct lc_ndi_receiver { NDIlib_recv_instance_t inst; };

lc_ndi_receiver *lc_ndi_receiver_create(const char *source_name) {
    if (!lc_ndi_load()) return NULL;
    NDIlib_recv_create_v3_t c;
    memset(&c, 0, sizeof c);
    c.source_to_connect_to.p_ndi_name = source_name;
    c.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    c.bandwidth = NDIlib_recv_bandwidth_highest;
    c.allow_video_fields = false;
    c.p_ndi_recv_name = "LiveCore NDI check";
    NDIlib_recv_instance_t inst = ndi->recv_create_v3(&c);
    if (!inst) return NULL;
    lc_ndi_receiver *r = calloc(1, sizeof *r);
    if (!r) { ndi->recv_destroy(inst); return NULL; }
    r->inst = inst;
    return r;
}

void lc_ndi_receiver_destroy(lc_ndi_receiver *r) {
    if (!r) return;
    ndi->recv_destroy(r->inst);
    free(r);
}

bool lc_ndi_receive_video(lc_ndi_receiver *r, int timeout_ms, int *width, int *height,
                          uint32_t *fourcc, uint32_t *centre_bgra) {
    if (!r) return false;
    NDIlib_video_frame_v2_t v;
    NDIlib_audio_frame_v2_t a;
    memset(&v, 0, sizeof v);
    memset(&a, 0, sizeof a);
    NDIlib_frame_type_e t = ndi->recv_capture_v2(r->inst, &v, &a, NULL, (uint32_t)timeout_ms);
    if (t == NDIlib_frame_type_audio) ndi->recv_free_audio_v2(r->inst, &a);
    if (t != NDIlib_frame_type_video) return false;
    *width = v.xres;
    *height = v.yres;
    *fourcc = (uint32_t)v.FourCC;
    const uint8_t *row = v.p_data + (size_t)(v.yres / 2) * (size_t)v.line_stride_in_bytes;
    const uint8_t *px = row + (size_t)(v.xres / 2) * 4;
    *centre_bgra = (uint32_t)px[3] << 24 | (uint32_t)px[2] << 16 | (uint32_t)px[1] << 8 | px[0];
    ndi->recv_free_video_v2(r->inst, &v);
    return true;
}
#endif
