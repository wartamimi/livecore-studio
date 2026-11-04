// LiveCore Studio — minimal VST 3 effect host (see include/LCVST3.h).
// Original implementation on top of Steinberg's MIT-licensed pluginterfaces.
#include "LCVST3.h"

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#else
#include <dlfcn.h>
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

// Interface ids this host uses (the base ones are in pluginterfaces/base/coreiids.cpp).
namespace Steinberg {
DEF_CLASS_IID (IPlugView)
DEF_CLASS_IID (IPlugFrame)
namespace Vst {
DEF_CLASS_IID (IComponent)
DEF_CLASS_IID (IAudioProcessor)
DEF_CLASS_IID (IEditController)
DEF_CLASS_IID (IComponentHandler)
DEF_CLASS_IID (IConnectionPoint)
DEF_CLASS_IID (IMessage)
DEF_CLASS_IID (IAttributeList)
DEF_CLASS_IID (IHostApplication)
DEF_CLASS_IID (IParamValueQueue)
DEF_CLASS_IID (IParameterChanges)
} // namespace Vst
} // namespace Steinberg

namespace {

void setErr(char *err, int32_t cap, const std::string &msg) {
    if (!err || cap <= 0) return;
    std::snprintf(err, (size_t)cap, "%s", msg.c_str());
}

std::string utf8(const char16 *s) {
    std::string out;
    if (!s) return out;
    for (; *s; ++s) {
        uint32_t c = (uint16_t)*s;
        if (c >= 0xD800 && c <= 0xDBFF && s[1] >= 0xDC00 && s[1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + ((uint16_t)s[1] - 0xDC00);
            ++s;
        }
        if (c < 0x80) out += (char)c;
        else if (c < 0x800) { out += (char)(0xC0 | (c >> 6)); out += (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out += (char)(0xE0 | (c >> 12)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
        else { out += (char)(0xF0 | (c >> 18)); out += (char)(0x80 | ((c >> 12) & 0x3F)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
    }
    return out;
}

void copyStr(char *dst, int32_t cap, const std::string &s) {
    if (!dst || cap <= 0) return;
    std::snprintf(dst, (size_t)cap, "%s", s.c_str());
}

void toString128(const char *src, String128 dst) {
    int i = 0;
    for (; src[i] && i < 127; ++i) dst[i] = (char16)(unsigned char)src[i];
    dst[i] = 0;
}

std::string jsonEscape(const std::string &s) {
    std::string o;
    for (char c : s) {
        switch (c) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': case '\t': o += ' '; break;
        default:
            if ((unsigned char)c < 0x20) o += ' ';
            else o += c;
        }
    }
    return o;
}

std::string cidHex(const TUID cid) {
    static const char *hx = "0123456789ABCDEF";
    std::string s;
    for (int i = 0; i < 16; ++i) { s += hx[((unsigned char)cid[i]) >> 4]; s += hx[((unsigned char)cid[i]) & 15]; }
    return s;
}

bool parseCid(const char *hex, TUID out) {
    if (!hex || std::strlen(hex) != 32) return false;
    for (int i = 0; i < 16; ++i) {
        unsigned v = 0;
        if (std::sscanf(hex + i * 2, "%2x", &v) != 1) return false;
        out[i] = (char)v;
    }
    return true;
}

#define LC_UNKNOWN_REFCOUNT                                                       \
    std::atomic<int32> refs_{1};                                                  \
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return (uint32)++refs_; }         \
    uint32 PLUGIN_API release() SMTG_OVERRIDE {                                  \
        int32 r = --refs_;                                                        \
        if (r == 0) delete this;                                                  \
        return (uint32)r;                                                         \
    }

#define LC_QUERY(Iface)                                                           \
    if (FUnknownPrivate::iidEqual(iid, Iface::iid)) {                             \
        addRef();                                                                 \
        *obj = static_cast<Iface *>(this);                                        \
        return kResultOk;                                                         \
    }

// MARK: Host-side helper objects

class HostAttributeList : public IAttributeList {
public:
    LC_UNKNOWN_REFCOUNT
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IAttributeList)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    tresult PLUGIN_API setInt(AttrID id, int64 v) SMTG_OVERRIDE { ints[id] = v; return kResultOk; }
    tresult PLUGIN_API getInt(AttrID id, int64 &v) SMTG_OVERRIDE {
        auto it = ints.find(id); if (it == ints.end()) return kResultFalse; v = it->second; return kResultOk;
    }
    tresult PLUGIN_API setFloat(AttrID id, double v) SMTG_OVERRIDE { floats[id] = v; return kResultOk; }
    tresult PLUGIN_API getFloat(AttrID id, double &v) SMTG_OVERRIDE {
        auto it = floats.find(id); if (it == floats.end()) return kResultFalse; v = it->second; return kResultOk;
    }
    tresult PLUGIN_API setString(AttrID id, const TChar *s) SMTG_OVERRIDE {
        std::u16string v;
        if (s) for (; *s; ++s) v += (char16_t)*s;
        strings[id] = v;
        return kResultOk;
    }
    tresult PLUGIN_API getString(AttrID id, TChar *s, uint32 sizeInBytes) SMTG_OVERRIDE {
        auto it = strings.find(id);
        if (it == strings.end() || !s || sizeInBytes < sizeof(TChar)) return kResultFalse;
        uint32 n = (uint32)std::min<size_t>(it->second.size(), sizeInBytes / sizeof(TChar) - 1);
        for (uint32 i = 0; i < n; ++i) s[i] = (TChar)it->second[i];
        s[n] = 0;
        return kResultOk;
    }
    tresult PLUGIN_API setBinary(AttrID id, const void *data, uint32 size) SMTG_OVERRIDE {
        const uint8 *p = (const uint8 *)data;
        binaries[id] = std::vector<uint8>(p, p + size);
        return kResultOk;
    }
    tresult PLUGIN_API getBinary(AttrID id, const void *&data, uint32 &size) SMTG_OVERRIDE {
        auto it = binaries.find(id); if (it == binaries.end()) return kResultFalse;
        data = it->second.data(); size = (uint32)it->second.size(); return kResultOk;
    }
private:
    virtual ~HostAttributeList() = default;
    std::map<std::string, int64> ints;
    std::map<std::string, double> floats;
    std::map<std::string, std::u16string> strings;
    std::map<std::string, std::vector<uint8>> binaries;
};

class HostMessage : public IMessage {
public:
    LC_UNKNOWN_REFCOUNT
    HostMessage() : attributes(new HostAttributeList()) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IMessage)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    FIDString PLUGIN_API getMessageID() SMTG_OVERRIDE { return messageID.c_str(); }
    void PLUGIN_API setMessageID(FIDString id) SMTG_OVERRIDE { messageID = id ? id : ""; }
    IAttributeList *PLUGIN_API getAttributes() SMTG_OVERRIDE { return attributes; }
private:
    virtual ~HostMessage() { attributes->release(); }
    std::string messageID;
    HostAttributeList *attributes;
};

class HostApplication : public IHostApplication {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IHostApplication)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    // A process-wide singleton: never deleted.
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }
    tresult PLUGIN_API getName(String128 name) SMTG_OVERRIDE { toString128("LiveCore Studio", name); return kResultOk; }
    tresult PLUGIN_API createInstance(TUID cid, TUID iid, void **obj) SMTG_OVERRIDE {
        if (FUnknownPrivate::iidEqual(cid, IMessage::iid) && FUnknownPrivate::iidEqual(iid, IMessage::iid)) {
            *obj = static_cast<IMessage *>(new HostMessage());
            return kResultOk;
        }
        if (FUnknownPrivate::iidEqual(cid, IAttributeList::iid) && FUnknownPrivate::iidEqual(iid, IAttributeList::iid)) {
            *obj = static_cast<IAttributeList *>(new HostAttributeList());
            return kResultOk;
        }
        *obj = nullptr;
        return kResultFalse;
    }
};
HostApplication gHost;

class MemoryStream : public IBStream {
public:
    LC_UNKNOWN_REFCOUNT
    MemoryStream() {}
    MemoryStream(const uint8 *p, size_t n) : data(p, p + n) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IBStream)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    tresult PLUGIN_API read(void *buffer, int32 numBytes, int32 *numBytesRead) SMTG_OVERRIDE {
        int64 n = std::max<int64>(0, std::min<int64>(numBytes, (int64)data.size() - pos));
        if (n > 0) std::memcpy(buffer, data.data() + pos, (size_t)n);
        pos += n;
        if (numBytesRead) *numBytesRead = (int32)n;
        return kResultOk;
    }
    tresult PLUGIN_API write(void *buffer, int32 numBytes, int32 *numBytesWritten) SMTG_OVERRIDE {
        if (numBytes < 0) return kInvalidArgument;
        if ((size_t)(pos + numBytes) > data.size()) data.resize((size_t)(pos + numBytes));
        if (numBytes > 0) std::memcpy(data.data() + pos, buffer, (size_t)numBytes);
        pos += numBytes;
        if (numBytesWritten) *numBytesWritten = numBytes;
        return kResultOk;
    }
    tresult PLUGIN_API seek(int64 p, int32 mode, int64 *result) SMTG_OVERRIDE {
        int64 base = mode == kIBSeekSet ? 0 : mode == kIBSeekCur ? pos : (int64)data.size();
        int64 np = base + p;
        if (np < 0) return kInvalidArgument;
        pos = np;
        if (result) *result = pos;
        return kResultOk;
    }
    tresult PLUGIN_API tell(int64 *p) SMTG_OVERRIDE { if (p) *p = pos; return kResultOk; }
    std::vector<uint8> data;
    int64 pos = 0;
private:
    virtual ~MemoryStream() = default;
};

