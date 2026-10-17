# Xiaomi PC Manager on Linux — investigation notes

Reverse-engineering the packaging of **Xiaomi PC Manager 5.8.1.121** to find out
whether it can run on Linux under Wine, and if not, exactly where it dies.

**Status: does not run.** The blocker is identified and reproducible. Details
below — no Xiaomi code or binaries are included in this repository.

## Why look at this

Xiaomi PC Manager is a Windows-only phone-manager utility. It has no Linux
build and no documented protocol. The interesting question is whether the
obvious path — unpack, run under Wine — works, and if not, whether the failure
is something you can shim your way around or a hard stop.

## Unpacking the installer

The installer is a self-extracting archive. Extracted, it resolves into 21
segments:

| Segment | Size | Files | What it is |
|---|---|---|---|
| `00_seg0` | 736K | 3 | MSVC runtime (`msvcp140`, `vcruntime140`) |
| `01_dependences3` | 1.5M | 6 | `PcClipboard` helpers |
| `02_dependences4` | 924K | 4 | MSVC runtime, 32-bit side |
| `03_msi` | 104K | 1 | `cab1.cab` — MSI payload |
| `04_shellExt` | 72K | 1 | `MiDropShellExt.dll` — Explorer shell extension |
| **`05_main`** | **587M** | **1548** | **The application itself** |
| `06_distfile` | 2.7M | 6 | `dokan2.dll`, `distfile.exe` — Dokan filesystem |
| `07_vj` | 35M | 22 | `PcClipboard` |
| `08_xQ` | 14M | 22 | App Store plugins, `MiSceneClient`, protobuf |
| `09_Gesture` | 240K | 1 | Gesture plugins |
| `10_distfs` | 34M | 25 | `AISearchSDK`, `aisearchservice`, `cert.pem` |
| `11_launcher` | 876K | 1 | `Launch.exe` |
| `12_run` | 4.0K | 1 | `.run` marker |
| `13_Vz` | 64K | 3 | `RadioControl.sys` — **kernel driver** |
| `14_XeDMFT` | 86M | 10 | Media Foundation Transform, `openvino.dll` |
| `15_DMFT_RT` | 736K | 3 | DMFT runtime |
| `16_aiservice` | 132M | 2 | AI service setup + .NET desktop runtime |
| `18_14` | 111M | 69 | `AIClientBusiness`, ffmpeg libs, assets |
| `19_meta` | 4.0K | 1 | `meta_data.xml` — distributed hardware registry |
| `99_drivers` | 285M | 55 | `devcon.exe`, device driver installs |

Roughly 1.2 GB extracted, of which **587 MB is the app** and the rest is
Windows plumbing that cannot function on Linux under any circumstances:

- a kernel-mode driver (`RadioControl.sys`)
- a Dokan-backed filesystem layer
- 285 MB of device-driver install payloads for Xiaomi hardware
- ~243 MB of OpenVINO/protobuf AI service and ffmpeg media plumbing

This is the first real result: **the phone-management surface is a small
fraction of the installer**, and the bulk is Windows-specific integration that
Linux will never run. Scope of what *could* work is much smaller than the
marketing implies.

### The distributed hardware registry

`19_meta/meta_data.xml` declares hardware capabilities that peers discover
over the network, as a JSON-in-XML registry:

```json
{ "dhList": [ { "distributed_hardware_info": {
      "attr": "{\"version\":1,\"defaults\":{\"params\":"
              "[{\"channels\":1,\"bitDepth\":16,\"sampleRate\":16000}]}}",
      "dhOwner": "com.xiaomi.distaudio",
      "dhType": 3 } } ] }
```

Audio streaming advertises mono / 16-bit / 16 kHz under
`com.xiaomi.distaudio`. This is the mechanism by which a PC Manager instance
announces it can receive phone audio — and it is the piece that would need
reimplementation before any Linux client could talk to a Windows peer.

## The connectivity stack

The main payload carries 169 non-framework assemblies. Most are third-party
libraries (CommunityToolkit.Mvvm, FFmpeg, Boost, nlohmann/json, CommandLine),
but a handful are Xiaomi's own and they map the connectivity protocol cleanly.
Recovered from exported symbol names and log strings:

| Layer | Assembly | Contents |
|---|---|---|
| Discovery | `MiScanner.dll` | `AvailableBtScanner`, `PairedBtScanner`, `BaseBtScanner`, `WifiScanner`, `RadioWatcher`, `ScannerHelper`, `IDeviceScannerCallback` |
| Transport | `MiMultiDeviceConnection.dll` | `micont::channel`, `micont::networking`, `micont::IListener`, on Boost.ASIO |
| Session/media | same | `mi_media::MiMultiDeviceImpl`, `CRPClient`, `CRPCBusinessMgr`, `CLyraCommonMessageMgr`, `CallbackClient` |
| Arbitration | `ConcurrentSession.dll` | `ConcurrentSessionExecutor` — `RequestJoinSession`, `LeaveSession`, `ReportPreemptResult` |
| Files | `lyra_dist_file_sys.dll` | distributed file transfer |

