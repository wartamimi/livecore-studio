# CSyphon

Server side of the [Syphon framework](https://github.com/Syphon/Syphon-Framework) (BSD licence,
`License.txt`), vendored from commit f4761677a45b8034a3c2069ec0f3d2553da81fba so the app needs no
embedded framework (an ad-hoc signed app with hardened runtime cannot load one).

The server files plus the client side (`SyphonClientBase`, `SyphonClientConnectionManager`,
`SyphonServerDirectory`) are included; the client is only used by `LCSyphonProbe` for the CI check
`livecore-syphon-check`. Changes from upstream:
- every file is wrapped in `#if defined(__APPLE__)` (the package also builds on Linux);
- `SyphonPrivate.h` imports AppKit and defines `SYPHONLOG` (upstream does this in its prefix header);
- `SyphonSubclassing.h` imports the local headers.

`LCSyphonServer` is LiveCore's own blit-only Metal server built on `SyphonServerBase`; `LCSyphonProbe` is a
minimal client used to prove another process can discover the server and read its frames.
