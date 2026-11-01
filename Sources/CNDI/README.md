# CNDI

LiveCore Studio's NDI® output. `LCNDI.c` loads the NDI 6 runtime at run time with `dlopen`
(`NDIlib_v6_load`), so LiveCore neither links nor ships the NDI library. The runtime comes from
NDI Tools or the NDI Runtime installer (http://ndi.link/NDIRedistV6Apple).

`ndi/` holds the NDI SDK headers, v6.3.0.3, unchanged. Each header carries its own MIT licence
notice (Copyright (C) 2023-2026 Vizrt NDI AB), which applies to that file only.

NDI® is a registered trademark of Vizrt NDI AB.
