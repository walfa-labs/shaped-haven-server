//! Shaped Haven server — the `--debug-loadout` test affordance.
//!
//! **This module is not part of the game.** It exists so a live client run can
//! be started already holding a loadout that normal play cannot reach in the
//! time a scripted run survives: an evolution needs a level-8 weapon *and* its
//! named passive at its max, which is roughly thirteen level-up picks, and a
//! scripted run reaches level 6–7 before dying. The phase-5 completion
//! criterion — *"evolutions appear"* in a live client run — is therefore
//! unobservable without it. The server only turns it on from
//! `--debug-loadout`, exactly like `--stress-enemies`.
//!
//! The spec is a comma-separated list of `name=level` pairs, e.g.
//! `--debug-loadout "sword=8,clockwork_gear=5"`. A name is a DESIGN.md §3 item
//! name (lower-cased, spaces as underscores), the passive's `P0`–`P9` alias
//! from PROTOCOL.md, or a decimal item id from PROTOCOL.md "Item ids" — so
//! `"0=8,18=5"` is the same loadout as `"sword=8,clockwork_gear=5"`. An empty
//! spec starts the run with the normal loadout.
//!
//! Applying a loadout runs the same rule the level-up draft uses for
//! evolutions (DESIGN.md §3): a weapon at level 8 whose named passive is at its
//! max fuses into that evolution. `sword=8,clockwork_gear=5` therefore arms
//! Vorpal Blender with no separate syntax for naming an evolution.
//!
//! This module imports only `root.zig` and `upgrade.zig`: it consumes a
//! loadout as plain slices, so `sim.zig` can call it without a circular import.

const std = @import("std");
const root = @import("root.zig");
const upgrade = @import("upgrade.zig");

/// One resolved `--debug-loadout` spec.
pub const Loadout = struct {
    /// Level to start each weapon at, indexed by weapon id (0..3).
    /// 0 leaves the run's default alone.
    weapons: [root.max_weapons]u8 = @splat(0),
    /// Level to start each passive at, indexed 0..9 in DESIGN.md §3 order.
    /// 0 leaves the run's default alone.
    passives: [root.max_passives]u8 = @splat(0),

    pub fn isEmpty(l: Loadout) bool {
        for (l.weapons) |v| {
            if (v != 0) return false;
        }
        for (l.passives) |v| {
            if (v != 0) return false;
        }
        return true;
    }

    /// Apply to a player's loadout arrays.
    ///
    /// `sim.resetPlayer` has already filled the four level-1 weapons of
    /// DESIGN.md §3, so a weapon named here is levelled in place when the
    /// player already holds it and placed into a free slot otherwise — the same
    /// rule `sim.applyOption` uses for a newly chosen weapon. Passive levels
    /// are clamped to their max, and weapon levels to level 8.
    pub fn apply(l: Loadout, weapons: []upgrade.WeaponSlot, passives: []u8) void {
        for (0..root.max_weapons) |i| {
            const level = l.weapons[i];
            if (level == 0) continue;
            const id: u8 = @intCast(i);
            const clamped = @min(level, root.max_weapon_level);

            var slot: ?usize = upgrade.weaponSlot(weapons, id);
            if (slot == null) {
                for (weapons, 0..) |*s, k| {
                    if (!s.isFree()) continue;
                    slot = k;
                    break;
                }
            }
            const s = slot orelse continue;
            weapons[s].id = id;
            weapons[s].level = clamped;
            weapons[s].cooldown_ticks = 0;
            weapons[s].evolved = false;
            weapons[s].pending_slashes = 0;
            weapons[s].pending_timer = 0;
            weapons[s].shots_fired = 0;
        }

        for (0..root.max_passives) |i| {
            const level = l.passives[i];
            if (level == 0) continue;
            passives[i] = @min(level, upgrade.passiveMaxLevel(@intCast(i)));
        }

        // Evolutions: the draft's own rule, applied once at run start. A slot
        // already holding an evolution is left alone, so the first evolution a
        // weapon qualifies for, in DESIGN.md §3 order, is the one it fuses
        // into — a loadout that maxes both of a weapon's partners is asking for
        // the same slot twice, and the draft would offer the second later.
        for (upgrade.evolutions) |evo| {
            if (upgrade.holdsEvolution(weapons, evo.id)) continue;
            if (!upgrade.holdsWeaponAtLevel(weapons, evo.weapon_id, root.max_weapon_level)) continue;
            const max = upgrade.passiveMaxLevelById(evo.passive_id) orelse continue;
            if (!upgrade.holdsPassiveAtLevel(passives, evo.passive_id, max)) continue;
            const i = upgrade.weaponSlot(weapons, evo.weapon_id) orelse continue;
            if (upgrade.isEvolutionId(weapons[i].id)) continue;

            upgrade.fuseInto(&weapons[i], evo);
        }
    }
};

/// Weapon names in DESIGN.md §3 order; `weapon_names[i]` is weapon id `i`.
const weapon_names = [_][]const u8{ "sword", "axe", "bow", "gun" };

