# CSyphon

Server side of the [Syphon framework](https://github.com/Syphon/Syphon-Framework) (BSD licence,
`License.txt`), vendored from commit f4761677a45b8034a3c2069ec0f3d2553da81fba so the app needs no
embedded framework (an ad-hoc signed app with hardened runtime cannot load one).

Only the files a server needs are included. Changes from upstream:
- every file is wrapped in `#if defined(__APPLE__)` (the package also builds on Linux);
- `SyphonPrivate.h` imports AppKit and defines `SYPHONLOG` (upstream does this in its prefix header);
- `SyphonSubclassing.h` imports the local server header and drops the client category.

`LCSyphonServer` is LiveCore's own blit-only Metal server built on `SyphonServerBase`.
