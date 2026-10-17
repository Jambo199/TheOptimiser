# Security & Reverse-Engineering Audit — 18 Windows tweak/debloat projects

> **AtlasOS (Atlas-OS/Atlas)** was added after the original 17 — see the **Addendum** at the end for its findings. It is folded into ThE OptImiseR's catalogue (299 unique new tweaks), with its Defender/telemetry removal excluded on the same grounds as Revision Tool.

**Date:** 2026-10-15
**Analyst tooling:** REA (Reverse Engineer Anything) MCP + Ghidra 12.1.4, ILSpy (`ilspycmd` 9.1), innounp 2.2.13, NanaZip, Microsoft Defender (`MpCmdRun.exe`), PowerShell `Get-AuthenticodeSignature`, custom Python scanners.
**Host:** Windows 11 Pro, build 26200.

---

## 1. What "audited" means here

For each project I did as many of the following as the project allowed:

1. **Clone the source** at the current `HEAD` (shallow).
2. **Download the shipped release** binary/script and **verify its SHA-256** against the digest GitHub publishes for the asset (where GitHub provides one).
3. **Decompile** every shipped binary — .NET assemblies to C# (ILSpy), native DLLs/EXEs to pseudocode (Ghidra via REA), Rust/Go metadata where present.
4. **Compare binary to source** — for .NET, confirm every type in the binary is declared in the matching source tag (so the published build isn't carrying hidden code); for scripts, diff the released file against the tagged source.
5. **Scan behaviour** — grep decompiled + source for a fixed set of malware/risky patterns (remote code execution, process injection, keylogging, credential/browser-data theft, Defender tampering, root-cert installs, persistence, exfil endpoints, miners), and extract every embedded URL/host.
6. **Antivirus** — Microsoft Defender signature scan of every downloaded and extracted file.

**"No malware" in this report means:** nothing in the above matched a credential-stealer, backdoor, miner, injector, or covert-exfiltration pattern; all network endpoints and privileged actions trace to the project's stated purpose and its own source; and the shipped build matches the published source.

### 1.1 Environment caveat (important)

**Real-time protection was OFF on the test PC.** The Defender *signature* scan I ran was therefore the only AV pass, and signature scanning catches known samples, not novel behaviour. My behavioural conclusions come from the decompilation/source review, not from Defender.

### 1.2 Release-digest verification

Ten projects publish per-asset SHA-256 digests on their GitHub releases. **All ten matched byte-for-byte**, i.e. the file I analysed is exactly the file GitHub serves:

| Project | Asset | Verified |
|---|---|---|
| SpecialK | `SpecialK.7z` | ✅ |
| OptiScaler | `Optiscaler_0.9.4…_MM.7z` | ✅ |
| Bulk-Crap-Uninstaller | `BCUninstaller_6.3.0_…zip` | ✅ |
| Winhance | `Winhance.Installer.exe` | ✅ |
| winutil | `winutil.ps1` | ✅ |
| Win11Debloat | `Get.ps1` | ✅ |
| winscript | `winscript-portable.exe` | ✅ |
| Sophia Script | `Sophia.Script…11.v8.0.0.zip` | ✅ |
| Bloatynosy | `BloatynosyOrigin-1.0.71.zip` | ✅ |
| Revision Tool | `RevisionTool-Setup.exe` | ✅ |

SophiApp and ThisIsWin11 ship zips without a published digest (older releases); I hashed and extracted them. Talon publishes no GitHub binary at all (see §3.10).

---

## 2. Verdict summary

| # | Project | Type | Signed? | Decompiled | Verdict |
|---|---|---|---|---|---|
| 1 | awesome-windows11/windows11 | Docs / link list | n/a | DLL in repo | ⚠️ One risky archive — **excluded** (§4.2) |
| 2 | BoringBoredom/PC-Optimization-Hub | Docs / website | n/a | — | ✅ Informational, no code |
| 3 | SpecialKO/SpecialK | Native DLL framework | ✗ | ✅ Ghidra | ✅ Legitimate |
| 4 | optiscaler/OptiScaler | Native DLL injector | partial (SignPath) | ✅ Ghidra | ✅ Legitimate |
| 5 | BCUninstaller/Bulk-Crap-Uninstaller | .NET app | mostly ✅ | ✅ ILSpy | ✅ Legitimate (opt-in telemetry) |
| 6 | valleyofdoom/PC-Tuning | Scripts + guide | ✗ (MinSudo) | ✅ | ✅ Legitimate (advanced, opt-in) |
| 7 | memstechtips/Winhance | .NET (WinUI) app | ✅ | ✅ ILSpy | ✅ Legitimate |
| 8 | ChrisTitusTech/winutil | PowerShell | ✗ (script) | n/a (source) | ✅ Legitimate |
| 9 | Raphire/Win11Debloat | PowerShell | ✗ (script) | n/a (source) | ✅ Legitimate |
| 10 | ravendevteam/talon | Python/Nuitka | — | source only | ✅ Source clean (binary not on GitHub — caveat) |
| 11 | flick9000/winscript | Tauri (Rust+web) | ✅ (SignPath) | Rust meta | ✅ Legitimate |
| 12 | Sophia-Community/SophiApp | .NET app | ✗ | ✅ ILSpy | ⚠️ Optional russian proxy — **excluded** (§4.1) |
| 13 | farag2/Sophia-Script-for-Windows | PowerShell module | ✗ (script) | ✅ (wrapper) | ✅ Legitimate |
| 14 | builtbybel/ThisIsWin11 | .NET app | ✗ | ✅ ILSpy | ✅ Legitimate |
| 15 | builtbybel/Bloatynosy | .NET app | ✗ | ✅ ILSpy | ✅ Legitimate (plaintext API-key note) |
| 16 | meetrevision/playbook | AME playbook (.apbx) | n/a | extracted | ✅ Legitimate (bundles Revision Tool) |
| 17 | meetrevision/revision-tool | Flutter+Rust app | ✗ | ✅ Ghidra | ⚠️ Cert-trust + TLS-bypass — **excluded** (§4.3) |

No credential stealers, backdoors, miners, injectors or covert exfiltration were found in any of the 17. Defender flagged three files at cloud-heuristic level during the bulk scan but **cleared all of them on individual rescan** (false positives).

---

## 3. Per-project findings

### 3.1 awesome-windows11/windows11
An "awesome list" (curated Markdown of links) plus one archive, `archive/InputSwitch.zip`. The zip ships a **modified Windows system DLL** and batch files that swap it into `System32`. This is the DLL-swap behaviour detailed in §4.2 and is **excluded** from ThE OptImiseR. The list content itself is just links. Defender: clean.

### 3.2 BoringBoredom/PC-Optimization-Hub
A content hub / website (Markdown + static site). No executables, no scripts that touch the system. URL and risk scanners returned zero hits. Informational only.

### 3.3 SpecialKO/SpecialK
`SpecialK.7z` digest matched. Ships `SpecialK32.dll` / `SpecialK64.dll` — **unsigned**, native, large (the 64-bit DLL has ~19,800 functions). It is a game-overlay / render-tweak framework that injects into games, so the shape is expected. Ghidra import review found:
- `WININET` (update checks, achievement backend), `CryptProtectData` (DPAPI, LocalMachine scope — used in `wgc_registrar.cpp` to register the Windows Game capture, not to steal secrets), `CreateRemoteThread` (in the `arknights_endfield` game plugin), `WinExec` (launching a game exe from `config.cpp`).
- Embedded hosts: `sk-data.special-k.info` (optional image-codec add-on DLLs), `backend.special-k.info` (achievement data), plus wiki/discord/patreon links. All present in source; the few URLs not found verbatim are compiler-joined string fragments (confirmed in source).

Unsigned and powerful, but every capability maps to the documented overlay feature set. No malware.

### 3.4 optiscaler/OptiScaler
`Optiscaler_0.9.4…_MM.7z` digest matched. `OptiScaler.dll` is **signed by SignPath Foundation**; helper DLLs (`fakenvapi`, `dlssg_to_fsr3`) are unsigned. It is an upscaler/frame-gen injector (DLSS↔FSR↔XeSS). Ghidra: `WINHTTP` (update check), `GetAsyncKeyState` (in-game overlay hotkeys), `ShellExecuteW`. URLs: GitHub + Nexus Mods only. `dlssg_to_fsr3` carries an extra PE section named `tdb` — normal for that project's build, not an anomaly. No malware.

### 3.5 BCUninstaller/Bulk-Crap-Uninstaller
`BCUninstaller_6.3.0_net8…zip` digest matched. Most assemblies are **signed** (.NET Foundation, voidtools). Decompiled all modules; every type matches the source repo (the only "extra" types were compiler-generated regex runners). Network behaviour:
- Crash reports (NBug) and a `SendStats` call go to `bugsklocman.ddns.net:7721`. The statistics are **opt-in** — `MiscSendStatistics` defaults to `False` and is bound to a checkbox on first run.

A legitimate, well-known bulk uninstaller. No malware.

### 3.6 valleyofdoom/PC-Tuning
No GitHub release; distributed as a source repo + guide. Ships `bin/MinSudo.exe` (unsigned native, a small open-source "sudo" helper) and `bin/apply-registry.ps1`, a structured registry-tweak table. Several tweaks are security-relevant (disable Defender, block Windows Update, driver-only update block) but each is **gated behind an opt-in option** (`apply_if`). This project is the source of the gated "advanced" set in ThE OptImiseR (see §4.4). No malware.

### 3.7 memstechtips/Winhance
`Winhance.Installer.exe` is **signed** ("Open Source Developer Marco du Plessis"), Inno Setup. Decompiled `Winhance.*.dll`; types match source. Behaviour:
- `store.rg-adguard.net` (resolves Microsoft Store package download links), `get.winhance.net` (its own installer bootstrap — a shortcut it creates runs `irm 'https://get.winhance.net' | iex`; I fetched that script — it just downloads the signed installer from the project's own GitHub release), winget, and Chocolatey for app installs.
- App installs use `PackageManager.AddPackageAsync(..., DeploymentOptions.None)` — no "allow unsigned" flag.

A legitimate WinUI debloater/optimiser. No malware.

### 3.8 ChrisTitusTech/winutil
`winutil.ps1` digest matched. Unsigned, which is expected for a script meant to be run via `irm https://christitus.com/win | iex`. I confirmed `christitus.com/win` is a redirect to the exact GitHub release asset. Its embedded JSON configs (tweaks, applications, appx, dns, feature, preset, themes) were **semantically compared to source: 396 entries, 0 differences** — the build step only stamps the version and prefixes app keys with `WPFInstall`. The most-used, widely-shared optimiser; its tweak data is a primary source for the catalogue. No malware.

### 3.9 Raphire/Win11Debloat
`Get.ps1` digest matched. It is a small bootstrap that downloads the repo zip from GitHub (release zipball or `master`) and runs `Win11Debloat.ps1`. `debloat.raphi.re` redirects to the GitHub release. Source scripts are plain registry/Appx operations. No malware.

### 3.10 ravendevteam/talon
Python, compiled with Nuitka. **Note:** Talon publishes **no binary on GitHub** — the real download is served from `raventechnologiesgroup.com` / `ravendevteam.org`, which I did not fetch or verify. I audited the **source** only. The source is a wrapper that:
- Bundles and runs **winutil** and **Win11Debloat** with preset configs (fetched from GitHub at build time per `build.bat`);
- Can download an external JSON config via `urllib` (validates it parses as JSON before use);
- Optionally installs Chocolatey packages.

`debloat.win` is their redirect domain. The current source contains **no Defender-exclusion code** (a FAQ entry referring to that is about older versions). Source is clean. **Caveat:** because the distributed binary isn't on GitHub, I can't certify the exact shipped executable — only the source that builds it.

### 3.11 flick9000/winscript
Installer and portable EXE, digests matched, **signed by SignPath Foundation**. Tauri app (Rust backend + web UI). `winscript.cc/irm` is its bootstrap. The tweak payloads live in `scripts.ts` as `reg add` / Appx one-liners. Rust dependency metadata read; no network/exec surprises. No malware.

### 3.12 Sophia-Community/SophiApp
`SophiApp.zip` (no published digest; hashed and extracted). `SophiApp.exe` is an **unsigned** .NET app. Decompiled vs `master`; all types match (the only unresolved names are COM interop `INetFw*` interfaces, which are expected). `script.sophia.team` / `sl.sophia.team` redirect to GitHub. **One optional toggle sets a system-wide proxy to a Russian anti-censorship server** — detailed in §4.1 and **excluded**. Everything else is standard tweaking. No malware.

### 3.13 farag2/Sophia-Script-for-Windows
All release zip digests matched. A large PowerShell module, bootstrapped via `iwr script.sophia.team | iex`. It contains many security-relevant functions (Defender network-protection/PUA toggles, telemetry) — all are **opt-in function calls**, not applied automatically. Committed binaries: `LGPO.exe` (**Microsoft-signed**), `SophiaScriptWrapper.exe` (unsigned, Costura-packed .NET — decompiled; a benign GitHub-release updater/launcher using Octokit + Newtonsoft), and a WinGet installer exe. No malware.

### 3.14 builtbybel/ThisIsWin11
`TIW11.zip` (no published digest; hashed). `ThisIsWin11.exe` and `Albacore.ViVe.dll` are **unsigned** .NET. Decompiled; **all 97 types match the source exactly**. Bundled scripts download **MSEdgeRedirect** from its official GitHub release and do the usual OneDrive/Edge removals. No malware.

### 3.15 builtbybel/Bloatynosy
`BloatynosyOrigin-1.0.71.zip` digest matched. `Bloatynosy.exe` is an **unsigned** .NET Framework 4.8 app ("Origin" rewrite). Decompiled; matches source. Tweaks live in `Data/WinRules.ini` (a clean `Path`/`ValueName`/`RecommendedValue`/`DefaultValue` catalogue — a primary source for ThE OptImiseR). **Minor privacy note:** its optional AI "explain this tweak" feature calls OpenAI / Anthropic / Groq / OpenRouter using a **user-supplied API key stored in plaintext** in `Data/Settings.json`, and sends the tweak description as the prompt. It's user-initiated and off unless you enter a key — not malware, but worth knowing the key is stored unencrypted.

### 3.16 meetrevision/playbook
`Revi-PB-26.04.apbx` digest matched (`.apbx` is the AME playbook format — a password-protected zip, password `malte`). Contents are YAML task definitions + `Executables/` (PowerShell/CMD). It bundles **Revision Tool** as a fallback. Heavy debloat/telemetry removal. The only release-vs-source differences were version stamps. AME-style playbooks are polarising in the community but contain no malware here. No malware.

### 3.17 meetrevision/revision-tool
`RevisionTool-Setup.exe` digest matched; Inno Setup, **unsigned**. Flutter/Dart front end + Rust (`revitool_native.dll`, cargo-auditable) + `process_checker.dll` (native; byte-for-byte reproducible from its committed C source). Two risky behaviours, both detailed in §4.3 and **excluded** from ThE OptImiseR:
- It creates the **"Microsoft Testing Root" certificate** registry key so Windows will accept its **self-signed** component CABs.
- Its download client **disables TLS certificate validation** (`badCertificateCallback => true`, commented "Important for LTSC 2021").

Its Defender/telemetry/Xbox/AI removal is done by installing those signed-by-itself Windows component packages. Not a stealer or backdoor, but the cert-trust + TLS-bypass are the reasons its package-install path is excluded.

---

## 4. The excluded behaviours (in detail)

These were found during the audit and left out of ThE OptImiseR at your instruction. None is "malware" in the stealer/backdoor sense; each is a system-weakening action with real downside.

### 4.1 Russian anti-censorship proxy — SophiApp
`CustomisationOs.cs:1005` sets
`HKCU\…\Internet Settings\AutoConfigURL = https://antizapret.prostovpn.org:8443/proxy.pac`
(constant `_359_ANTIZAPRET_PROXY_LINK`, `CustomisationConstants.cs:428`). Antizapret is a Russian service for bypassing state censorship. The PAC file is fetched from their server and decides, per site, whether your traffic goes direct or through their proxies; they can change it at any time and can see the sites you visit (and plaintext of non-HTTPS traffic). It's system-wide (Edge/Chrome/most apps follow it). Off by default; pointless and privacy-damaging outside Russia. **Excluded.** Check your own PC with:
```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -ErrorAction SilentlyContinue
```

### 4.2 System-DLL swap — awesome-windows11
`archive/InputSwitch.zip` contains `InputSwitch.dll.killbox` (a patched copy of a Windows 10 **1903** DLL, build 18362.145, from 2019), `…returnbox`, and batch files that take ownership of `C:\Windows\System32\InputSwitch.dll` from TrustedInstaller and copy the patched DLL over it. Byte diff: 33 bytes differ at offset `0x25229`; decompiling both halves shows the patch only removes the call that shows the keyboard-language popup (Win+Space / Alt+Shift). No hidden code — but putting a 2019 DLL into a Windows 11 (build 26200) System32 risks breaking input/Explorer, the "restore" file is the 2019 version (not your real one), and the DLL isn't verifiably Microsoft-signed on this build. `sfc /scannow` restores the genuine file if anyone ran it. **Excluded.**

### 4.3 "Microsoft Testing Root" certificate + TLS bypass — Revision Tool
`win_package_repository_impl.dart:140` creates
`HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\8A334AA8052DD244A647306A76B8178FA215F344`
— the thumbprint Microsoft's own docs label **"Microsoft Testing Root Certificate."** Windows' servicing engine checks for that key and, when present, accepts **test-signed** system packages. Revision's component CABs are signed with a **self-made certificate named "Microsoft Windows"** (I confirmed Windows rejects it as an untrusted root); the key is what lets them install anyway. The key is **never removed**, so afterward any admin-level program could install its own fake "Windows component" and have it treated as part of Windows. Separately, `api_client.dart:175` sets `badCertificateCallback => true`, disabling HTTPS certificate checking for its downloads (comment: "Important for LTSC 2021") — on a hostile network the downloaded package could be swapped. The key is **not present** on your PC (checked). **Excluded.**

### 4.4 Defender disable / Windows Update block — included but gated (your choice)
From PC-Tuning's `apply-registry.ps1`. In ThE OptImiseR these live in the **Expert menu**, off by default, behind a typed confirmation:
- **Disable Defender** (21 registry values) — leaves the PC with no built-in AV.
- **Block Windows Update completely** (16 values) — no security updates either. Not recommended.
- **Block driver updates only, keep system/security updates** (6 values) — the safer option you noted: Windows keeps patching, it just stops pushing drivers through Windows Update.

---

## 5. Cross-cutting notes

- **Deduplication:** across all tools I extracted 1,887 distinct `(registry key, value)` tweaks; 391 appear in ≥2 tools and 81 in ≥4 — i.e. the tools heavily overlap (the "greatest hits" are telemetry, ad/suggestion toggles, taskbar/Explorer layout, dark mode). ThE OptImiseR's catalogue keeps one copy of each, tagged with which tools it came from.
- **Signing reality:** script-based tools (winutil, Win11Debloat, Sophia Script) are unsigned by nature (run via `irm | iex`); among the compiled apps, Winhance and winscript are signed, while SpecialK, OptiScaler helpers, SophiApp, ThisIsWin11, Bloatynosy and Revision Tool are unsigned. Unsigned ≠ malicious, but it means you're trusting the GitHub digest (which I verified) rather than a code-signing certificate.
- **Defender false positives:** `RevisionTool-Setup.exe`, Revision's `process_checker.dll`, and `Bloatynosy.exe` tripped the bulk cloud-heuristic scan but were **clean on individual rescan** — typical for unsigned PInvoke-heavy debloat tools.

## 6. Limitations

- Behavioural review is **static** (decompilation + source), not dynamic — I did not run the GUI apps and watch them live, except one throwaway registry key to test ThE OptImiseR's apply/undo.
- **Talon's shipped binary was not verified** — it isn't on GitHub; only its source (which builds it) was audited.
- Defender **real-time protection was off**; the signature scan is a point-in-time check against known samples.
- Decompiled type-matching proves the shipped build has no *extra types* vs source; it does not prove bit-identical compilation.
- The excluded behaviours (§4) are **benign-but-risky**, not stealers/backdoors/miners.

---

## Addendum — project #18: Atlas-OS/Atlas (AtlasOS)

**Added at user request.** Repo `Atlas-OS/Atlas` (21.8k★, GPL), playbook **v0.5.0**, HEAD `1ed9630`. Also cloned `Atlas-OS/utilities`. Atlas is an **AME-Wizard "overhaul" playbook** — the same ecosystem as meetrevision's playbook/Revision Tool — meant to be applied whole to a fresh Windows 11 24H2/25H2 install (`SupportedBuilds` 26100/26200). `playbook.conf` declares `Overhaul=true`, `UseKernelDriver=false`, and **requires Defender to be off** before it runs (`Requirements: DefenderToggled, NoAntivirus, UCPDDisabled`).

### Verification & method
- Audited the **repo source** (authoritative — the released `.apbx`/`.zip` are built from it; the `v0.5.0-hotfix.apbx` carries a published SHA-256 on its GitHub release).
- Risk/URL scanners over all `*.yml` / `*.ps1` / `*.cmd`; signature + Defender scan of every bundled binary and the two component CABs.

### Findings — clean, no malware
- **Defender scan: no threats** across the whole `src/` tree.
- **Bundled tools** are the well-known community utilities, all unsigned but benign: `SetTimerResolution.exe` / `MeasureSleep.exe` (amitxv timer tools), `multichoice.exe`, and **ViVeTool v0.3.3** (Albacore — the same `Albacore.ViVe.dll` ThisIsWin11 ships). No injectors, keyloggers, exfil endpoints, miners; URLs are all docs/winstall/github/microsoft.
- **Scripts** use `RunAsTI.cmd` (run-as-TrustedInstaller) and `setSvc.cmd` to apply system changes — standard for this class of tool, not covert.

### Excluded (same grounds as Revision Tool) — §4.3
Atlas removes Windows Defender and telemetry at the **component level** via two **self-signed CABs** — `Z-Atlas-NoDefender-Package` and `Z-Atlas-NoTelemetry-Package` (signed `CN=Microsoft Windows`, untrusted root). `Executables/AtlasModules/Scripts/packageInstall.ps1` (line ~307) creates the **Microsoft Testing Root** key
`HKLM\…\SystemCertificates\ROOT\Certificates\8A334AA8052DD244A647306A76B8178FA215F344`
so Windows will accept them, with the explicit comment *"isn't cleared later as it's required for the alt repair source"* — i.e. the test-root trust is left in place permanently, exactly like Revision Tool. Its CAB-based Defender/telemetry removal is therefore **excluded** from ThE OptImiseR. (Atlas also ships a `Disable Automatic Driver Installation.reg`, consistent with the drivers-only-update idea.)

### What was folded into the catalogue
Atlas's tweaks are **`!registryValue`** actions in `Configuration/tweaks/{debloat,misc,networking,performance,privacy,qol,security}` (392 registry writes). Parsed and **deduplicated by key against the existing catalogue**:
- **299 new unique tweaks folded in**; **69 already present** from other tools (confirming the heavy overlap you expected).
- Its non-registry actions were **not** folded: `!cmd` script steps (18), `!registryKey` create/deletes (34), `!service`, `!scheduledTask`, and the component CABs — these are overhaul mechanics, not portable tweaks.
- **Security check on the folded set:** none disable Defender, UAC (`EnableLUA`), the firewall or SmartScreen. The only security-adjacent additions either **harden** (`RestrictAnonymous`, `RestrictAnonymousSAM`) or **defer feature updates / stop auto-reboot nagging while keeping security patches** (`DeferFeatureUpdates`, `TargetReleaseVersion`, `NoAutoRebootWithLoggedOnUsers`, Store `AutoDownload=2`). 2 entries referencing Atlas-only files (`%windir%\AtlasModules\…`) were dropped as non-portable.

Catalogue after folding: **478 deduplicated registry tweaks** (was 181). New categories: `Atlas: debloat/misc/networking/performance/privacy/qol/security`.

**Shortcut noted:** Atlas tweaks were taken from the repo source, not by decrypting the released `.apbx`; the `.apbx` is built from this repo and its release digest is published, so provenance holds, but I did not byte-diff the encrypted playbook against the repo.


---

## Addendum — eclean (closed-source competitor, reverse-engineered for comparison)

**Not one of the original 18.** eclean is a **commercial, closed-source** Windows cleaner/optimizer, included here only as a comparison point. Because there is no public repository, it was **reverse-engineered from the shipped installer** (unlike the 18 open-source tools, which were audited from their actual source). Analysis date: 2026-10-16.

### Identity & packaging
- **eclean v1.3.0** by **eclean Labs AB**. Installer: **NSIS**, **validly code-signed** (`CN=eclean Labs AB`, Microsoft ID Verified CS cert), **Defender-clean**. SHA-256 `6D5B36B3187A49571AE13BE1226719E09A9EDB83067B4EAB06CA27EAC042DF42`. Ships a EULA.
- How it was opened: unpacked the NSIS payload (7-Zip), read `backend_config.json` and the NSIS script, profiled the two Rust binaries (strings/imports, cargo-auditable check), recovered the app's complete module tree from embedded Rust source paths, and **extracted the embedded SvelteKit frontend** by parsing the PE, locating the Tauri asset slice-descriptor table, and brotli-decompressing all 402 assets.

### Architecture
- **Tauri** app: **SvelteKit** web UI (402 brotli-compressed assets embedded in the exe) rendered in **WebView2**, with a **Rust** backend (`eclean.exe`, 33 MB).
- **Elevated broker service** (`eclean-privileged-service.exe`, 5 MB) that performs all admin-level changes.
- **IPC:** named pipe `\\.\pipe\eclean-privileged-service-v1`. The service **validates the caller with `WinVerifyTrust` + `ImpersonateNamedPipeClient`** and requires the caller to be the signed GUI from the same install root (`trusted_signed_gui_same_install_root`; rejects `caller_binary_outside_install_root`). Elevated ops are versioned (`optimizer_apply_v1` / `optimizer_revert_v1`) and journalled for undo.
- Local **SQLite** DB; per-feature **operation journals** → almost everything is undoable.

### Feature set (recovered)
- **Dashboard:** live CPU / AMD+NVIDIA GPU / memory / storage / network metrics; Quick Clean; **Performance Mode** (power plan, timer resolution, process priority, pause background services).
- **Cleaner:** category scanners + file/registry cleanup; **CCleaner-style winapp2 rules** plus a **3,558-entry registry MRU/trace database** for third-party apps; **secure file shredder**; large-files finder; scheduled clean; undo.
- **Booster:** Secure DNS (benchmarks DoH providers), scheduled-task disabling, service startup tuning, startup-app management, with revert.
- **Optimizations:** **Atlas Mode** (AtlasOS-style, manifest+integrity+validation) and an ~80-toggle tweak menu (telemetry/privacy, performance incl. **Spectre/Meltdown + CPU mitigations off**, **Defender off**, Core Isolation off, network, Explorer/UI, update control); stage→apply→revert + config import/export (`.ecleanopt`).
- **Uninstaller:** Win32 + UWP apps, **leftover removal with confidence scoring**, Chromium/Firefox **extension manager**.
- **System:** full hardware/OS inventory.
- **Account/monetisation:** OAuth login (+ **2FA**), **device registration with a device limit**, entitlements, **Pro subscription** (`/checkout`), **referrals**.
- **Plumbing:** **minisign (ed25519)-signed auto-update** (`update.eclean.gg`, with an emergency channel), remote feature flags, server-polled notifications, Discord Rich Presence, log redaction, i18n (6+ languages).

### Network & telemetry
`api.eclean.gg` (account/plans), `update.eclean.gg` (signed updates), **PostHog** analytics via `p.eclean.gg`, **Sentry** crash reports (DSN embedded), Discord IPC. No covert/unexpected destinations. Verdict: **legitimate, signed, clean commercial software** — the "know this" items are telemetry, the account requirement, and an always-on elevated service.

### How eclean compares

| Dimension | eclean | ThE OptImiseR (this project) | The 18 open-source tools |
|---|---|---|---|
| Source | Closed (binary only) | Open | Open |
| Cost / account | Paid "Pro" + account + device limit | Free, no account | Free |
| Telemetry | PostHog + Sentry | None | Mostly none (BCU opt-in stats; Bloatynosy AI opt-in) |
| Elevated work | Always-on broker service, `WinVerifyTrust`-gated named pipe | Runs elevated on demand; Expert tweaks behind a typed confirm | Varies (Revision & Atlas use a self-signed CAB + test-root-cert trick — excluded here) |
| Updates | Auto-update, **minisign-signed & verified** | **minisign (Ed25519)-verified** update check (pure-PowerShell verifier, offline) | Varies; some `irm \| iex` bootstraps |
| Tweak count | ~80 curated | **478 deduplicated** (merged from these tools) | Each smaller individually |
| Disk/privacy cleaner | Full (winapp2 + 3,558 MRU DB + shredder + large files) | **Yes** — winapp2-style junk rules + MRU-trace clears (browser/Windows caches, Run/Recent/Open-Save/MuiCache); registry clears backed up & undoable | None — these are tweakers/debloaters, not cleaners |
| Uninstaller | Full (Win32 + UWP + leftovers + extensions) | **Win32 + UWP**: runs the uninstaller, then a leftover scan with **High/Med/Low confidence** (Revo-informed) across Revo's registry/filesystem roots; removals backed up & undoable | BCUninstaller is a full uninstaller; others do Appx only |
| Undo | Per-operation journals | **Per-operation journals** (transactional, atomic rollback) + restore point | Varies |
| Live system monitoring | Yes (CPU/GPU/mem/net) | No | No |
| UI | Tauri / SvelteKit, polished | WPF, winutil-style | WPF / WinForms / PowerShell / TUI |

### What's worth borrowing for ThE OptImiseR
1. **The `WinVerifyTrust`-gated named-pipe broker** — this is the clean way to make the Defender/Update "Expert" tweaks genuinely safe to elevate: a small signed service that only accepts commands from the verified signed GUI, instead of relying on the whole app running as admin.
2. **minisign-signed updates** — cheap to add, removes the "unsigned, SmartScreen-warned" trust problem for updates.
3. **Per-operation journals** for transactional apply/revert (eclean's model is more robust than a flat undo log).
4. **A cleaner module** (winapp2 rules + an MRU-trace list) and an **uninstaller with leftover-confidence scoring** — the two whole categories ThE OptImiseR doesn't yet cover.

**Status — now implemented (2026-10-16):** items 2, 3 and 4 are built into ThE OptImiseR. Updates are verified with a pure-PowerShell minisign/Ed25519 verifier (RFC 8032 test-vector checked). Undo is now per-operation journals with atomic rollback. A cleaner module and a Win32+UWP uninstaller were added; the uninstaller's leftover scan and confidence tiers (High/Med/Low ≈ Revo's Safe/Moderate/Advanced) and its registry/filesystem scan roots were taken from a reverse-engineering pass over **Revo Uninstaller Pro 5.5.2.0** (string/feature extraction from `RevoUnPro.exe` / `RevoCmd.exe`). Item 1 (the `WinVerifyTrust`-gated broker service) remains future work — the Expert tweaks still elevate the whole app behind a typed confirm.

**Caveat:** eclean's analysis is from the binary, not source — the feature map and the ~80 tweak labels are recovered from the extracted frontend and Rust module paths and are accurate to what's shipped, but exact per-tweak registry values would need decompiling its tweak scripts (not done here).