// Fixed-capacity parameter queue (no allocation on the render thread).
class ParamQueue : public IParamValueQueue {
public:
    ParamID id = 0;
    int32 count = 0;
    static const int32 kMax = 64;
    struct Point { int32 offset; ParamValue value; } points[kMax];
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IParamValueQueue)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    // Owned by ParamChanges: reference counting is a no-op.
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }
    ParamID PLUGIN_API getParameterId() SMTG_OVERRIDE { return id; }
    int32 PLUGIN_API getPointCount() SMTG_OVERRIDE { return count; }
    tresult PLUGIN_API getPoint(int32 index, int32 &offset, ParamValue &value) SMTG_OVERRIDE {
        if (index < 0 || index >= count) return kResultFalse;
        offset = points[index].offset; value = points[index].value; return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32 &index) SMTG_OVERRIDE {
        // One value per block is enough here: a later point at the same offset replaces it.
        if (count > 0 && points[count - 1].offset == offset) { points[count - 1].value = value; index = count - 1; return kResultOk; }
        if (count >= kMax) return kResultFalse;
        points[count] = {offset, value};
        index = count++;
        return kResultOk;
    }
};

class ParamChanges : public IParameterChanges {
public:
    static const int32 kMax = 128;
    ParamQueue queues[kMax];
    int32 used = 0;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IParameterChanges)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }
    int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE { return used; }
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) SMTG_OVERRIDE {
        return index >= 0 && index < used ? &queues[index] : nullptr;
    }
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &pid, int32 &index) SMTG_OVERRIDE {
        for (int32 i = 0; i < used; ++i) if (queues[i].id == pid) { index = i; return &queues[i]; }
        if (used >= kMax) return nullptr;
        queues[used].id = pid; queues[used].count = 0;
        index = used;
        return &queues[used++];
    }
    void clear() { used = 0; }
};

