# Third-party notices

Device Hub Pro is released under the MIT License (see `LICENSE`, Copyright (c) 2026 Emre Özturk and Device Hub Pro contributors). The Device Hub Pro app also contains the third-party components listed below. This file covers what ships inside `Device Hub Pro.app`: code linked into the executable and files in its resource bundles. The app uses the Swift runtime that macOS includes and bundles none. Build-time tools such as the protobuf and gRPC code generators do not ship. `Scripts/package-app.sh` turns this file into the Credits shown in **Device Hub Pro ▸ About Device Hub Pro**.

<!--
  Keep this list in sync with Package.resolved. Scripts/package-app.sh
  refuses to package when Package.resolved names a package that is neither in
  its SHIPPED_PACKAGES list (covered here) nor in BUILD_ONLY_PACKAGES. To see
  what is actually linked, read the link file list of a debug build:
  .build/out/Intermediates.noindex/DeviceHubPro.build/Debug/DeviceHubPro-p.build/Objects-normal/arm64/DeviceHubPro.LinkFileList
-->

## How the license terms are met

Most components use the Apache License 2.0. For the binary app, that license asks for four things:

- **A copy of the license.** Packaged builds contain each component's own license file, unchanged, in `Device Hub Pro.app/Contents/Resources/Licenses/`. The packaging script copies them from the resolved package checkouts. The scrcpy license also sits beside the server in the DeviceHubProKit resource bundle.
- **Attribution notices.** The copyright and attribution notices of each component are kept. This file names each copyright holder.
- **NOTICE files.** When a component includes a NOTICE file, its attribution notices must travel with the app. Packaged builds contain those NOTICE files, unchanged, in `Contents/Resources/Licenses/<package>/`. Each summary below says what the NOTICE credits.
- **Marked changes.** Changed files must say they were changed. Device Hub Pro ships the scrcpy server and `emulator_controller.proto` unchanged. `bundletool_toc.proto` is a partial restatement of bundletool's messages, and its header says so.

