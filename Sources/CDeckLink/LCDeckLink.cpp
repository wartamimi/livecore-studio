// LiveCore Studio: DeckLink capture wrapper. See include/LCDeckLink.h.
#if defined(__APPLE__)
#include "LCDeckLink.h"
#include "decklink/DeckLinkAPI.h"
#include "decklink/DeckLinkAPIDispatch.cpp"
#include <atomic>
#include <mutex>
#include <stdio.h>
#include <string.h>

namespace {

void copyCF(CFStringRef s, char *buf, int32_t cap) {
    if (!buf || cap <= 0) return;
    buf[0] = 0;
    if (!s) return;
    CFStringGetCString(s, buf, cap, kCFStringEncodingUTF8);
    CFRelease(s);
}

void setErr(char *err, int32_t cap, const char *msg) {
    if (err && cap > 0) snprintf(err, (size_t)cap, "%s", msg);
}

/// The capture-capable device at `index` (AddRef'd), or NULL.
IDeckLink *deviceAt(int32_t index) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return NULL;
    IDeckLink *dl = NULL, *found = NULL;
    int32_t n = 0;
    while (it->Next(&dl) == S_OK) {
        IDeckLinkInput *in = NULL;
        bool canCapture = dl->QueryInterface(IID_IDeckLinkInput, (void **)&in) == S_OK;
        if (in) in->Release();
        if (canCapture && n++ == index) { found = dl; break; }
        dl->Release();
    }
    it->Release();
    return found;
}

double modeFPS(IDeckLinkDisplayMode *m) {
    BMDTimeValue dur = 0;
    BMDTimeScale scale = 0;
    if (m->GetFrameRate(&dur, &scale) != S_OK || dur <= 0) return 0;
    return (double)scale / (double)dur;
}

class Capture : public IDeckLinkInputCallback {
public:
    std::atomic<ULONG> refs{1};
    IDeckLink *device = NULL;
    IDeckLinkInput *input = NULL;
    lc_decklink_callbacks cb{};
    void *ctx = NULL;
    std::mutex lock;          // held while a callback runs; close() takes it to wait them out
    bool closed = false;
    bool detect = false;
    int32_t audioChannels = 0;
    BMDPixelFormat pixelFormat = bmdFormat8BitYUV;

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        CFUUIDBytes unknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &unknown, sizeof(REFIID)) == 0 || memcmp(&iid, &IID_IDeckLinkInputCallback, sizeof(REFIID)) == 0) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override {
        ULONG r = --refs;
        if (r == 0) delete this;
        return r;
    }

    HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events, IDeckLinkDisplayMode *mode,
                                    BMDDetectedVideoInputFormatFlags flags) override {
        std::lock_guard<std::mutex> g(lock);
        if (closed || !mode) return S_OK;
        BMDPixelFormat pf = (flags & bmdDetectedVideoInputRGB444) ? bmdFormat8BitBGRA : bmdFormat8BitYUV;
        if ((events & (bmdVideoInputDisplayModeChanged | bmdVideoInputColorspaceChanged)) || pf != pixelFormat) {
            input->PauseStreams();
            if (input->EnableVideoInput(mode->GetDisplayMode(), pf, bmdVideoInputEnableFormatDetection) != S_OK && pf != bmdFormat8BitYUV) {
                pf = bmdFormat8BitYUV;   // the card cannot capture RGB: let it convert
                input->EnableVideoInput(mode->GetDisplayMode(), pf, bmdVideoInputEnableFormatDetection);
            }
            pixelFormat = pf;
            input->FlushStreams();
            input->StartStreams();
        }
        if (cb.format)
            cb.format(ctx, mode->GetDisplayMode(), (int32_t)mode->GetWidth(), (int32_t)mode->GetHeight(), modeFPS(mode),
                      pf == bmdFormat8BitBGRA);
        return S_OK;
    }

    HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *v, IDeckLinkAudioInputPacket *a) override {
        std::lock_guard<std::mutex> g(lock);
        if (closed) return S_OK;
        if (v && cb.video) {
            void *bytes = NULL;
            if (v->GetBytes(&bytes) == S_OK && bytes) {
                bool noSignal = (v->GetFlags() & bmdFrameHasNoInputSource) != 0;
                cb.video(ctx, (const uint8_t *)bytes, (int32_t)v->GetWidth(), (int32_t)v->GetHeight(), (int32_t)v->GetRowBytes(),
                         (uint32_t)v->GetPixelFormat(), noSignal);
            }
        }
        if (a && cb.audio && audioChannels > 0) {
            void *bytes = NULL;
            if (a->GetBytes(&bytes) == S_OK && bytes)
                cb.audio(ctx, (const int16_t *)bytes, (int32_t)a->GetSampleFrameCount(), audioChannels);
        }
        return S_OK;
    }
};

}  // namespace