// Single-producer (main thread) / single-consumer (render thread) parameter edit ring.
struct EditRing {
    static const uint32_t kCap = 1024;
    struct Edit { ParamID id; ParamValue value; } items[kCap];
    std::atomic<uint32_t> head{0}, tail{0};
    std::mutex producer;   // the editor and the generic UI may both write
    void push(ParamID id, ParamValue v) {
        std::lock_guard<std::mutex> g(producer);
        uint32_t h = head.load(std::memory_order_relaxed);
        if (h - tail.load(std::memory_order_acquire) >= kCap) return;   // full: drop
        items[h % kCap] = {id, v};
        head.store(h + 1, std::memory_order_release);
    }
    bool pop(Edit &e) {
        uint32_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire)) return false;
        e = items[t % kCap];
        tail.store(t + 1, std::memory_order_release);
        return true;
    }
};

class ComponentHandler : public IComponentHandler {
public:
    explicit ComponentHandler(EditRing *ring) : ring(ring) {}
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IComponentHandler)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }
    tresult PLUGIN_API beginEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue v) SMTG_OVERRIDE { ring->push(id, v); return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) SMTG_OVERRIDE { return kResultOk; }
    EditRing *ring;
};

class PlugFrame : public IPlugFrame {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        LC_QUERY(IPlugFrame)
        LC_QUERY(FUnknown)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *r) SMTG_OVERRIDE {
        if (!view || !r) return kInvalidArgument;
        if (resize) resize(ctx, r->getWidth(), r->getHeight());
        view->onSize(r);
        return kResultOk;
    }
    void (*resize)(void *, int32_t, int32_t) = nullptr;
    void *ctx = nullptr;
};

// MARK: Modules (bundles stay loaded for the life of the process)

typedef IPluginFactory *(PLUGIN_API *GetFactoryProc)();

struct Module {
    IPluginFactory *factory = nullptr;
};

