//! Shaped Haven server — the ten playable races (protocol v2).
//!
//! `C2S_HELLO.race_id` picks one of these rows and `C2S_HELLO.starting_weapon_id`
//! picks the one weapon the run starts with; everything else about the player
//! — health, mana, dash behaviour, the damage and XP multipliers — is the race's
//! row in `RACE_SPECS`, scaled on top of the loadout's own multipliers rather
//! than instead of them.
//!
//! The dash cooldown is counted in simulation ticks here and reported in
//! milliseconds on the wire (`PlayerNet.dash_cd_remaining` / `dash_cd_total`).

const std = @import("std");

/// The race ids `C2S_HELLO.race_id` carries, in the order the spec lists them.
pub const RaceId = enum(u8) {
    terran_kin = 0,
    mantid_vex = 1,
    cephalon_tide = 2,
    aerie_seraph = 3,
    saurian_scute = 4,
    abyssal_pelag = 5,
    weave_widow = 6,
    felis_nyx = 7,
    canid_vanguard = 8,
    cervid_sylvan = 9,
};

/// One race's base stats. A fresh player at level 1 holds exactly these, before
/// any passive, weapon level or Overclock touches them.
pub const RaceSpec = struct {
    max_hp: u16,
    max_shield: u16,
    max_mana: u16,
    move_speed_mult: f32,
    damage_mult: f32,
    /// Between dashes, in simulation ticks (60 Hz).
    dash_cooldown_ticks: u16,
    dash_mana_cost: u16,
    dash_distance: f32,
    /// Invulnerability ticks granted by a dash.
    dash_iframe_ticks: u8,
    /// Flat damage reduction, applied before the 1-damage minimum.
    base_armor: i16,
    xp_gain_mult: f32,
    pickup_radius_mult: f32,
};

/// The ten races, indexed by `RaceId`.
pub const RACE_SPECS = [_]RaceSpec{
    //                  hp   sh  mana  spd   dmg   cd   cost dist  if  arm  xp    pick
    .{ .max_hp = 110, .max_shield = 25, .max_mana = 100, .move_speed_mult = 1.00, .damage_mult = 1.00, .dash_cooldown_ticks = 210, .dash_mana_cost = 25, .dash_distance = 180, .dash_iframe_ticks = 12, .base_armor = 0, .xp_gain_mult = 1.12, .pickup_radius_mult = 1.00 }, // 0 Terran Kin
    .{ .max_hp = 85, .max_shield = 15, .max_mana = 110, .move_speed_mult = 1.15, .damage_mult = 1.18, .dash_cooldown_ticks = 168, .dash_mana_cost = 20, .dash_distance = 210, .dash_iframe_ticks = 14, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 }, // 1 Mantid Vex
    .{ .max_hp = 95, .max_shield = 50, .max_mana = 140, .move_speed_mult = 0.95, .damage_mult = 1.05, .dash_cooldown_ticks = 240, .dash_mana_cost = 25, .dash_distance = 170, .dash_iframe_ticks = 12, .base_armor = 2, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.05 }, // 2 Cephalon Tide
    .{ .max_hp = 75, .max_shield = 20, .max_mana = 120, .move_speed_mult = 1.22, .damage_mult = 1.08, .dash_cooldown_ticks = 144, .dash_mana_cost = 22, .dash_distance = 240, .dash_iframe_ticks = 36, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.10 }, // 3 Aerie Seraph
    .{ .max_hp = 145, .max_shield = 40, .max_mana = 80, .move_speed_mult = 0.90, .damage_mult = 1.12, .dash_cooldown_ticks = 270, .dash_mana_cost = 30, .dash_distance = 150, .dash_iframe_ticks = 15, .base_armor = 8, .xp_gain_mult = 1.00, .pickup_radius_mult = 0.95 }, // 4 Saurian Scute
    .{ .max_hp = 100, .max_shield = 35, .max_mana = 150, .move_speed_mult = 1.08, .damage_mult = 1.00, .dash_cooldown_ticks = 192, .dash_mana_cost = 20, .dash_distance = 195, .dash_iframe_ticks = 14, .base_armor = 1, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 }, // 5 Abyssal Pelag
    .{ .max_hp = 80, .max_shield = 30, .max_mana = 130, .move_speed_mult = 1.05, .damage_mult = 1.20, .dash_cooldown_ticks = 216, .dash_mana_cost = 25, .dash_distance = 185, .dash_iframe_ticks = 12, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 }, // 6 Weave Widow
    .{ .max_hp = 85, .max_shield = 15, .max_mana = 100, .move_speed_mult = 1.18, .damage_mult = 1.15, .dash_cooldown_ticks = 156, .dash_mana_cost = 24, .dash_distance = 220, .dash_iframe_ticks = 18, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.05 }, // 7 Felis Nyx
    .{ .max_hp = 130, .max_shield = 30, .max_mana = 90, .move_speed_mult = 1.06, .damage_mult = 1.10, .dash_cooldown_ticks = 204, .dash_mana_cost = 25, .dash_distance = 180, .dash_iframe_ticks = 14, .base_armor = 4, .xp_gain_mult = 1.05, .pickup_radius_mult = 1.00 }, // 8 Canid Vanguard
    .{ .max_hp = 105, .max_shield = 25, .max_mana = 135, .move_speed_mult = 1.16, .damage_mult = 0.98, .dash_cooldown_ticks = 180, .dash_mana_cost = 22, .dash_distance = 200, .dash_iframe_ticks = 15, .base_armor = 1, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.35 }, // 9 Cervid Sylvan
};

