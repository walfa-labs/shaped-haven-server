# shaped-haven-server

Headless, server-authoritative simulation core for **Shaped Haven**, a minimal
bullet-heaven (survivors-like) game.

The server owns *all* game state. It has no rendering code and no Ogre
dependency: it is a plain process that runs a fixed-timestep simulation and
speaks a compact snapshot protocol over TCP. Single player today is the same
code path as multiplayer later — the client just connects to `127.0.0.1`.

Companion repository: `shaped-haven-client` (C++17 / Ogre3D view + input layer).

## Architecture

- **Fixed timestep:** 60 Hz simulation tick (16.667 ms), deterministic order of
  system updates.
- **Transport:** TCP with `TCP_NODELAY`, little-endian packed structs, 7-byte
  packet header (`msg_type: u8`, `payload_len: u16`, `seq: u32`).
- **Snapshots:** 20 Hz, full snapshots first, then deltas against the last
  snapshot the client acknowledged.
- **State layout:** structure-of-arrays flat pools with hard caps
  (4 players, 4096 enemies, 2048 projectiles, 4096 XP gems).

The full design — entity fields, weapon/upgrade tables, escalation curves,
message list, phase plan — is in [DESIGN.md](DESIGN.md).

## Requirements

- **Zig 0.18.0-dev.146** — the build installed on this machine at
  `D:\src\zig\zig.exe`. The code is written and verified against exactly this
  toolchain: its standard library differs substantially from earlier releases
  (`std.process.Init`, `std.Io`, the current `ArrayList` API), so read
  `D:\src\zig\lib\std` rather than older examples when extending it.
  Zig 0.17.0 is the current stable release, but fetching it from ziglang.org
  was not possible at a usable speed here; switching is a follow-up task once
  the download is practical.

## Build and test

```sh
zig build          # build the server
zig build test     # run the headless simulation tests
zig build run      # run the server (listens on 127.0.0.1:7777)
```

## Status

Phase 0 — repository skeleton and design document. See `DESIGN.md` §6 for the
phase plan.