std::mutex gModulesLock;
std::map<std::string, Module> gModules;

IPluginFactory *loadFactory(const std::string &path, std::string &err) {
    std::lock_guard<std::mutex> g(gModulesLock);
    auto it = gModules.find(path);
    if (it != gModules.end()) return it->second.factory;
    GetFactoryProc getFactory = nullptr;
#if defined(__APPLE__)
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path.c_str(), (CFIndex)path.size(), true);
    if (!url) { err = "invalid path"; return nullptr; }
    CFBundleRef bundle = CFBundleCreate(nullptr, url);
    CFRelease(url);
    if (!bundle) { err = "not a bundle"; return nullptr; }
    CFErrorRef cfErr = nullptr;
    if (!CFBundleLoadExecutableAndReturnError(bundle, &cfErr)) {
        err = "cannot load the plug-in binary (wrong architecture or damaged)";
        if (cfErr) {
            CFStringRef d = CFErrorCopyDescription(cfErr);
            char buf[512];
            if (d && CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8)) err = buf;
            if (d) CFRelease(d);
            CFRelease(cfErr);
        }
        CFRelease(bundle);
        return nullptr;
    }
    typedef bool (*BundleEntryProc)(CFBundleRef);
    auto entry = (BundleEntryProc)CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry"));
    if (!entry) entry = (BundleEntryProc)CFBundleGetFunctionPointerForName(bundle, CFSTR("BundleEntry"));
    if (entry && !entry(bundle)) { err = "the plug-in's bundleEntry failed"; return nullptr; }
    getFactory = (GetFactoryProc)CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory"));
    // The bundle reference is kept on purpose: modules are never unloaded.
#else
    std::string bin = path;
    if (bin.size() > 5 && bin.compare(bin.size() - 5, 5, ".vst3") == 0) {
        std::string name = bin.substr(bin.find_last_of('/') + 1);
        name = name.substr(0, name.size() - 5);
#if defined(__aarch64__)
        bin += "/Contents/aarch64-linux/" + name + ".so";
#else
        bin += "/Contents/x86_64-linux/" + name + ".so";
#endif
    }
    void *h = dlopen(bin.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) { err = dlerror() ? dlerror() : "dlopen failed"; return nullptr; }
    typedef bool (*ModuleEntryProc)(void *);
    auto entry = (ModuleEntryProc)dlsym(h, "ModuleEntry");
    if (entry && !entry(h)) { err = "the plug-in's ModuleEntry failed"; return nullptr; }
    getFactory = (GetFactoryProc)dlsym(h, "GetPluginFactory");
#endif
    if (!getFactory) { err = "not a VST 3 plug-in (no GetPluginFactory)"; return nullptr; }
    IPluginFactory *f = getFactory();
    if (!f) { err = "the plug-in returned no factory"; return nullptr; }
    IPluginFactory3 *f3 = nullptr;
    if (f->queryInterface(IPluginFactory3::iid, (void **)&f3) == kResultOk && f3) {
        f3->setHostContext(&gHost);
        f3->release();
    }
    gModules[path] = Module{f};
    return f;
}

bool isEffectClass(const PClassInfo &ci, const std::string &sub) {
    if (std::strcmp(ci.category, kVstAudioEffectClass) != 0) return false;
    // Instruments and generators have no audio input to process.
    if (sub.find("Instrument") != std::string::npos && sub.find("Fx") == std::string::npos) return false;
    return true;
}

} // namespace

// MARK: Plug-in instance

struct lc_vst3_plugin {
    IComponent *component = nullptr;
    IAudioProcessor *processor = nullptr;
    IEditController *controller = nullptr;
    bool controllerIsComponent = false;
    IConnectionPoint *compCP = nullptr, *ctrlCP = nullptr;
    IPlugView *view = nullptr;
    PlugFrame frame;
    EditRing ring;
    ComponentHandler handler{&ring};
    ParamChanges inChanges, outChanges;
    ProcessContext context{};
    int32 maxFrames = 0;
    int32 mainInChannels = 2, mainOutChannels = 2;
    // Bus buffers for every bus (main and side-chain), as the interface requires.
    std::vector<AudioBusBuffers> inBuses, outBuses;
    std::vector<std::vector<float *>> inPtrs, outPtrs;
    std::vector<float *> scratch;
    bool active = false, processing = false;

    float *alloc() {
        float *p = (float *)std::calloc((size_t)maxFrames, sizeof(float));
        scratch.push_back(p);
        return p;
    }
    ~lc_vst3_plugin() { for (float *p : scratch) std::free(p); }
};

