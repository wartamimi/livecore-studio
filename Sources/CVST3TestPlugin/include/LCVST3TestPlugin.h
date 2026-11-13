// LiveCore Studio CI test plug-in: a VST 3 gain effect used by livecore-plugin-check.
#pragma once
#include <stdint.h>
/// Keeps the linker from dropping the plug-in when it is built as a dynamic library.
#ifdef __cplusplus
extern "C"
#endif
int32_t lc_vst3_test_plugin_marker(void);