/// Mana restored per second. The protocol spec fixes the dash cost and cooldown
/// but not a refill, and a dash that can never be taken twice is not a dash —
/// this flat rate is the server's choice, the same for every race.
pub const mana_regen_per_sec: f32 = 4.0;

/// One race's display name and lore, for the client's race select screen.
pub const RaceInfo = struct {
    id: RaceId,
    name: []const u8,
    lore: []const u8,
};

/// The ten races' names and lore, indexed by `RaceId`.
pub const RACE_INFO = [_]RaceInfo{
    .{ .id = .terran_kin, .name = "Terran Kin", .lore = "Steady all-rounders from the heartland; the benchmark every other race is measured against." },
    .{ .id = .mantid_vex, .name = "Mantid Vex", .lore = "Blade-limbed skirmishers. Fragile, first to arrive, hardest to pin down." },
    .{ .id = .cephalon_tide, .name = "Cephalon Tide", .lore = "Deep-tide scholars in pressure plate. Slow, shielded, and patient with a staff." },
    .{ .id = .aerie_seraph, .name = "Aerie Seraph", .lore = "Winged sky-castters. The fastest thing on two feet or four, and just as frail." },
    .{ .id = .saurian_scute, .name = "Saurian Scute", .lore = "Living siege walls. They walk through what would kill anything else." },
    .{ .id = .abyssal_pelag, .name = "Abyssal Pelag", .lore = "Gloom-dwellers of the trench. Balanced, adaptable, and always watching the gauge." },
    .{ .id = .weave_widow, .name = "Weave Widow", .lore = "Silk-spinning ambushers. They strike first and apologize never." },
    .{ .id = .felis_nyx, .name = "Felis Nyx", .lore = "Night-stalking loners. Quick, quiet, and gone before the answer lands." },
    .{ .id = .canid_vanguard, .name = "Canid Vanguard", .lore = "Shield-line pack fighters. They hold ground so others do not have to." },
    .{ .id = .cervid_sylvan, .name = "Cervid Sylvan", .lore = "Grove-wardens of the deep wood. They find what others miss and outlast it." },
};

/// The spec row for `id`, or `null` when `id` names no race. `C2S_HELLO` is
/// rejected rather than clamped: a race id the client invented must not become
/// Terran Kin by default.
pub fn spec(id: u8) ?RaceSpec {
    if (id >= RACE_SPECS.len) return null;
    return RACE_SPECS[id];
}