extern "C" {

void lc_vst3_free(void *ptr) { std::free(ptr); }

char *lc_vst3_scan(const char *bundle_path, char *err, int32_t err_cap) {
    std::string e;
    IPluginFactory *f = loadFactory(bundle_path ? bundle_path : "", e);
    if (!f) { setErr(err, err_cap, e); return nullptr; }
    PFactoryInfo fi{};
    f->getFactoryInfo(&fi);
    IPluginFactory2 *f2 = nullptr;
    if (f->queryInterface(IPluginFactory2::iid, (void **)&f2) != kResultOk) f2 = nullptr;
    std::string json = "[";
    bool first = true;
    for (int32 i = 0; i < f->countClasses(); ++i) {
        PClassInfo ci{};
        if (f->getClassInfo(i, &ci) != kResultOk) continue;
        std::string vendor = fi.vendor, version, sub;
        PClassInfo2 c2{};
        if (f2 && f2->getClassInfo2(i, &c2) == kResultOk) {
            if (c2.vendor[0]) vendor = c2.vendor;
            version = c2.version;
            sub = c2.subCategories;
        }
        if (!isEffectClass(ci, sub)) continue;
        if (!first) json += ",";
        first = false;
        json += "{\"cid\":\"" + cidHex(ci.cid) + "\",\"name\":\"" + jsonEscape(ci.name) + "\",\"vendor\":\"" + jsonEscape(vendor) +
                "\",\"version\":\"" + jsonEscape(version) + "\",\"subCategories\":\"" + jsonEscape(sub) + "\"}";
    }
    json += "]";
    if (f2) f2->release();
    char *out = (char *)std::malloc(json.size() + 1);
    std::memcpy(out, json.c_str(), json.size() + 1);
    return out;
}

static bool setupBuses(lc_vst3_plugin *p, BusDirection dir, std::vector<AudioBusBuffers> &buses,
                       std::vector<std::vector<float *>> &ptrs, int32 &mainChannels) {
    int32 n = p->component->getBusCount(kAudio, dir);
    buses.assign((size_t)n, AudioBusBuffers());
    ptrs.assign((size_t)n, {});
    for (int32 b = 0; b < n; ++b) {
        SpeakerArrangement arr = 0;
        p->processor->getBusArrangement(dir, b, arr);
        int32 ch = SpeakerArr::getChannelCount(arr);
        if (ch <= 0) {
            BusInfo bi{};
            p->component->getBusInfo(kAudio, dir, b, bi);
            ch = bi.channelCount;
        }
        for (int32 c = 0; c < ch; ++c) ptrs[(size_t)b].push_back(p->alloc());
        buses[(size_t)b].numChannels = ch;
        buses[(size_t)b].channelBuffers32 = ptrs[(size_t)b].empty() ? nullptr : ptrs[(size_t)b].data();
        // Only the main bus carries audio; side-chains stay off.
        p->component->activateBus(kAudio, dir, b, b == 0);
        if (b == 0) mainChannels = ch;
    }
    return n > 0;
}

lc_vst3_plugin *lc_vst3_open(const char *bundle_path, const char *cid_hex, double sample_rate,
                             int32_t max_frames, char *err, int32_t err_cap) {
    std::string e;
    IPluginFactory *f = loadFactory(bundle_path ? bundle_path : "", e);
    if (!f) { setErr(err, err_cap, e); return nullptr; }
    TUID cid;
    if (!parseCid(cid_hex, cid)) { setErr(err, err_cap, "invalid class id"); return nullptr; }
    auto *p = new lc_vst3_plugin();
    p->maxFrames = max_frames;
    auto fail = [&](const std::string &msg) -> lc_vst3_plugin * {
        setErr(err, err_cap, msg);
        lc_vst3_close(p);
        return nullptr;
    };
    if (f->createInstance(cid, IComponent::iid, (void **)&p->component) != kResultOk || !p->component)
        return fail("the plug-in could not be created");
    if (p->component->initialize(&gHost) != kResultOk) { p->component->release(); p->component = nullptr; return fail("the plug-in failed to initialise"); }
    if (p->component->queryInterface(IAudioProcessor::iid, (void **)&p->processor) != kResultOk || !p->processor)
        return fail("not an audio processor");

    // Edit controller: the component itself, or a separate class.
    if (p->component->queryInterface(IEditController::iid, (void **)&p->controller) == kResultOk && p->controller) {
        p->controllerIsComponent = true;
    } else {
        p->controller = nullptr;
        TUID ccid;
        if (p->component->getControllerClassId(ccid) == kResultOk &&
            f->createInstance(ccid, IEditController::iid, (void **)&p->controller) == kResultOk && p->controller) {
            if (p->controller->initialize(&gHost) != kResultOk) { p->controller->release(); p->controller = nullptr; }
        } else {
            p->controller = nullptr;
        }
    }
    if (p->controller) {
        p->controller->setComponentHandler(&p->handler);
        if (!p->controllerIsComponent &&
            p->component->queryInterface(IConnectionPoint::iid, (void **)&p->compCP) == kResultOk &&
            p->controller->queryInterface(IConnectionPoint::iid, (void **)&p->ctrlCP) == kResultOk && p->compCP && p->ctrlCP) {
            p->compCP->connect(p->ctrlCP);
            p->ctrlCP->connect(p->compCP);
        }
        // Controller starts from the processor's state.
        auto *s = new MemoryStream();
        if (p->component->getState(s) == kResultOk) { s->pos = 0; p->controller->setComponentState(s); }
        s->release();
    }

    // Stereo in / stereo out, or mono when that is all the plug-in takes.
    int32 nIn = p->component->getBusCount(kAudio, kInput), nOut = p->component->getBusCount(kAudio, kOutput);
    if (nOut < 1) return fail("the plug-in has no audio output");
    std::vector<SpeakerArrangement> ins((size_t)nIn, SpeakerArr::kStereo), outs((size_t)nOut, SpeakerArr::kStereo);
    for (int32 b = 1; b < nIn; ++b) p->processor->getBusArrangement(kInput, b, ins[(size_t)b]);
    for (int32 b = 1; b < nOut; ++b) p->processor->getBusArrangement(kOutput, b, outs[(size_t)b]);
    if (p->processor->setBusArrangements(ins.data(), nIn, outs.data(), nOut) != kResultTrue) {
        if (nIn > 0) ins[0] = SpeakerArr::kMono;
        outs[0] = SpeakerArr::kMono;
        p->processor->setBusArrangements(ins.data(), nIn, outs.data(), nOut);   // else keep the plug-in's own
    }
    setupBuses(p, kInput, p->inBuses, p->inPtrs, p->mainInChannels);
    setupBuses(p, kOutput, p->outBuses, p->outPtrs, p->mainOutChannels);
    if (p->mainOutChannels < 1 || p->mainOutChannels > 8) return fail("unsupported output channel layout");

    ProcessSetup setup{kRealtime, kSample32, max_frames, sample_rate};
    if (p->processor->canProcessSampleSize(kSample32) != kResultTrue) return fail("the plug-in cannot process 32-bit audio");
    if (p->processor->setupProcessing(setup) != kResultOk) return fail("the plug-in refused 48 kHz processing");
    if (p->component->setActive(true) != kResultOk) return fail("the plug-in could not be activated");
    p->active = true;
    p->processor->setProcessing(true);   // kNotImplemented is allowed
    p->processing = true;

    p->context.sampleRate = sample_rate;
    p->context.tempo = 120;
    p->context.timeSigNumerator = 4;
    p->context.timeSigDenominator = 4;
    p->context.state = ProcessContext::kPlaying | ProcessContext::kTempoValid | ProcessContext::kTimeSigValid;
    return p;
}

void lc_vst3_close(lc_vst3_plugin *p) {
    if (!p) return;
    lc_vst3_editor_close(p);
    if (p->processing && p->processor) p->processor->setProcessing(false);
    if (p->active && p->component) p->component->setActive(false);
    if (p->compCP && p->ctrlCP) { p->compCP->disconnect(p->ctrlCP); p->ctrlCP->disconnect(p->compCP); }
    if (p->compCP) p->compCP->release();
    if (p->ctrlCP) p->ctrlCP->release();
    if (p->controller) {
        p->controller->setComponentHandler(nullptr);
        if (!p->controllerIsComponent) p->controller->terminate();
        p->controller->release();
    }
    if (p->processor) p->processor->release();
    if (p->component) { p->component->terminate(); p->component->release(); }
    delete p;
}

int32_t lc_vst3_process(lc_vst3_plugin *p, float *left, float *right, int32_t frames) {
    if (!p || frames <= 0 || frames > p->maxFrames || p->outPtrs.empty()) return -1;
    // Parameter edits made in the editor since the last block.
    p->inChanges.clear();
    EditRing::Edit e;
    while (p->ring.pop(e)) {
        int32 idx = 0;
        if (IParamValueQueue *q = p->inChanges.addParameterData(e.id, idx)) q->addPoint(0, e.value, idx);
    }
    p->outChanges.clear();
    // Main input: stereo, or the two channels mixed for a mono effect.
    if (!p->inBuses.empty()) {
        auto &in = p->inPtrs[0];
        if (in.size() >= 2) {
            std::memcpy(in[0], left, sizeof(float) * (size_t)frames);
            std::memcpy(in[1], right, sizeof(float) * (size_t)frames);
            for (size_t c = 2; c < in.size(); ++c) std::memset(in[c], 0, sizeof(float) * (size_t)frames);
        } else if (in.size() == 1) {
            for (int32 i = 0; i < frames; ++i) in[0][i] = 0.5f * (left[i] + right[i]);
        }
        for (size_t b = 1; b < p->inPtrs.size(); ++b)
            for (float *ch : p->inPtrs[b]) std::memset(ch, 0, sizeof(float) * (size_t)frames);
    }
    ProcessData d;
    d.processMode = kRealtime;
    d.symbolicSampleSize = kSample32;
    d.numSamples = frames;
    d.numInputs = (int32)p->inBuses.size();
    d.numOutputs = (int32)p->outBuses.size();
    d.inputs = p->inBuses.empty() ? nullptr : p->inBuses.data();
    d.outputs = p->outBuses.data();
    d.inputParameterChanges = &p->inChanges;
    d.outputParameterChanges = &p->outChanges;
    d.processContext = &p->context;
    for (auto &b : p->outBuses) b.silenceFlags = 0;
    for (auto &b : p->inBuses) b.silenceFlags = 0;
    tresult r = p->processor->process(d);
    p->context.projectTimeSamples += frames;
    p->context.continousTimeSamples += frames;
    if (r != kResultOk) return (int32_t)(r == 0 ? -1 : r);
    auto &out = p->outPtrs[0];
    if (out.size() >= 2) {
        std::memcpy(left, out[0], sizeof(float) * (size_t)frames);
        std::memcpy(right, out[1], sizeof(float) * (size_t)frames);
    } else if (out.size() == 1) {
        std::memcpy(left, out[0], sizeof(float) * (size_t)frames);
        std::memcpy(right, out[0], sizeof(float) * (size_t)frames);
    }
    return 0;
}

int32_t lc_vst3_latency(lc_vst3_plugin *p) { return p && p->processor ? (int32_t)p->processor->getLatencySamples() : 0; }
int32_t lc_vst3_channels(lc_vst3_plugin *p) { return p ? p->mainInChannels : 0; }

bool lc_vst3_get_state(lc_vst3_plugin *p, uint8_t **out, int64_t *length) {
    if (!p || !out || !length) return false;
    auto *cs = new MemoryStream();
    auto *ks = new MemoryStream();
    bool ok = p->component->getState(cs) == kResultOk;
    if (p->controller && !p->controllerIsComponent) p->controller->getState(ks);
    // Blob: "LCV3" | u32 component length | component | u32 controller length | controller.
    size_t total = 4 + 4 + cs->data.size() + 4 + ks->data.size();
    uint8_t *buf = (uint8_t *)std::malloc(total);
    size_t o = 0;
    std::memcpy(buf, "LCV3", 4); o += 4;
    auto put32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) buf[o++] = (uint8_t)(v >> (8 * i)); };
    put32((uint32_t)cs->data.size());
    if (!cs->data.empty()) std::memcpy(buf + o, cs->data.data(), cs->data.size());
    o += cs->data.size();
    put32((uint32_t)ks->data.size());
    if (!ks->data.empty()) std::memcpy(buf + o, ks->data.data(), ks->data.size());
    cs->release();
    ks->release();
    *out = buf;
    *length = (int64_t)total;
    return ok;
}

