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

Source layout:

| File | Contents |
| --- | --- |
| `root.zig` | Tick rate, entity caps and the other DESIGN.md constants. |
| `wire.zig` | Protocol v1: framing, payload layouts, quantization, and the byte values for the enums PROTOCOL.md leaves open. |
| `sim.zig` | The tick loop, the player pool and the player integrator. |
| `enemy.zig` | Enemy pool, Tier 1 archetypes, the spawn formula and the darter's AI. |
| `weapon.zig` | The weapon table (DESIGN.md §3). |
| `combat.zig` | Projectile pool, arc/circle hit detection, damage and knockback. |
| `spatial.zig` | Uniform spatial hash grid used as the combat broadphase. |
| `rng.zig` | Deterministic SplitMix64, so a run is reproducible from its seed. |
| `server.zig` | TCP listener, per-connection threads, the 60 Hz wall-clock loop. |
| `bench.zig` | The phase-2 load measurement. |

The full design — entity fields, weapon/upgrade tables, escalation curves,
message list, phase plan — is in [DESIGN.md](DESIGN.md).

### Tick order

Determinism depends on this order, so it is part of the contract:

1. players integrate their input;
2. enemies run their AI, integrate, and are clamped to the arena;
3. the broadphase grid is rebuilt from the enemies' new positions;
4. every ready weapon acquires the nearest enemy and fires;
5. projectiles travel and resolve what they overlap;
6. enemies touching a player deal contact damage;
7. dead enemies and spent projectiles are compacted out of their pools;
8. once a second, the spawn formula is evaluated.

Nothing moves between step 3 and step 7 except knockback *velocity*, so every
grid query in a tick sees a consistent set of indices and the pools are
compacted once, at the end.

### Protocol values this repository had to choose

`PROTOCOL.md` fixes the byte layout of `EnemyNet` and `ProjNet` but not the
meaning of their enum bytes. This repository chooses:

| Field | Values |
| --- | --- |
| `EnemyNet.archetype` | 0 Circle T1, 1 Circle T2, 2 Circle T3, 3 Triangle T1, 4 Triangle T2, 5 Triangle T3, 6 Boss — the order DESIGN.md §2 lists them in. Phase 2 emits only 0 and 3. |
| `ProjNet.shape` | 0 ARC, 1 CIRCLE, 2 RAY — the order DESIGN.md §2 lists them in. |
| `ProjNet.weapon_id` | 0 Sword, 1 Axe, 2 Bow, 3 Gun — the order DESIGN.md §3 lists them in. |

`shape = ARC` is the melee sweep: the sword and axe apply their damage
instantaneously through a sector test and then emit a short-lived, non-colliding
ARC record so the client can draw the swing. CIRCLE and RAY are travelling
projectiles that damage what they overlap as they move.

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
zig build                          # build the server (Debug)
zig build -Doptimize=ReleaseFast   # the build to run when measuring
zig build test                     # run the headless simulation tests
zig build test -Doptimize=ReleaseFast   # the same tests, at shipping speed
zig build run                      # run the server (listens on 127.0.0.1:7777)
```

### Server flags

| Flag | Meaning |
| --- | --- |
| `--port <n>` | TCP port to listen on (default 7777). |
| `--stress-enemies <n>` | Hold `n` enemies live around the players. |
| `--stress-projectiles <n>` | Hold `n` gun projectiles live as well. |

The stress flags are a **measurement tool**, not part of the game. The natural
spawn curve of DESIGN.md §4 does not reach 1,000 live enemies until roughly
twelve minutes into a run, which is far too long to sit through while measuring
a frame rate; `--stress-enemies 1000 --stress-projectiles 500` puts the phase-2
load on the wire immediately so the client's side of the definition of done can
be measured against a real server. The load is placed around the players'
centroid, so it only starts once somebody has joined.

## Status

Phase 2 — combat core. The server simulates the four level 1 weapons of
DESIGN.md §3, the two Tier 1 enemies and spawn curve of §4, and arc/circle hit
detection with pierce and knockback over a uniform spatial hash grid. The
snapshot's existing enemy and projectile arrays are filled; the wire format
itself is unchanged from phase 1.

Verified: `zig build test` — 107 tests pass. `zig build test
-Doptimize=ReleaseFast` — 107 pass, and the phase-2 load measurement reports
**0.031 ms/tick mean (0.44 ms worst) over 240 ticks with 1,000 enemies and 500
projectiles live**, against the 4.0 ms budget DESIGN.md §6 sets. Against a real
client over loopback the same load is served at a steady 20 snapshots/second
with no drops.

Deliberately not in this phase (DESIGN.md §6 puts them later): XP gems and
pickups, upgrades, level-ups, evolutions, boss and elite enemies, floating
damage numbers, and player death. Enemy contact damage floors a player's HP at
1 so a run cannot end yet.