extern "C" {

bool lc_decklink_available(void) { return IsDeckLinkAPIPresent(); }

void lc_decklink_api_version(char *buf, int32_t cap) {
    if (buf && cap > 0) buf[0] = 0;
    IDeckLinkAPIInformation *info = CreateDeckLinkAPIInformationInstance();
    if (!info) return;
    CFStringRef s = NULL;
    if (info->GetString(BMDDeckLinkAPIVersion, &s) == S_OK) copyCF(s, buf, cap);
    info->Release();
}

int32_t lc_decklink_device_count(void) {
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (!it) return 0;
    IDeckLink *dl = NULL;
    int32_t n = 0;
    while (it->Next(&dl) == S_OK) {
        IDeckLinkInput *in = NULL;
        if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&in) == S_OK) { n++; in->Release(); }
        dl->Release();
    }
    it->Release();
    return n;
}

bool lc_decklink_device_name(int32_t index, char *buf, int32_t cap) {
    IDeckLink *dl = deviceAt(index);
    if (!dl) return false;
    CFStringRef s = NULL;
    if (dl->GetDisplayName(&s) == S_OK) copyCF(s, buf, cap);
    else if (dl->GetModelName(&s) == S_OK) copyCF(s, buf, cap);
    dl->Release();
    return true;
}

bool lc_decklink_device_caps(int32_t index, int64_t *connections, bool *formatDetection) {
    if (connections) *connections = 0;
    if (formatDetection) *formatDetection = false;
    IDeckLink *dl = deviceAt(index);
    if (!dl) return false;
    IDeckLinkProfileAttributes *attr = NULL;
    if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) == S_OK && attr) {
        int64_t c = 0;
        bool d = false;
        if (connections && attr->GetInt(BMDDeckLinkVideoInputConnections, &c) == S_OK) *connections = c;
        if (formatDetection && attr->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &d) == S_OK) *formatDetection = d;
        attr->Release();
    }
    dl->Release();
    return true;
}

int32_t lc_decklink_modes(int32_t index, lc_decklink_mode *out, int32_t cap) {
    IDeckLink *dl = deviceAt(index);
    if (!dl) return 0;
    IDeckLinkInput *in = NULL;
    int32_t n = 0;
    if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&in) == S_OK && in) {
        IDeckLinkDisplayModeIterator *it = NULL;
        if (in->GetDisplayModeIterator(&it) == S_OK && it) {
            IDeckLinkDisplayMode *m = NULL;
            while (n < cap && it->Next(&m) == S_OK) {
                lc_decklink_mode &o = out[n++];
                memset(&o, 0, sizeof o);
                o.mode = m->GetDisplayMode();
                o.width = (int32_t)m->GetWidth();
                o.height = (int32_t)m->GetHeight();
                o.fps = modeFPS(m);
                o.interlaced = m->GetFieldDominance() != bmdProgressiveFrame;
                CFStringRef s = NULL;
                if (m->GetName(&s) == S_OK) copyCF(s, o.name, sizeof o.name);
                m->Release();
            }
            it->Release();
        }
        in->Release();
    }
    dl->Release();
    return n;
}

