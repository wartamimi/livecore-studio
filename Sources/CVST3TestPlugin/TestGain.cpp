// LiveCore Studio CI test plug-in: "LiveCore Test Gain", a stereo VST 3 effect with one
// parameter (gain, normalised 0…1 = ×0…×2, default 0.5 = unity). Used only by
// livecore-plugin-check to prove the VST 3 host loads, processes, automates and restores state.
#include "LCVST3TestPlugin.h"
#include "../CVST3/sdk/pluginterfaces/base/funknown.cpp"
#include "../CVST3/sdk/pluginterfaces/base/coreiids.cpp"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"

#include <cstring>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace Steinberg { namespace Vst {
DEF_CLASS_IID (IComponent)
DEF_CLASS_IID (IAudioProcessor)
DEF_CLASS_IID (IEditController)
DEF_CLASS_IID (IParamValueQueue)
DEF_CLASS_IID (IParameterChanges)
}}

extern "C" int32_t lc_vst3_test_plugin_marker(void) { return 1; }

namespace {
// 4C435447-4149-4E00-0000-000000000001 ("LCTGAIN")
const TUID kGainCID = INLINE_UID(0x4C435447, 0x41494E00, 0x00000000, 0x00000001);

void str16(const char *s, String128 d) { int i = 0; for (; s[i] && i < 127; ++i) d[i] = (char16)s[i]; d[i] = 0; }

class Gain : public IComponent, public IAudioProcessor, public IEditController {
public:
    int32 refs = 1;
    double gainNorm = 0.5;   // processor value
    double ctrlNorm = 0.5;               // controller value
    IComponentHandler *handler = nullptr;

    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, IComponent::iid) ||
            FUnknownPrivate::iidEqual(iid, IPluginBase::iid)) { addRef(); *obj = static_cast<IComponent *>(this); return kResultOk; }
        if (FUnknownPrivate::iidEqual(iid, IAudioProcessor::iid)) { addRef(); *obj = static_cast<IAudioProcessor *>(this); return kResultOk; }
        if (FUnknownPrivate::iidEqual(iid, IEditController::iid)) { addRef(); *obj = static_cast<IEditController *>(this); return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return (uint32)++refs; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { int32 r = --refs; if (r == 0) delete this; return (uint32)r; }
    // IPluginBase (shared by IComponent and IEditController)
    tresult PLUGIN_API initialize(FUnknown *) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API terminate() SMTG_OVERRIDE { return kResultOk; }
    // IComponent
    tresult PLUGIN_API getControllerClassId(TUID) SMTG_OVERRIDE { return kNotImplemented; }
    tresult PLUGIN_API setIoMode(IoMode) SMTG_OVERRIDE { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType t, BusDirection) SMTG_OVERRIDE { return t == kAudio ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType t, BusDirection d, int32 i, BusInfo &b) SMTG_OVERRIDE {
        if (t != kAudio || i != 0) return kInvalidArgument;
        b.mediaType = kAudio; b.direction = d; b.channelCount = 2; str16(d == kInput ? "In" : "Out", b.name);
        b.busType = kMain; b.flags = BusInfo::kDefaultActive; return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo &, RoutingInfo &) SMTG_OVERRIDE { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API setActive(TBool) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API setState(IBStream *s) SMTG_OVERRIDE {
        double v = 0.5; int32 n = 0;
        if (!s || s->read(&v, sizeof v, &n) != kResultOk || n != sizeof v) return kResultFalse;
        gainNorm = v; return kResultOk;
    }
    tresult PLUGIN_API getState(IBStream *s) SMTG_OVERRIDE { double v = gainNorm; return s ? s->write(&v, sizeof v, nullptr) : kResultFalse; }
    // IAudioProcessor
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *in, int32 ni, SpeakerArrangement *out, int32 no) SMTG_OVERRIDE {
        return ni == 1 && no == 1 && in[0] == SpeakerArr::kStereo && out[0] == SpeakerArr::kStereo ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32 i, SpeakerArrangement &a) SMTG_OVERRIDE {
        if (i != 0) return kInvalidArgument; a = SpeakerArr::kStereo; return kResultOk;
    }
    tresult PLUGIN_API canProcessSampleSize(int32 s) SMTG_OVERRIDE { return s == kSample32 ? kResultTrue : kResultFalse; }
    uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE { return 0; }
    tresult PLUGIN_API setupProcessing(ProcessSetup &) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API setProcessing(TBool) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API process(ProcessData &d) SMTG_OVERRIDE {
        if (d.inputParameterChanges) {
            for (int32 i = 0; i < d.inputParameterChanges->getParameterCount(); ++i) {
                IParamValueQueue *q = d.inputParameterChanges->getParameterData(i);
                int32 off; ParamValue v;
                if (q && q->getParameterId() == 0 && q->getPointCount() > 0 && q->getPoint(q->getPointCount() - 1, off, v) == kResultOk) gainNorm = v;
            }
        }
        if (d.numInputs < 1 || d.numOutputs < 1) return kResultOk;
        float g = (float)(gainNorm * 2.0);
        for (int32 c = 0; c < 2; ++c)
            for (int32 i = 0; i < d.numSamples; ++i) d.outputs[0].channelBuffers32[c][i] = d.inputs[0].channelBuffers32[c][i] * g;
        return kResultOk;
    }
    uint32 PLUGIN_API getTailSamples() SMTG_OVERRIDE { return 0; }
    // IEditController
    tresult PLUGIN_API setComponentState(IBStream *s) SMTG_OVERRIDE {
        double v = 0.5; int32 n = 0;
        if (s && s->read(&v, sizeof v, &n) == kResultOk && n == sizeof v) ctrlNorm = v;
        return kResultOk;
    }
    int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE { return 1; }
    tresult PLUGIN_API getParameterInfo(int32 i, ParameterInfo &p) SMTG_OVERRIDE {
        if (i != 0) return kInvalidArgument;
        std::memset(&p, 0, sizeof p);
        p.id = 0; str16("Gain", p.title); str16("Gain", p.shortTitle); str16("x", p.units);
        p.defaultNormalizedValue = 0.5; p.flags = ParameterInfo::kCanAutomate; return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue v, String128 s) SMTG_OVERRIDE {
        char b[32]; std::snprintf(b, sizeof b, "%.2f", v * 2); str16(b, s); return kResultOk;
    }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar *, ParamValue &) SMTG_OVERRIDE { return kNotImplemented; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue v) SMTG_OVERRIDE { return v * 2; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue v) SMTG_OVERRIDE { return v / 2; }
    ParamValue PLUGIN_API getParamNormalized(ParamID) SMTG_OVERRIDE { return ctrlNorm; }
    tresult PLUGIN_API setParamNormalized(ParamID, ParamValue v) SMTG_OVERRIDE { ctrlNorm = v; return kResultOk; }
    tresult PLUGIN_API setComponentHandler(IComponentHandler *h) SMTG_OVERRIDE { handler = h; return kResultOk; }
    IPlugView *PLUGIN_API createView(FIDString) SMTG_OVERRIDE { return nullptr; }