/// Passive names, indexed 0..9 in DESIGN.md §3 order. These mirror the
/// `name` field of `upgrade.passive_table`; the test below pins the two
/// together so a renamed passive cannot silently break a spec.
const passive_names = [_][]const u8{
    "spinach_core",
    "amplifier_lens",
    "clockwork_gear",
    "accelerator_coil",
    "stasis_capacitor",
    "prism_splitter",
    "magnet_array",
    "thruster_boots",
    "titanium_plating",
    "nano_repair",
};

/// Parse a `--debug-loadout` spec.
///
/// Returns `error.InvalidLoadout` for anything that is not comma-separated
/// `name=level` pairs, for an unknown name or id, for a level that is not a
/// decimal number, or for a level of 0. An empty spec parses to an empty
/// loadout, which changes nothing.
pub fn parse(spec: []const u8) error{InvalidLoadout}!Loadout {
    if (spec.len == 0) return Loadout{};
    var out = Loadout{};

    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |entry| {
        var pair = std.mem.splitScalar(u8, entry, '=');
        const name = std.mem.trim(u8, pair.next() orelse return error.InvalidLoadout, " \t");
        const level_text = std.mem.trim(u8, pair.next() orelse return error.InvalidLoadout, " \t");
        if (pair.next() != null) return error.InvalidLoadout;
        if (name.len == 0 or level_text.len == 0) return error.InvalidLoadout;

        const level = std.fmt.parseInt(u8, level_text, 10) catch return error.InvalidLoadout;
        if (level == 0) return error.InvalidLoadout;

        const id = resolveId(name) orelse return error.InvalidLoadout;
        if (id < root.max_weapons) {
            out.weapons[id] = level;
        } else if (upgrade.passiveIndex(id)) |i| {
            out.passives[i] = level;
        } else {
            return error.InvalidLoadout;
        }
    }
    return out;
}

