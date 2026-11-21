# Changelog

All notable changes are listed here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/). Everything so far is verified only in the CraftOS-PC emulator, not in real Minecraft.

## [Unreleased]

### Added
- Contact, donation and security-reporting information: `docs/SUPPORT.md`, `SECURITY.md`, issue templates, a funding file, and the same details in the in-game manual (`thelp about`).
- Fuzz tests for the wire formats and protocol servers, a lab test that applies the installer use cases to a simulated network, and regression tests for the fixes below.

### Fixed
- MQTT: a will message now needs the right to publish, and a stored session can only be resumed by its own user.
- Mail: delivery to a list is per member (one full mailbox no longer blocks or repeats the others); mailbox and folder names are validated; MIME nesting and part counts are limited; line breaks can no longer inject headers; allow/deny lists are applied before SPF/DKIM/DMARC; DKIM checks at most two signatures per message; the failed-login table is bounded.
- Wi-Fi beacon decoding of short frames and the Modbus exception code for large function codes.

## [0.1.0] - not yet released

First public version: the core (boot, kernel, filesystem layer, recovery), the package manager with signed registries and offline bundles, the
installer and setup wizard with hardware detection and use cases, 93 optional packages (turtle jobs, redstone and device control, GUI, mobile and
TV interfaces, crypto, ssh, pgp, ntp, torrents, an in-game internet with switches, routers, firewalls, DNS, DHCP, Wi-Fi, BGP, web, TLS, mail with
anti-spam and anti-virus, MQTT, Modbus and a smart-home hub), and a manual. See [docs/ROADMAP.md](docs/ROADMAP.md) for what is built and what is planned.