bool lc_vst3_set_state(lc_vst3_plugin *p, const uint8_t *data, int64_t length) {
    if (!p || !data || length < 12 || std::memcmp(data, "LCV3", 4) != 0) return false;
    auto get32 = [&](int64_t at) { uint32_t v = 0; for (int i = 0; i < 4; ++i) v |= (uint32_t)data[at + i] << (8 * i); return v; };
    int64_t o = 4;
    uint32_t cl = get32(o); o += 4;
    if (o + cl + 4 > length) return false;
    const uint8_t *comp = data + o; o += cl;
    uint32_t kl = get32(o); o += 4;
    if (o + kl > length) return false;
    const uint8_t *ctrl = data + o;
    auto *cs = new MemoryStream(comp, cl);
    bool ok = p->component->setState(cs) == kResultOk;
    if (p->controller) {
        cs->pos = 0;
        p->controller->setComponentState(cs);
        if (kl > 0 && !p->controllerIsComponent) {
            auto *ks = new MemoryStream(ctrl, kl);
            p->controller->setState(ks);
            ks->release();
        }
    }
    cs->release();
    return ok;
}

int32_t lc_vst3_param_count(lc_vst3_plugin *p) { return p && p->controller ? p->controller->getParameterCount() : 0; }

bool lc_vst3_param_info(lc_vst3_plugin *p, int32_t index, uint32_t *id, char *title, int32_t title_cap,
                        char *units, int32_t units_cap, int32_t *steps, int32_t *flags) {
    if (!p || !p->controller) return false;
    ParameterInfo pi{};
    if (p->controller->getParameterInfo(index, pi) != kResultOk) return false;
    if (id) *id = pi.id;
    copyStr(title, title_cap, utf8(pi.title));
    copyStr(units, units_cap, utf8(pi.units));
    if (steps) *steps = pi.stepCount;
    if (flags) {
        int32_t f = 0;
        if (pi.flags & ParameterInfo::kCanAutomate) f |= 1;
        if (pi.flags & ParameterInfo::kIsReadOnly) f |= 2;
        if (pi.flags & (ParameterInfo::kIsHidden | ParameterInfo::kIsBypass)) f |= 4;
        *flags = f;
    }
    return true;
}

