# CVST3 — VST 3 effect host

`LCVST3.cpp` is LiveCore Studio's own minimal VST 3 host (scan, load, process, parameters,
state, NSView editor). It uses only Steinberg's plug-in interface headers in
`sdk/pluginterfaces` (vst3_pluginterfaces, MIT licence since VST SDK 3.8 — see
`sdk/pluginterfaces/LICENSE.txt`). No other part of the VST 3 SDK is included.

VST is a registered trademark of Steinberg Media Technologies GmbH. LiveCore Studio does not
use the VST logo.
