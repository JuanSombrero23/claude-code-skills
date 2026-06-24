# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- README: two worked walkthroughs — crash recovery (survey + launch) and live cross-session monitoring (develop in one session, test in a second, monitor/audit from the first).

## [0.1.0] - 2026-06-24

First public release.

### Added
- Repository scaffold: marketplace manifest, MIT license, `.gitignore` safety-net, README, and contributing guide.
- `session-curator` skill: cross-project Claude Code session browser, search, cleanup, rename, resume/continue, move, and live monitor — sanitized for public release and ported to PowerShell 7+ so the seven core modes run on Windows, macOS, and Linux (the `launch`/`monitor` modes are Windows-first with graceful degradation elsewhere).