private:
    virtual ~Gain() = default;
};

// IComponent::setState and IEditController::setState share a signature: one implementation
// serves both (the controller has no state of its own here).

class Factory : public IPluginFactory2 {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, IPluginFactory::iid) ||
            FUnknownPrivate::iidEqual(iid, IPluginFactory2::iid)) { *obj = this; return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *i) SMTG_OVERRIDE {
        std::memset(i, 0, sizeof *i); std::strcpy(i->vendor, "LiveCore Studio"); i->flags = PFactoryInfo::kUnicode; return kResultOk;
    }
    int32 PLUGIN_API countClasses() SMTG_OVERRIDE { return 1; }
    tresult PLUGIN_API getClassInfo(int32 i, PClassInfo *c) SMTG_OVERRIDE {
        if (i != 0) return kInvalidArgument;
        std::memset(c, 0, sizeof *c); std::memcpy(c->cid, kGainCID, 16); c->cardinality = PClassInfo::kManyInstances;
        std::strcpy(c->category, kVstAudioEffectClass); std::strcpy(c->name, "LiveCore Test Gain"); return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 i, PClassInfo2 *c) SMTG_OVERRIDE {
        if (i != 0) return kInvalidArgument;
        std::memset(c, 0, sizeof *c); std::memcpy(c->cid, kGainCID, 16); c->cardinality = PClassInfo::kManyInstances;
        std::strcpy(c->category, kVstAudioEffectClass); std::strcpy(c->name, "LiveCore Test Gain");
        std::strcpy(c->subCategories, "Fx|Tools"); std::strcpy(c->vendor, "LiveCore Studio"); std::strcpy(c->version, "1.0.0");
        std::strcpy(c->sdkVersion, "VST 3.8"); return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) SMTG_OVERRIDE {
        if (!FUnknownPrivate::iidEqual(cid, kGainCID)) { *obj = nullptr; return kNoInterface; }
        Gain *g = new Gain();
        tresult r = g->queryInterface(iid, obj);
        g->release();
        return r;
    }
};
Factory gFactory;
} // namespace

extern "C" {
SMTG_EXPORT_SYMBOL IPluginFactory *PLUGIN_API GetPluginFactory() { return &gFactory; }
#if defined(__APPLE__)
SMTG_EXPORT_SYMBOL bool bundleEntry(void *) { return true; }
SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }
#else
SMTG_EXPORT_SYMBOL bool ModuleEntry(void *) { return true; }
SMTG_EXPORT_SYMBOL bool ModuleExit() { return true; }
#endif
}