Some components are licensed under "Apache-2.0 with Runtime Library Exception" (the Swift project's license). That exception drops the attribution requirement for compiled binaries. They are listed here anyway.

The BoringSSL copies inside SwiftNIO SSL and Swift Crypto need one more step. Their source files point to BoringSSL's `LICENSE` file for the full terms, but the vendored copies leave that file out. For the older copy, those terms are the OpenSSL and original SSLeay licenses plus ISC. They ask a binary distribution to reproduce the copyright notices, the license conditions and the disclaimer in its documentation, and to keep the OpenSSL Project's acknowledgment. The repository therefore keeps BoringSSL's `LICENSE`, unchanged, for each vendored revision in `packaging/licenses/boringssl-<revision>/` (docs/distribution.md says how to add it). Builds for other people contain it as `Licenses/swift-nio-ssl/BoringSSL-LICENSE` and `Licenses/swift-crypto/BoringSSL-LICENSE`. `Scripts/package-app.sh` refuses to build if a file differs from upstream's. It also refuses when a file is missing and the build is signed with a real identity or run with `--require-licenses` (as the release workflow does). A local ad-hoc build without the files is marked as not for sharing (docs/distribution.md, "BoringSSL's license").

## Components that run on the Android device

### scrcpy server 3.1

- Where: `Contents/Resources/DeviceHubPro_DeviceHubProKit.bundle` (`scrcpy-server`). It is pushed to the device at run time to mirror physical phones. It is the unmodified `scrcpy-server-v3.1` release asset.
- License: Apache-2.0. The full text is `LICENSE.scrcpy`, in the same bundle and in `Licenses/scrcpy/`.
- Copyright: Copyright (C) 2018 Genymobile; Copyright (C) 2018-2024 Romain Vimont.
- Source: [github.com/Genymobile/scrcpy](https://github.com/Genymobile/scrcpy)

## Protocol definitions compiled into Device Hub Pro

### Android Emulator gRPC API (`emulator_controller.proto`)

- Where: Swift code is generated from `Sources/DeviceHubProKit/Protos/emulator_controller.proto` and linked into the executable. The proto file is an unchanged copy of `emulator/lib/emulator_controller.proto` from the Android SDK.
- License: Apache-2.0.
- Copyright: Copyright (C) 2018 The Android Open Source Project.
- Source: the Android Emulator (`platform/external/qemu` in AOSP).

### bundletool table of contents (`bundletool_toc.proto`)

- Where: Swift code is generated from `Sources/DeviceHubProKit/Protos/bundletool_toc.proto`. This file restates a subset of bundletool's `BuildApksResult` messages and field numbers, so Device Hub Pro can read `.apks` sets. It is derived from bundletool's `commands.proto` and `targeting.proto`.
- License: Apache-2.0.
- Copyright: bundletool's sources carry Copyright (C) 2017 The Android Open Source Project.
- Source: [github.com/google/bundletool](https://github.com/google/bundletool)

## Code derived from other projects

### idb (FBSimulatorControl)

- Where: `Sources/DeviceHubProSimBridge`, linked into the executable. The simulator bridge ports logic from idb's `FBSimulatorControl`: how to find a simulator's main display and register its screen callbacks, how to open the `dtuhidd` XPC connection, the `dtuhidd` message formats, and its connection retry timing. No idb source file is copied; `Sources/DeviceHubProSimBridge/PROVENANCE.md` lists each name taken from idb and the file it came from.
- License: MIT, whose terms follow.
- Copyright: Copyright (c) Meta Platforms, Inc. and affiliates.
- Source: [github.com/facebook/idb](https://github.com/facebook/idb)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### ipb (fast input helper)

- Where: `fastinput/` (shipped in `Contents/Resources/fastinput`, built into the user's cache on first use when fast input is switched on). The Mercury / UniversalHID glue and assembly thunks that let a resident helper send touch and button events to a connected iPhone are taken from ipb at a pinned commit; `fastinput/PROVENANCE.md` lists each file and what was changed or left out.
- License: MIT. The full text is `fastinput/LICENSE`, unchanged, also in `Contents/Resources/fastinput/`.
- Copyright: Copyright (c) 2026 Borealin and ipbtools contributors.
- Source: [github.com/ipbtools/ipb](https://github.com/ipbtools/ipb)

## Swift packages linked into the executable

The versions are the ones pinned in `Package.resolved`.

### gRPC Swift 2 — 2.4.3 (`GRPCCore`)

- License: Apache-2.0. Copyright: The gRPC Swift Project; gRPC Authors.
- NOTICE: credits code derived from SwiftNIO HTTP/2 (case-insensitive string comparison) and from swift-extras-base64. Both are Apache-2.0.
- Source: [github.com/grpc/grpc-swift-2](https://github.com/grpc/grpc-swift-2)

### gRPC Swift NIO Transport — 2.9.2 (`GRPCNIOTransportCore`, `GRPCNIOTransportHTTP2`)

- License: Apache-2.0. Copyright: The gRPC Swift Project; gRPC Authors.
- NOTICE: credits code derived from swift-extras-base64 (Apache-2.0). Its zlib module links the system's `libz` and does not bundle zlib.
- Source: [github.com/grpc/grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport)

### gRPC Swift Protobuf — 2.4.1 (`GRPCProtobuf`)

- License: Apache-2.0. Copyright: The gRPC Swift Project; gRPC Authors.
- NOTICE: credits code derived from SwiftNIO (locks and test scripts), SwiftNIO HTTP/2, the Swift project (a backpressure-aware async stream), swift-extras-base64 and Swift OpenAPI Generator. All are Apache-2.0. The OpenAPI Generator code is in the code generator, which does not ship.
- Source: [github.com/grpc/grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf)

### SwiftProtobuf — 1.38.1 (`SwiftProtobuf`)

- License: Apache-2.0 with Runtime Library Exception. Copyright: Apple Inc. and the project authors.
- The library contains Swift code generated from Google's well-known protobuf types. Those definitions are Copyright 2008 Google Inc. and are licensed under the BSD 3-Clause License. The Google Protocol Buffers license file ships in `Licenses/swift-protobuf/`.
- Source: [github.com/apple/swift-protobuf](https://github.com/apple/swift-protobuf)

### SwiftNIO — 2.102.0 (`NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOTLS`, `NIOFoundationCompat`, and related modules)

- License: Apache-2.0. Copyright: The SwiftNIO Project; Apple Inc. and the SwiftNIO project authors.
- Contains llhttp from Node.js, in the HTTP/1 parser. llhttp is MIT-licensed, Copyright Fedor Indutny, 2018, and its license file ships in `Licenses/swift-nio/`.
- Contains `cpp_magic.h` from uSHET, which is MIT-licensed (Thomas Nixon and Jonathan Heathcote).
- NOTICE: says SwiftNIO is heavily influenced by Netty (Apache-2.0). It also credits code derived from Fabian Fett's Base64, AsyncHTTPClient, Swift Certificates, Swift System and Swift Package Manager, and FreeBSD's SHA-1 (BSD 3-Clause, WIDE Project). The SHA-1 code is in a module (`CNIOSHA1`, used by SwiftNIO's WebSocket support) that Device Hub Pro does not link.
- Source: [github.com/apple/swift-nio](https://github.com/apple/swift-nio)

### SwiftNIO HTTP/2 — 1.46.0 (`NIOHTTP2`, `NIOHPACK`)

- License: Apache-2.0. Copyright: The SwiftNIO Project.
- NOTICE: credits Netty's influence, plus code derived from a test-file script by Tony Stone, Swift Protobuf (a fuzzing harness) and gRPC Swift NIO Transport (a graceful-shutdown connection manager).
- Source: [github.com/apple/swift-nio-http2](https://github.com/apple/swift-nio-http2)

### SwiftNIO SSL — 2.37.4 (`NIOSSL`, with its vendored BoringSSL `CNIOBoringSSL`)

- License: Apache-2.0. Copyright: The SwiftNIO Project.
- Contains BoringSSL at revision `817ab07ebb53da35afea409ab9328f578492832d`. At that revision, the BoringSSL files carry OpenSSL-license headers (Copyright The OpenSSL Project Authors) and ISC-license headers (Copyright The BoringSSL Authors; Google Inc.). They also contain code generated by fiat-crypto. BoringSSL includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit, and cryptographic software written by Eric Young.
- BoringSSL's `LICENSE` at that revision holds the combined terms: the OpenSSL License, the original SSLeay License, the ISC license and the terms of the fiat-crypto code, plus the licenses of test and build code that is not in the app. It ships unchanged as `Licenses/swift-nio-ssl/BoringSSL-LICENSE`. Upstream copy: [boringssl.googlesource.com/boringssl](https://boringssl.googlesource.com/boringssl/+/817ab07ebb53da35afea409ab9328f578492832d/LICENSE).
- NOTICE: credits Netty's influence, code derived from grpc-swift and a test-file script by Tony Stone, and the BoringSSL code.
- Source: [github.com/apple/swift-nio-ssl](https://github.com/apple/swift-nio-ssl)

### SwiftNIO Extras — 1.35.1 (`NIOExtras`, `NIOCertificateReloading`)

- License: Apache-2.0. Copyright: The SwiftNIO Project.
- NOTICE: credits code derived from AsyncHTTPClient and a test-file script by Tony Stone. It also mentions a vendored zlib, which lives in a module Device Hub Pro does not link.
- Source: [github.com/apple/swift-nio-extras](https://github.com/apple/swift-nio-extras)

### SwiftNIO Transport Services — 1.28.0 (`NIOTransportServices`)

- License: Apache-2.0. Copyright: Apple Inc. and the SwiftNIO project authors.
- Source: [github.com/apple/swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services)

### Swift Crypto — 4.5.2 (`Crypto`, `CryptoExtras`, with its vendored BoringSSL `CCryptoBoringSSL`)

- License: Apache-2.0. Copyright: The SwiftCrypto Project.
- Contains BoringSSL at revision `0226f30467f540a3f62ef48d453f93927da199b6`. At that revision, the files carry Apache-2.0 headers (Copyright The BoringSSL Authors, The OpenSSL Project Authors, and others). They also contain code generated by fiat-crypto.
- BoringSSL's `LICENSE` at that revision holds the Apache License 2.0, plus the Go license of test code that is not built into the app. It ships unchanged as `Licenses/swift-crypto/BoringSSL-LICENSE`. Upstream copy: [boringssl.googlesource.com/boringssl](https://boringssl.googlesource.com/boringssl/+/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE).
- NOTICE: credits code derived from SwiftNIO and test vectors from Google's Wycheproof project. The test vectors are not in the app.
- Source: [github.com/apple/swift-crypto](https://github.com/apple/swift-crypto)

### Swift Certificates — 1.20.0 (`X509`)

- License: Apache-2.0. Copyright: The SwiftCertificates Project.
- NOTICE: credits code derived from SwiftASN1, SwiftNIO, SwiftNIO SSH and Swift OpenAPI Generator. It also credits UNIX timestamp code derived from musl libc (MIT), and test data from Webpki and pyca/cryptography. The test data is not in the app.
- Source: [github.com/apple/swift-certificates](https://github.com/apple/swift-certificates)

### Swift ASN.1 — 1.7.2 (`SwiftASN1`)

- License: Apache-2.0. Copyright: The SwiftASN1 Project.
- NOTICE: credits scripts derived from SwiftNIO and Swift OpenAPI Generator.
- Source: [github.com/apple/swift-asn1](https://github.com/apple/swift-asn1)

### Swift Log — 1.15.1 (`Logging`)

- License: Apache-2.0. Copyright: The SwiftLog Project; Apple Inc. and the Swift Logging API project authors.
- NOTICE: credits the lock implementation and other code derived from SwiftNIO.
- Source: [github.com/apple/swift-log](https://github.com/apple/swift-log)

### Swift Service Lifecycle — 2.12.0 (`ServiceLifecycle`, `UnixSignals`)

- License: Apache-2.0. Copyright: The ServiceLifecycle Project.
- NOTICE: credits lock code derived from SwiftNIO, and says the package uses Swift Async Algorithms.
- Source: [github.com/swift-server/swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle)

### Swift Async Algorithms — 1.1.5 (`AsyncAlgorithms`)

- License: Apache-2.0 with Runtime Library Exception. Copyright: Apple Inc. and the Swift project authors.
- Source: [github.com/apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms)

### Swift Atomics — 1.3.1 (`Atomics`)

- License: Apache-2.0 with Runtime Library Exception. Copyright: Apple Inc. and the Swift project authors.
- Source: [github.com/apple/swift-atomics](https://github.com/apple/swift-atomics)

### Swift Collections — 1.6.0 (`DequeModule`, `OrderedCollections`)

- License: Apache-2.0 with Runtime Library Exception. Copyright: Apple Inc. and the Swift project authors.
- Source: [github.com/apple/swift-collections](https://github.com/apple/swift-collections)

### Sparkle — 2.10.0 (`Sparkle.framework`, with its Autoupdate helper, Updater app and XPC services)

- License: MIT. Copyright: Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd Ranch and the Sparkle contributors. Its `LICENSE` also carries the terms of the code Sparkle bundles (bsdiff and bspatch, sais-lite, ed25519 and SUSpiffy); the packaged copy is unchanged.
- Embedded in `Contents/Frameworks` and used only when the build names an appcast (`Check for Updates…`, Settings ▸ Updates).
- Source: [github.com/sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)

## Resolved packages that do not ship

Swift Algorithms, Swift Numerics, Swift System, Swift HTTP Types and Swift HTTP Structured Headers appear in `Package.resolved`. Only build-time tools or modules that Device Hub Pro does not link depend on them, so none of their code is in the app.