### What this tells you

**Discovery is Bluetooth and WiFi, not mDNS.** `MiScanner` is a native C++
library in namespace `mi_scanner` built around BT scan callbacks plus a
`WifiScanner`. There is no multicast service advertising anywhere in the
payload — so there is no zeroconf-style endpoint to sniff for a device.

**The transport is JSON over Boost.ASIO.** `micont` provides channel and
networking primitives, and nlohmann/json is linked throughout. That is a
considerably friendlier protocol than a custom binary framing would be.

**Sessions are arbitrated, not just connected.** This is the part with actual
design in it. `ConcurrentSessionExecutor` exposes `RequestJoinSession`,
`LeaveSession` and `ReportPreemptResult`, and the embedded log strings name the
conflict cases directly:

```text
[mi_media][lyra] OnReceiveSessionRequestResult can not find device_id =
[mi_media][lyra] OnReceiveSessionRequestResult not a call action device_id =
[mi_media][mi_multi_device_impl] LeavePreemptSession cur_preempt_device_id =
```

So when two clients both want the same device, one is **preempted** rather than
merely refused. A client has to handle being the party that loses — the
result code is delivered asynchronously and distinguished by `device_id`,
`session_id`, `conflict_session_type` and `packet_type`.

That is the single most useful thing in this repository: the surface a
reimplementation would have to get right is not the streaming, it is session
conflict resolution. Everything above it is JSON over sockets.

> **Caveat.** This is static analysis — symbol tables, string tables and
> embedded log messages. Nothing here is decompiled logic, and no protocol
> implementation is included or implied. Treat it as a map of what to read
> next, not a specification.

## Running it

Minimal deployment: a bare `win64` prefix, the `05_main` payload copied in,
and the app launched from that directory rather than installed into the prefix.

Two override DLLs are configured, because the app probes the host before
starting:

```bash
WINEDLLOVERRIDES="wtsapi32=n,b;msimg32=n,b"
```

`wtsapi32` is the terminal-services API — the app queries it to determine the
host model, and will not proceed on an unrecognised one. A compatibility DLL
standing in for `wtsapi32` resolves that check. **That DLL is a third-party
artefact and is deliberately not included in this repo**; it exports 69
ordinals covering the WTS surface with no name table.

`msimg32` is overridden for the same reason — the app looks for a
version/model table there.

## Where it dies

The app starts, and gets further than expected:

```
Loaded Microsoft.ui.xaml.dll
Loaded System.Runtime.CompilerServices.Unsafe.dll
Loaded System.Security.Cryptography.Algorithms.dll
Loaded System.Security.Cryptography.Primitives.dll
...
wine: Call from 00006FFFFFC4E22A to unimplemented function
       ntdll.dll.NtCreateWaitCompletionPacket, aborting
Application: XiaomiPcManager.exe
CoreCLR Version: 6.0.3624.51421
The process was terminated due to an unhandled exception.
```

**Root cause:** the application is a .NET 6 / WinUI XAML app. The CoreCLR
runtime initialises, the XAML framework loads, and roughly twenty managed
assemblies resolve correctly — then the runtime hits
`ntdll!NtCreateWaitCompletionPacket`, which Wine 11.0 (Staging) does not
implement. CoreCLR takes an unhandled exception and the process aborts.

### Why this is a hard stop

This is not a `WINEDLLOVERRIDES` problem. `NtCreateWaitCompletionPacket` is an
internal `ntdll` system-call wrapper, not a Win32 export, so it cannot be
intercepted by dropping a DLL next to the binary the way the model check was.
Closing it would need either a Wine patch carrying the syscall implementation,
or a replacement `ntdll` — both of which are upstream Wine changes, not
something a shim can do.

The dependency chains that *do* work are worth recording: CoreCLR, WinUI XAML,
and the cryptography assemblies all load under Wine without intervention. The
port is blocked in one place, not everywhere.

## Running it as a service

`mipcmanager.service` in this repo is the hardened user-unit used to launch it.
Note the sandboxing, which is the part worth reusing regardless of whether the
app ever starts:

```ini
[Service]
Type=simple
Environment=WINEPREFIX=%h/.local/share/mipcmanager/wine
ExecStart=%h/.local/share/mipcmanager/wine_wrapper.sh run
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.local/share/mipcmanager
```

`ProtectSystem=strict` plus `ProtectHome=read-only` means the Wine prefix is
writable and nothing else is, and `NoNewPrivileges` stops the process gaining
rights via setuid binaries inside the prefix — a real concern when running an
unsupported vendor binary.

## Layout

```text
.
├── README.md
├── mipcmanager.service     # hardened user unit
└── wine_wrapper.sh         # prefix provisioning + launch
```

## Legal

Xiaomi PC Manager is a Xiaomi product. No Xiaomi code, binaries, installer
payloads, or the `wtsapi32` compatibility DLL are redistributed here. This is
an analysis of a packaging layout, plus a reproduction harness.
