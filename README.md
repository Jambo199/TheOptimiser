# ThE OptImiseR

A single-file Windows optimiser, debloater, cleaner and uninstaller. A PowerShell
intro (scary ASCII banner + questions + a short summoning animation) hands off to a
compact, winutil-style WPF GUI.

Its tweak catalogue (478 deduplicated registry tweaks) was assembled by reverse-engineering
and merging a set of open-source tools — winutil, Win11Debloat, Bloatynosy, PC-Tuning,
Sophia Script, Winhance and others — and deduplicating their overlapping features.

## Features

- **Tweaks** — 478 deduplicated registry tweaks, grouped by category, with plain-language hover tips.
- **Debloat** — remove built-in Store/Appx apps (safe ones shown first); installed apps highlighted.
- **Uninstall programs** — enumerate Win32 + UWP programs, run the uninstaller, then a **leftover
  scan with High/Med/Low confidence tiers** (informed by a reverse-engineering pass over Revo
  Uninstaller Pro) across the registry/filesystem roots Revo scans. Removals are backed up and undoable.
- **Install apps** — curated winget installs.
- **Clean** — winapp2-style junk rules + a Revo/CCleaner-style MRU-trace list (browser/Windows caches,
  Run/Recent/Open-Save history, MuiCache). Registry clears are backed up and undoable.
- **Services** — change service startup types.
- **Updates (signed)** — a pure-PowerShell **minisign / Ed25519** verifier (RFC 8032) so update
  manifests are verified offline before anything is trusted. The installer is never auto-run.
- **Expert / advanced** — security-weakening options (disable Defender; block all updates; block *driver*
  updates while keeping security patches). Off by default, gated behind a typed confirmation.
- **Undo** — every change is recorded in a **per-operation journal** (transactional: an operation that
  fails part-way rolls back atomically), revertible as a unit. A System Restore point can be made first.

## Deliberately excluded

Three things found in the source tools were left out on purpose:

- a system-wide proxy pointing at a Russian anti-censorship server (SophiApp),
- swapping a Windows system DLL with an old 2019 copy (awesome-windows11),
- trusting a "Microsoft Testing Root" certificate (Revision Tool).

## Running it

- **Easiest:** double-click `TheOptimiser.exe`. Many tweaks need admin; it offers to relaunch elevated.
- **From source:** `powershell -ExecutionPolicy Bypass -File .\TheOptimiser.ps1`
- **Text menu instead of the GUI:** add `-NoGui`
- **Self-check (no changes made):** `.\TheOptimiser.ps1 -SelfTest`

Nothing is changed on your PC until you select items and confirm.

## Credits & licence

The tweak catalogue was assembled from open-source projects including winutil (ChrisTitusTech),
Win11Debloat (Raphire), Bloatynosy (builtbybel), PC-Tuning (valleyofdoom), Sophia Script (farag2) and
Winhance (memstechtips). Each remains the property of its authors under its own licence; all credit to them.

Provided "as is", without warranty. You use it at your own risk. Not affiliated with Microsoft.
See `AUDIT.md` for the full reverse-engineering / safety audit of the source tools and a comparison
against a closed-source competitor (eclean).