test "RACE_SPECS pins the ten race rows" {
    const want = [_]RaceSpec{
        .{ .max_hp = 110, .max_shield = 25, .max_mana = 100, .move_speed_mult = 1.00, .damage_mult = 1.00, .dash_cooldown_ticks = 210, .dash_mana_cost = 25, .dash_distance = 180, .dash_iframe_ticks = 12, .base_armor = 0, .xp_gain_mult = 1.12, .pickup_radius_mult = 1.00 },
        .{ .max_hp = 85, .max_shield = 15, .max_mana = 110, .move_speed_mult = 1.15, .damage_mult = 1.18, .dash_cooldown_ticks = 168, .dash_mana_cost = 20, .dash_distance = 210, .dash_iframe_ticks = 14, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 },
        .{ .max_hp = 95, .max_shield = 50, .max_mana = 140, .move_speed_mult = 0.95, .damage_mult = 1.05, .dash_cooldown_ticks = 240, .dash_mana_cost = 25, .dash_distance = 170, .dash_iframe_ticks = 12, .base_armor = 2, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.05 },
        .{ .max_hp = 75, .max_shield = 20, .max_mana = 120, .move_speed_mult = 1.22, .damage_mult = 1.08, .dash_cooldown_ticks = 144, .dash_mana_cost = 22, .dash_distance = 240, .dash_iframe_ticks = 36, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.10 },
        .{ .max_hp = 145, .max_shield = 40, .max_mana = 80, .move_speed_mult = 0.90, .damage_mult = 1.12, .dash_cooldown_ticks = 270, .dash_mana_cost = 30, .dash_distance = 150, .dash_iframe_ticks = 15, .base_armor = 8, .xp_gain_mult = 1.00, .pickup_radius_mult = 0.95 },
        .{ .max_hp = 100, .max_shield = 35, .max_mana = 150, .move_speed_mult = 1.08, .damage_mult = 1.00, .dash_cooldown_ticks = 192, .dash_mana_cost = 20, .dash_distance = 195, .dash_iframe_ticks = 14, .base_armor = 1, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 },
        .{ .max_hp = 80, .max_shield = 30, .max_mana = 130, .move_speed_mult = 1.05, .damage_mult = 1.20, .dash_cooldown_ticks = 216, .dash_mana_cost = 25, .dash_distance = 185, .dash_iframe_ticks = 12, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.00 },
        .{ .max_hp = 85, .max_shield = 15, .max_mana = 100, .move_speed_mult = 1.18, .damage_mult = 1.15, .dash_cooldown_ticks = 156, .dash_mana_cost = 24, .dash_distance = 220, .dash_iframe_ticks = 18, .base_armor = 0, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.05 },
        .{ .max_hp = 130, .max_shield = 30, .max_mana = 90, .move_speed_mult = 1.06, .damage_mult = 1.10, .dash_cooldown_ticks = 204, .dash_mana_cost = 25, .dash_distance = 180, .dash_iframe_ticks = 14, .base_armor = 4, .xp_gain_mult = 1.05, .pickup_radius_mult = 1.00 },
        .{ .max_hp = 105, .max_shield = 25, .max_mana = 135, .move_speed_mult = 1.16, .damage_mult = 0.98, .dash_cooldown_ticks = 180, .dash_mana_cost = 22, .dash_distance = 200, .dash_iframe_ticks = 15, .base_armor = 1, .xp_gain_mult = 1.00, .pickup_radius_mult = 1.35 },
    };
    try std.testing.expectEqual(RACE_SPECS.len, want.len);
    for (want, 0..) |w, i| {
        const r = RACE_SPECS[i];
        try std.testing.expectEqual(w.max_hp, r.max_hp);
        try std.testing.expectEqual(w.max_shield, r.max_shield);
        try std.testing.expectEqual(w.max_mana, r.max_mana);
        try std.testing.expectApproxEqAbs(w.move_speed_mult, r.move_speed_mult, 1e-6);
        try std.testing.expectApproxEqAbs(w.damage_mult, r.damage_mult, 1e-6);
        try std.testing.expectEqual(w.dash_cooldown_ticks, r.dash_cooldown_ticks);
        try std.testing.expectEqual(w.dash_mana_cost, r.dash_mana_cost);
        try std.testing.expectEqual(w.dash_distance, r.dash_distance);
        try std.testing.expectEqual(w.dash_iframe_ticks, r.dash_iframe_ticks);
        try std.testing.expectEqual(w.base_armor, r.base_armor);
        try std.testing.expectApproxEqAbs(w.xp_gain_mult, r.xp_gain_mult, 1e-6);
        try std.testing.expectApproxEqAbs(w.pickup_radius_mult, r.pickup_radius_mult, 1e-6);
    }
}

test "RACE_INFO lines up with RACE_SPECS" {
    try std.testing.expectEqual(RACE_SPECS.len, RACE_INFO.len);
    for (RACE_INFO, 0..) |info, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(info.id));
        try std.testing.expect(info.name.len > 0);
        try std.testing.expect(info.lore.len > 0);
    }
    try std.testing.expectEqualStrings("Terran Kin", RACE_INFO[0].name);
    try std.testing.expectEqualStrings("Cervid Sylvan", RACE_INFO[9].name);
}

test "spec rejects an unknown race id" {
    try std.testing.expect(spec(10) == null);
    try std.testing.expect(spec(0xff) == null);
    const t = spec(0).?;
    try std.testing.expectEqual(@as(u16, 110), t.max_hp);
}