struct lc_decklink_capture {
    Capture *cap;
};

lc_decklink_capture *lc_decklink_open(int32_t index, uint32_t mode, int64_t connection, int32_t audio_channels,
                                      lc_decklink_callbacks callbacks, void *ctx, char *err, int32_t err_cap) {
    if (!IsDeckLinkAPIPresent()) { setErr(err, err_cap, "Blackmagic Desktop Video is not installed"); return NULL; }
    IDeckLink *dl = deviceAt(index);
    if (!dl) { setErr(err, err_cap, "The DeckLink device is not connected"); return NULL; }
    IDeckLinkInput *in = NULL;
    if (dl->QueryInterface(IID_IDeckLinkInput, (void **)&in) != S_OK || !in) {
        dl->Release();
        setErr(err, err_cap, "The device has no video input");
        return NULL;
    }
    if (connection != 0) {
        IDeckLinkConfiguration *cfg = NULL;
        if (dl->QueryInterface(IID_IDeckLinkConfiguration, (void **)&cfg) == S_OK && cfg) {
            cfg->SetInt(bmdDeckLinkConfigVideoInputConnection, connection);
            cfg->Release();
        }
    }
    bool canDetect = false;
    IDeckLinkProfileAttributes *attr = NULL;
    if (dl->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attr) == S_OK && attr) {
        attr->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &canDetect);
        attr->Release();
    }
    BMDDisplayMode m = (BMDDisplayMode)mode;
    if (m == 0 || m == bmdModeUnknown) {
        // Detect: start from the first mode the card offers; the driver switches on the signal.
        m = bmdModeHD1080i50;
        IDeckLinkDisplayModeIterator *it = NULL;
        if (in->GetDisplayModeIterator(&it) == S_OK && it) {
            IDeckLinkDisplayMode *first = NULL;
            if (it->Next(&first) == S_OK && first) { m = first->GetDisplayMode(); first->Release(); }
            it->Release();
        }
    }
    Capture *c = new Capture();
    c->device = dl;
    c->input = in;
    c->cb = callbacks;
    c->ctx = ctx;
    c->detect = canDetect;
    c->audioChannels = audio_channels;
    BMDVideoInputFlags flags = canDetect ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;
    if (in->SetCallback(c) != S_OK) {
        setErr(err, err_cap, "The DeckLink driver refused the capture callback");
        in->Release(); dl->Release(); c->Release();
        return NULL;
    }
    HRESULT r = in->EnableVideoInput(m, bmdFormat8BitYUV, flags);
    if (r != S_OK) {
        in->SetCallback(NULL);
        setErr(err, err_cap, "The device is in use by another application, or does not support this video mode");
        in->Release(); dl->Release(); c->Release();
        return NULL;
    }
    if (audio_channels > 0) in->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger, (uint32_t)audio_channels);
    if (in->StartStreams() != S_OK) {
        in->DisableVideoInput();
        in->DisableAudioInput();
        in->SetCallback(NULL);
        setErr(err, err_cap, "The DeckLink device could not start capturing");
        in->Release(); dl->Release(); c->Release();
        return NULL;
    }
    lc_decklink_capture *h = new lc_decklink_capture;
    h->cap = c;
    return h;
}

void lc_decklink_close(lc_decklink_capture *h) {
    if (!h) return;
    Capture *c = h->cap;
    {
        std::lock_guard<std::mutex> g(c->lock);
        c->closed = true;
    }
    c->input->StopStreams();
    c->input->SetCallback(NULL);
    c->input->DisableVideoInput();
    c->input->DisableAudioInput();
    c->input->Release();
    c->device->Release();
    c->Release();
    delete h;
}

}  // extern "C"
#endif