double lc_vst3_param_get(lc_vst3_plugin *p, uint32_t id) { return p && p->controller ? p->controller->getParamNormalized(id) : 0; }

void lc_vst3_param_set(lc_vst3_plugin *p, uint32_t id, double v) {
    if (!p || !p->controller) return;
    p->controller->setParamNormalized(id, v);
    p->ring.push(id, v);
}

void lc_vst3_param_display(lc_vst3_plugin *p, uint32_t id, double v, char *buf, int32_t cap) {
    if (!p || !p->controller) { copyStr(buf, cap, ""); return; }
    String128 s{};
    if (p->controller->getParamStringByValue(id, v, s) == kResultOk) copyStr(buf, cap, utf8(s));
    else { char t[32]; std::snprintf(t, sizeof t, "%.2f", v); copyStr(buf, cap, t); }
}

bool lc_vst3_has_editor(lc_vst3_plugin *p) {
    if (!p || !p->controller) return false;
    if (p->view) return true;
    IPlugView *v = p->controller->createView("editor");
    if (!v) return false;
#if defined(__APPLE__)
    bool ok = v->isPlatformTypeSupported(kPlatformTypeNSView) == kResultTrue;
#else
    bool ok = false;
#endif
    v->release();
    return ok;
}

bool lc_vst3_editor_open(lc_vst3_plugin *p, void *parent, int32_t *width, int32_t *height,
                         void (*resize)(void *, int32_t, int32_t), void *ctx) {
    if (!p || !p->controller || !parent) return false;
    lc_vst3_editor_close(p);
#if defined(__APPLE__)
    IPlugView *v = p->controller->createView("editor");
    if (!v) return false;
    if (v->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) { v->release(); return false; }
    p->frame.resize = resize;
    p->frame.ctx = ctx;
    v->setFrame(&p->frame);
    if (v->attached(parent, kPlatformTypeNSView) != kResultOk) { v->setFrame(nullptr); v->release(); return false; }
    ViewRect r{};
    if (v->getSize(&r) == kResultOk) {
        if (width) *width = r.getWidth();
        if (height) *height = r.getHeight();
    }
    p->view = v;
    return true;
#else
    (void)width; (void)height; (void)resize; (void)ctx;
    return false;
#endif
}

bool lc_vst3_editor_can_resize(lc_vst3_plugin *p) { return p && p->view && p->view->canResize() == kResultTrue; }

void lc_vst3_editor_set_size(lc_vst3_plugin *p, int32_t *width, int32_t *height) {
    if (!p || !p->view || !width || !height) return;
    ViewRect r(0, 0, *width, *height);
    p->view->checkSizeConstraint(&r);
    p->view->onSize(&r);
    *width = r.getWidth();
    *height = r.getHeight();
}

void lc_vst3_editor_close(lc_vst3_plugin *p) {
    if (!p || !p->view) return;
    p->view->removed();
    p->view->setFrame(nullptr);
    p->view->release();
    p->view = nullptr;
    p->frame.resize = nullptr;
    p->frame.ctx = nullptr;
}

} // extern "C"
