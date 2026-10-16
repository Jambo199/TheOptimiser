# Changelog

All notable changes to ThE OptImiseR. This file mirrors the in-app **Changelog** view.

## [2.1.0] - 2026-10-16
- **New:** in-app update banner — a floating, rounded prompt at the top of the window when a newer, minisign-verified version is available.
- **New:** Changelog view inside the program.

## [2.0.0] - 2026-10-16
- **New:** Clean — winapp2-style junk rules plus Revo/CCleaner-style recent-item (MRU) trace clears; registry clears are backed up and undoable.
- **New:** Uninstall programs — Win32 + UWP, runs the uninstaller then a leftover scan with High/Med/Low confidence (informed by reverse-engineering Revo Uninstaller Pro). Removals are backed up and undoable.
- **New:** per-operation transactional journals for undo — an operation that fails part-way rolls back atomically; replaces the flat undo log.
- **New:** signed updates — a pure-PowerShell minisign / Ed25519 verifier (RFC 8032), checked against the standard test vectors.

## [1.0.0] - 2026-10-15
- 478 deduplicated registry tweaks, assembled from 18 reverse-engineered open-source tools.
- Debloat (Store apps), Install (winget), Services, Expert menu, restore points and undo.
- Compact winutil-style WPF GUI with a scary ASCII PowerShell intro.