/// The item id a spec name stands for, or `null`.
///
/// The name is normalised before matching — lower-cased, spaces as underscores —
/// so `SWORD`, `Sword` and `sword` all resolve, matching what the documented
/// syntax promises rather than requiring the caller to have got the case right.
fn resolveId(raw_name: []const u8) ?u8 {
    var buf: [64]u8 = undefined;
    const name = snakeInto(raw_name, &buf);

    for (weapon_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    for (passive_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return upgrade.passive_table[i].id;
    }
    // The `P0`–`P9` aliases PROTOCOL.md gives the passives.
    if (name.len == 2 and name[0] == 'p' and name[1] >= '0' and name[1] <= '9') {
        const i: usize = name[1] - '0';
        if (i < passive_names.len) return upgrade.passive_table[i].id;
    }
    // Or the id itself, so a spec can be written straight from PROTOCOL.md.
    return std.fmt.parseInt(u8, name, 10) catch null;
}

/// `src` lower-cased with spaces as underscores, for the test that pins
/// `passive_names` to DESIGN.md's passive names.
fn snakeInto(src: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (src) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c == ' ') '_' else std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

test "the spec names match the DESIGN.md passive table" {
    try std.testing.expectEqual(root.max_passives, passive_names.len);
    try std.testing.expectEqual(root.max_weapons, weapon_names.len);
    var buf: [48]u8 = undefined;
    for (upgrade.passive_table, 0..) |p, i| {
        try std.testing.expectEqualStrings(snakeInto(p.name, &buf), passive_names[i]);
    }
}

test "a spec parses into weapon and passive levels" {
    const l = try parse("sword=8,clockwork_gear=5");
    try std.testing.expectEqual(@as(u8, 8), l.weapons[0]);
    try std.testing.expectEqual(@as(u8, 5), l.passives[2]);
    try std.testing.expectEqual(@as(u8, 0), l.weapons[1]);
    try std.testing.expectEqual(@as(u8, 0), l.passives[0]);
    try std.testing.expect(!l.isEmpty());
}

test "a spec accepts item ids and the passive aliases" {
    const by_name = try parse("sword=8,clockwork_gear=5");
    const by_id = try parse("0=8,18=5");
    const by_alias = try parse("sword=8,P2=5");
    try std.testing.expectEqual(by_name.weapons[0], by_id.weapons[0]);
    try std.testing.expectEqual(by_name.passives[2], by_id.passives[2]);
    try std.testing.expectEqual(by_name.weapons[0], by_alias.weapons[0]);
    try std.testing.expectEqual(by_name.passives[2], by_alias.passives[2]);
}

test "a spec name is normalised, so its case does not matter" {
    // The documented syntax says a name is the item's name lower-cased with
    // spaces as underscores, which reads as a promise that the flag does the
    // normalising. `SWORD` and `Sword` used to be rejected while `sword` worked.
    const canonical = try parse("sword=8,clockwork_gear=5");
    const shouted = try parse("SWORD=8,CLOCKWORK_GEAR=5");
    const titled = try parse("Sword=8,Clockwork_Gear=5");
    const spaced = try parse("Sword=8,Clockwork Gear=5");

    try std.testing.expectEqual(canonical.weapons[0], shouted.weapons[0]);
    try std.testing.expectEqual(canonical.passives[2], shouted.passives[2]);
    try std.testing.expectEqual(canonical.weapons[0], titled.weapons[0]);
    try std.testing.expectEqual(canonical.passives[2], spaced.passives[2]);
}

test "an empty spec changes nothing" {
    const l = try parse("");
    try std.testing.expect(l.isEmpty());
}

test "a malformed spec is rejected" {
    const bad = [_][]const u8{
        "sword",
        "sword=",
        "=8",
        "nonsense=3",
        "sword=8,,axe=1",
        "sword=8,",
        "sword=0",
        "sword=eight",
        "sword=8=9",
        "32=8",
    };
    for (bad) |spec| {
        try std.testing.expectError(error.InvalidLoadout, parse(spec));
    }
}

test "applying a loadout arms it and fuses the evolution" {
    var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
    for (&weapons, 0..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 1;
    }
    var passives: [root.max_passives]u8 = @splat(0);

    const l = try parse("sword=8,clockwork_gear=5");
    l.apply(&weapons, &passives);

    try std.testing.expectEqual(upgrade.ids.vorpal_blender, weapons[0].id);
    try std.testing.expect(weapons[0].evolved);
    try std.testing.expectEqual(@as(u8, 8), weapons[0].level);
    try std.testing.expectEqual(@as(u8, 5), passives[2]);
    // The other three weapons keep the run's level-1 defaults.
    try std.testing.expectEqual(@as(u8, 1), weapons[1].level);
    try std.testing.expectEqual(upgrade.ids.axe, weapons[1].id);
}

test "a maxed weapon without its partner passive does not evolve" {
    var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
    for (&weapons, 0..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 1;
    }
    var passives: [root.max_passives]u8 = @splat(0);

    const l = try parse("sword=8");
    l.apply(&weapons, &passives);

    try std.testing.expectEqual(upgrade.ids.sword, weapons[0].id);
    try std.testing.expect(!weapons[0].evolved);
    try std.testing.expectEqual(@as(u8, 8), weapons[0].level);
}

test "applying clamps a passive to its max and a weapon to level 8" {
    var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
    for (&weapons, 0..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 1;
    }
    var passives: [root.max_passives]u8 = @splat(0);

    const l = try parse("nano_repair=99,sword=99");
    l.apply(&weapons, &passives);

    try std.testing.expectEqual(@as(u8, 5), passives[9]);
    try std.testing.expectEqual(root.max_weapon_level, weapons[0].level);
}

test "a weapon the player does not hold goes into a free slot" {
    var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);

    const l = try parse("bow=3");
    l.apply(&weapons, &passives);

    try std.testing.expectEqual(upgrade.ids.bow, weapons[0].id);
    try std.testing.expectEqual(@as(u8, 3), weapons[0].level);
    try std.testing.expect(!weapons[0].evolved);
}

test "a weapon slot fuses into the first evolution it qualifies for" {
    var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
    for (&weapons, 0..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 1;
    }
    var passives: [root.max_passives]u8 = @splat(0);

    // Both of the sword's partners maxed: Clockwork Gear (Vorpal Blender) comes
    // first in DESIGN.md §3 order, so it is the one that fuses.
    const l = try parse("sword=8,clockwork_gear=5,thruster_boots=5");
    l.apply(&weapons, &passives);

    try std.testing.expectEqual(upgrade.ids.vorpal_blender, weapons[0].id);
    try std.testing.expect(weapons[0].evolved);
}

test "every evolution can be armed by its weapon and partner passive" {
    for (upgrade.evolutions) |evo| {
        // A fresh loadout each time: two of the eight grow from the same weapon,
        // and one slot can only hold one of them.
        var weapons = root.filledWithDefault(upgrade.WeaponSlot, root.max_weapons);
        for (&weapons, 0..) |*slot, i| {
            slot.id = @intCast(i);
            slot.level = 1;
        }
        var passives: [root.max_passives]u8 = @splat(0);

        const weapon_name = weapon_names[evo.weapon_id];
        const passive_name = passive_names[upgrade.passiveIndex(evo.passive_id).?];
        var spec_buf: [64]u8 = undefined;
        const spec = try std.fmt.bufPrint(&spec_buf, "{s}=8,{s}={d}", .{
            weapon_name,
            passive_name,
            upgrade.passiveMaxLevelById(evo.passive_id).?,
        });
        const l = try parse(spec);
        l.apply(&weapons, &passives);

        const i = upgrade.weaponSlot(&weapons, evo.weapon_id).?;
        try std.testing.expectEqual(evo.id, weapons[i].id);
        try std.testing.expect(weapons[i].evolved);
        try std.testing.expectEqual(root.max_weapon_level, weapons[i].level);
    }
}
