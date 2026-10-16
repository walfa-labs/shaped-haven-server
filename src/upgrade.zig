//! Shaped Haven server — the upgrade engine (DESIGN.md §3).
//!
//! One module holds every number the upgrade system needs: the item id space
//! PROTOCOL.md fixes, the ten passives, the eight evolutions, the five
//! synergies, the XP curve of §1, the stat-resolution layer that turns a
//! player's loadout into the multipliers the combat code consumes, and the
//! weighted three-choice generator.
//!
//! The id space is shared by weapons, passives, evolutions and the endless
//! Overclock upgrades, so an upgrade option, a loadout entry and a weapon id
//! all name the same thing the same way (PROTOCOL.md "Item ids"):
//!
//! ```text
//! 0..3    weapons (sword, axe, bow, gun) — also ProjNet.weapon_id
//! 16..25  passives P0..P9, in DESIGN.md §3 table order
//! 32..39  evolutions, in DESIGN.md §3 order
//! 48..50  Overclock: global damage, attack speed, max HP
//! 0xff    no item
//! ```
//!
//! This module deliberately does not import `sim.zig`: it consumes a player's
//! loadout as plain slices, so `sim.zig` can call into it without a circular
//! import. The mutation of a player's loadout on a chosen upgrade lives in
//! `sim.zig`, which owns `PlayerState`.

const std = @import("std");
const root = @import("root.zig");
const wire = @import("wire.zig");
const weapon = @import("weapon.zig");
const rng = @import("rng.zig");

/// Item ids (PROTOCOL.md "Item ids").
pub const ids = struct {
    pub const no_item: u8 = 0xff;

    /// Base weapons, matching `ProjNet.weapon_id` and DESIGN.md §3 order.
    pub const sword: u8 = 0;
    pub const axe: u8 = 1;
    pub const bow: u8 = 2;
    pub const gun: u8 = 3;

    /// Passives P0..P9 (DESIGN.md §3 table order).
    pub const spinach_core: u8 = 16;
    pub const amplifier_lens: u8 = 17;
    pub const clockwork_gear: u8 = 18;
    pub const accelerator_coil: u8 = 19;
    pub const stasis_capacitor: u8 = 20;
    pub const prism_splitter: u8 = 21;
    pub const magnet_array: u8 = 22;
    pub const thruster_boots: u8 = 23;
    pub const titanium_plating: u8 = 24;
    pub const nano_repair: u8 = 25;

    /// Evolutions (DESIGN.md §3 order).
    pub const vorpal_blender: u8 = 32;
    pub const phase_katana: u8 = 33;
    pub const gravity_cleaver: u8 = 34;
    pub const juggernaut_halberd: u8 = 35;
    pub const railgun_longbow: u8 = 36;
    pub const storm_volley: u8 = 37;
    pub const vulcan_minigun: u8 = 38;
    pub const cryo_flechette: u8 = 39;

    /// Overclock, the uncapped endgame.
    pub const overclock_damage: u8 = 48;
    pub const overclock_attack_speed: u8 = 49;
    pub const overclock_max_hp: u8 = 50;
};

/// True for the 32..39 range.
pub fn isEvolutionId(id: u8) bool {
    return id >= 32 and id < 40;
}

/// True for the 48..50 range.
pub fn isOverclockId(id: u8) bool {
    return id >= 48 and id < 51;
}

/// The base weapon an evolution grows from, or `id` itself when it is not an
/// evolution. `ProjNet.weapon_id` only carries 0..3, so an evolved weapon still
/// reports the weapon it grew from on the wire.
pub fn baseWeaponId(id: u8) u8 {
    if (!isEvolutionId(id)) return id;
    const evo = evolutionById(id) orelse return id;
    return evo.weapon_id;
}

// ---------------------------------------------------------------------------
// One weapon slot (DESIGN.md §2 `WeaponSlot`)
// ---------------------------------------------------------------------------

/// One weapon a player carries. `id` is a base weapon (0..3) or an evolution
/// (32..39); `0xff` names an empty slot. `level` is 1..8 and `evolved` records
/// that the slot was fused, which the loadout reports.
pub const WeaponSlot = struct {
    id: u8 = ids.no_item,
    level: u8 = 1,
    cooldown_ticks: u16 = 0,
    evolved: bool = false,
    /// Follow-up slashes still owed this cycle (Sword L8 fires two).
    pending_slashes: u8 = 0,
    /// Ticks until the next follow-up slash.
    pending_timer: u16 = 0,
    /// Shots fired since the slot was created; the Gun's explosive round reads
    /// it (DESIGN.md §3 "every 4th shot explodes").
    shots_fired: u16 = 0,

    /// Resolved spec for this slot: the level's row of its table, or the
    /// evolution's spec when the slot was fused.
    pub fn spec(slot: WeaponSlot) ?weapon.Spec {
        return weapon.specFor(slot.id, slot.level);
    }

    pub fn isFree(slot: WeaponSlot) bool {
        return slot.id == ids.no_item;
    }
};

// ---------------------------------------------------------------------------
// Passives (DESIGN.md §3)
// ---------------------------------------------------------------------------

/// One passive. `index` is 0..9, the position in the player's `passives` array
/// and the order of the DESIGN.md §3 table; `id` is the wire id, `16 + index`.
pub const Passive = struct {
    index: u8,
    id: u8,
    name: []const u8,
    /// Stat the passive modifies, for the loadout/debug output.
    stat: []const u8,
    /// Per-level effect, for the loadout/debug output.
    effect: []const u8,
    max_level: u8,
};

/// The ten passives, in DESIGN.md §3 table order.
pub const passive_table = [_]Passive{
    .{ .index = 0, .id = ids.spinach_core, .name = "Spinach Core", .stat = "Damage", .effect = "+10% base weapon damage", .max_level = 5 },
    .{ .index = 1, .id = ids.amplifier_lens, .name = "Amplifier Lens", .stat = "Area", .effect = "+12% hitbox/arc radius", .max_level = 5 },
    .{ .index = 2, .id = ids.clockwork_gear, .name = "Clockwork Gear", .stat = "Cooldown", .effect = "-8% weapon cooldown ticks", .max_level = 5 },
    .{ .index = 3, .id = ids.accelerator_coil, .name = "Accelerator Coil", .stat = "Projectile speed", .effect = "+15% projectile velocity", .max_level = 5 },
    .{ .index = 4, .id = ids.stasis_capacitor, .name = "Stasis Capacitor", .stat = "Duration", .effect = "+15% hitbox/projectile lifetime", .max_level = 5 },
    .{ .index = 5, .id = ids.prism_splitter, .name = "Prism Splitter", .stat = "Projectile count", .effect = "+1 projectile / swing per cycle", .max_level = 3 },
    .{ .index = 6, .id = ids.magnet_array, .name = "Magnet Array", .stat = "Pickup radius", .effect = "+35% XP gem attraction range", .max_level = 5 },
    .{ .index = 7, .id = ids.thruster_boots, .name = "Thruster Boots", .stat = "Move speed", .effect = "+8% player movement speed", .max_level = 5 },
    .{ .index = 8, .id = ids.titanium_plating, .name = "Titanium Plating", .stat = "Armor", .effect = "-3 flat damage taken (min 1)", .max_level = 5 },
    .{ .index = 9, .id = ids.nano_repair, .name = "Nano Repair", .stat = "Regen", .effect = "+0.8 HP restored per second", .max_level = 5 },
};

/// Max level of the passive at `index` (0..9).
pub fn passiveMaxLevel(index: u8) u8 {
    return passive_table[index].max_level;
}

/// Max level of the passive with wire id `id` (16..25).
pub fn passiveMaxLevelById(id: u8) ?u8 {
    for (passive_table) |p| {
        if (p.id == id) return p.max_level;
    }
    return null;
}

/// Index of the passive with wire id `id`, or `null`.
pub fn passiveIndex(id: u8) ?usize {
    for (passive_table, 0..) |p, i| {
        if (p.id == id) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Evolutions (DESIGN.md §3)
// ---------------------------------------------------------------------------

/// One evolution: a weapon at level 8 plus its named passive at max level.
pub const Evolution = struct {
    id: u8,
    name: []const u8,
    weapon_id: u8,
    passive_id: u8,
};

/// The eight evolutions, in DESIGN.md §3 order.
pub const evolutions = [_]Evolution{
    .{ .id = ids.vorpal_blender, .name = "Vorpal Blender", .weapon_id = ids.sword, .passive_id = ids.clockwork_gear },
    .{ .id = ids.phase_katana, .name = "Phase Katana", .weapon_id = ids.sword, .passive_id = ids.thruster_boots },
    .{ .id = ids.gravity_cleaver, .name = "Gravity Cleaver", .weapon_id = ids.axe, .passive_id = ids.amplifier_lens },
    .{ .id = ids.juggernaut_halberd, .name = "Juggernaut Halberd", .weapon_id = ids.axe, .passive_id = ids.titanium_plating },
    .{ .id = ids.railgun_longbow, .name = "Railgun Longbow", .weapon_id = ids.bow, .passive_id = ids.accelerator_coil },
    .{ .id = ids.storm_volley, .name = "Storm Volley", .weapon_id = ids.bow, .passive_id = ids.prism_splitter },
    .{ .id = ids.vulcan_minigun, .name = "Vulcan Minigun", .weapon_id = ids.gun, .passive_id = ids.spinach_core },
    .{ .id = ids.cryo_flechette, .name = "Cryo Flechette", .weapon_id = ids.gun, .passive_id = ids.stasis_capacitor },
};

/// Evolution with wire id `id`, or `null`.
pub fn evolutionById(id: u8) ?Evolution {
    for (evolutions) |e| {
        if (e.id == id) return e;
    }
    return null;
}

/// The evolution `weapon_id` + `passive_id` fuse into, or `null`.
pub fn evolutionFor(weapon_id: u8, passive_id: u8) ?Evolution {
    for (evolutions) |e| {
        if (e.weapon_id == weapon_id and e.passive_id == passive_id) return e;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Synergies (DESIGN.md §3)
// ---------------------------------------------------------------------------

/// One synergy: two items, both at level 3 or higher.
pub const Synergy = struct {
    id: u8,
    name: []const u8,
    a: u8,
    b: u8,
};

/// The five synergies. `a`/`b` are wire ids: passives are 16..25, weapons 0..3.
pub const synergies = [_]Synergy{
    .{ .id = 0, .name = "Singularity Field", .a = ids.magnet_array, .b = ids.amplifier_lens },
    .{ .id = 1, .name = "Reactive Carapace", .a = ids.titanium_plating, .b = ids.nano_repair },
    .{ .id = 2, .name = "Cross-Slash Mastery", .a = ids.sword, .b = ids.axe },
    .{ .id = 3, .name = "Target Painter", .a = ids.bow, .b = ids.gun },
    .{ .id = 4, .name = "Kinetic Charge", .a = ids.thruster_boots, .b = ids.accelerator_coil },
};

/// `synergy_mask` bits, in the order of `synergies`.
pub const synergy_singularity_field: u16 = 1 << 0;
pub const synergy_reactive_carapace: u16 = 1 << 1;
pub const synergy_cross_slash: u16 = 1 << 2;
pub const synergy_target_painter: u16 = 1 << 3;
pub const synergy_kinetic_charge: u16 = 1 << 4;

/// Level of an item id in a loadout: a passive's level, a weapon's level, or 0.
pub fn itemLevel(weapons: []const WeaponSlot, passives: []const u8, id: u8) u8 {
    if (isEvolutionId(id)) return 0;
    if (id < 4) {
        for (weapons) |slot| {
            if (slot.id == id) return slot.level;
            if (isEvolutionId(slot.id) and baseWeaponId(slot.id) == id) return slot.level;
        }
        return 0;
    }
    if (passiveIndex(id)) |i| return passives[i];
    return 0;
}

/// Bit mask of the synergies active for this loadout (DESIGN.md §3: both items
/// at level 3 or higher).
pub fn synergyMask(weapons: []const WeaponSlot, passives: []const u8) u16 {
    var mask: u16 = 0;
    for (synergies, 0..) |s, i| {
        if (itemLevel(weapons, passives, s.a) >= 3 and
            itemLevel(weapons, passives, s.b) >= 3)
        {
            mask |= @as(u16, 1) << @intCast(i);
        }
    }
    return mask;
}

// ---------------------------------------------------------------------------
// XP curve (DESIGN.md §1)
// ---------------------------------------------------------------------------

/// `XP(L) = floor(10 + 5L + 1.5L²)` — the XP needed to go from level `L` to
/// `L+1`. `L` is the player's current level, so a level-1 player needs
/// `xpForLevel(1)` to reach level 2.
pub fn xpForLevel(level: u16) u32 {
    const l: f32 = @floatFromInt(level);
    return @intFromFloat(@floor(10.0 + 5.0 * l + 1.5 * l * l));
}

// ---------------------------------------------------------------------------
// Stat resolution
// ---------------------------------------------------------------------------

/// The multipliers a loadout applies to every weapon. This is the layer the
/// phase-2 review asked for: weapon levels and passives change these numbers,
/// and the combat code reads the resolved spec rather than the level-1 table.
pub const Stats = struct {
    damage_mult: f32 = 1.0,
    area_mult: f32 = 1.0,
    cooldown_mult: f32 = 1.0,
    proj_speed_mult: f32 = 1.0,
    duration_mult: f32 = 1.0,
    count_bonus: u8 = 0,
    pickup_radius: f32 = root.xp_pickup_radius,
    move_speed_mult: f32 = 1.0,
    armor_flat: f32 = 0.0,
    regen_per_sec: f32 = 0.0,
    max_hp_bonus: f32 = 0.0,
};

/// Floor for the attack-speed Overclock's per-purchase cooldown factor.
///
/// Each attack-speed Overclock multiplies the cooldown by `1 - 0.015`. That
/// linear factor is exact for the first 63 purchases but turns negative at 67,
/// and a negative multiplier is not a faster attack — it is a broken one:
/// `scaleTicks` would silently floor every weapon's cooldown at 1 tick. So
/// unlimited attack speed means the factor approaches this floor instead: the
/// cooldown can shrink to 5% of base (a 20x attack rate) and no further, and
/// the multiplier stays positive and meaningful at any count.
pub const overclock_cooldown_floor: f32 = 0.05;

/// Resolve a loadout into its multipliers.
///
/// `overclock` holds the three Overclock counts, indexed by
/// `id - ids.overclock_damage` (48 -> 0, 49 -> 1, 50 -> 2). The counts are
/// `u32` because they are uncapped; see `PlayerState.overclock` in `sim.zig`.
pub fn resolveStats(
    weapons: []const WeaponSlot,
    passives: []const u8,
    overclock: []const u32,
) Stats {
    _ = weapons;
    var s = Stats{};

    for (passives, 0..) |lvl, i| {
        if (lvl == 0) continue;
        const f: f32 = @floatFromInt(lvl);
        switch (i) {
            0 => s.damage_mult *= 1.0 + 0.10 * f,
            1 => s.area_mult *= 1.0 + 0.12 * f,
            2 => s.cooldown_mult *= 1.0 - 0.08 * f,
            3 => s.proj_speed_mult *= 1.0 + 0.15 * f,
            4 => s.duration_mult *= 1.0 + 0.15 * f,
            5 => s.count_bonus += lvl,
            6 => s.pickup_radius = root.xp_pickup_radius * (1.0 + 0.35 * f),
            7 => s.move_speed_mult *= 1.0 + 0.08 * f,
            8 => s.armor_flat += 3.0 * f,
            9 => s.regen_per_sec += 0.8 * f,
            else => {},
        }
    }

    if (overclock.len >= 1) s.damage_mult *= 1.0 + 0.02 * @as(f32, @floatFromInt(overclock[0]));
    if (overclock.len >= 2) {
        const factor = 1.0 - 0.015 * @as(f32, @floatFromInt(overclock[1]));
        s.cooldown_mult *= @max(factor, overclock_cooldown_floor);
    }
    if (overclock.len >= 3) s.max_hp_bonus += 25.0 * @as(f32, @floatFromInt(overclock[2]));

    return s;
}

/// Apply the resolved multipliers to one weapon spec.
///
/// The level table supplies the shape; this scales it by the loadout. Area
/// covers reach, arc width and projectile radius; duration covers the sweep's
/// visual lifetime and a projectile's travel time; count is the Prism Splitter
/// bonus of extra projectiles per shot.
pub fn resolveSpec(base: weapon.Spec, s: Stats) weapon.Spec {
    var r = base;
    r.damage *= s.damage_mult;
    r.cooldown_ticks = scaleTicks(r.cooldown_ticks, s.cooldown_mult);
    r.reach *= s.area_mult;
    r.arc_rad *= s.area_mult;
    r.speed *= s.proj_speed_mult;
    r.radius *= s.area_mult;
    r.ttl_ticks = scaleTicks(r.ttl_ticks, s.duration_mult);
    r.count +|= s.count_bonus;
    return r;
}

fn scaleTicks(ticks: u16, mult: f32) u16 {
    const scaled = @as(f32, @floatFromInt(ticks)) * mult;
    return @intFromFloat(@max(1.0, @round(scaled)));
}

// ---------------------------------------------------------------------------
// Level-up choices
// ---------------------------------------------------------------------------

/// One entry of a level-up offer (PROTOCOL.md `UpgradeOptionNet`).
pub const UpgradeOption = struct {
    item_id: u8,
    next_level: u8,
    is_evo: bool,
};

/// A candidate and its weight in the draw.
const Candidate = struct {
    option: UpgradeOption,
    weight: u32,
};

/// Largest number of candidates the generator can hold: four weapon levels,
/// four new weapons, ten passives, eight evolutions, three Overclock.
const max_candidates: usize = 4 + 4 + 10 + 8 + 3;

/// Weights. Levelling an item the player already holds is the common case and
/// the most useful, so it draws most often; a brand-new item is a little rarer;
/// an evolution is a milestone and the rarest; Overclock is the fallback.
const weight_level: u32 = 4;
const weight_new: u32 = 3;
const weight_evolution: u32 = 2;
const weight_overclock: u32 = 1;

/// True when every held weapon and passive is at its maximum, which is when the
/// three repeatable Overclock upgrades take over (DESIGN.md §3 "Unlimited
/// limit-break"). Unheld items do not block it.
pub fn allMaxed(weapons: []const WeaponSlot, passives: []const u8) bool {
    for (weapons) |slot| {
        // An empty weapon slot is itself something left to fill, so the
        // Overclock fallback cannot be reached while one is open.
        if (slot.isFree()) return false;
        if (slot.level < root.max_weapon_level) return false;
    }
    for (passives, 0..) |lvl, i| {
        if (lvl == 0) continue;
        if (lvl < passiveMaxLevel(@intCast(i))) return false;
    }
    return true;
}

/// Build the three weighted choices for a loadout.
///
/// Draws three distinct candidates without replacement, weighted. When every
/// held item is maxed the only candidates are the three Overclock upgrades,
/// which is what makes progression unlimited; if a loadout somehow offers
/// fewer than three candidates the remainder is padded with Overclock so the
/// offer is always a full three options.
pub fn generateOptions(
    weapons: []const WeaponSlot,
    passives: []const u8,
    overclock: []const u32,
    r: *rng.Rng,
) [3]UpgradeOption {
    _ = overclock;
    var cands: [max_candidates]Candidate = undefined;
    var n: usize = 0;

    if (allMaxed(weapons, passives)) {
        for (0..3) |i| {
            const id: u8 = ids.overclock_damage + @as(u8, @intCast(i));
            cands[n] = .{
                .option = .{ .item_id = id, .next_level = 1, .is_evo = false },
                .weight = weight_overclock,
            };
            n += 1;
        }
        // The three Overclock upgrades are the whole offer, in id order.
        return .{ cands[0].option, cands[1].option, cands[2].option };
    }

    // Levelling a held weapon.
    for (weapons) |slot| {
        if (slot.isFree() or isEvolutionId(slot.id)) continue;
        if (slot.level >= root.max_weapon_level) continue;
        cands[n] = .{
            .option = .{ .item_id = slot.id, .next_level = slot.level + 1, .is_evo = false },
            .weight = weight_level,
        };
        n += 1;
    }

    // A new weapon into a free slot.
    var free_slots: usize = 0;
    for (weapons) |slot| {
        if (slot.isFree()) free_slots += 1;
    }
    if (free_slots > 0) {
        for (0..root.max_weapons) |w| {
            const id: u8 = @intCast(w);
            if (holdsWeapon(weapons, id)) continue;
            cands[n] = .{
                .option = .{ .item_id = id, .next_level = 1, .is_evo = false },
                .weight = weight_new,
            };
            n += 1;
        }
    }

    // Levelling a held passive.
    for (passives, 0..) |lvl, i| {
        if (lvl == 0) continue;
        if (lvl >= passiveMaxLevel(@intCast(i))) continue;
        cands[n] = .{
            .option = .{ .item_id = passivesId(@intCast(i)), .next_level = lvl + 1, .is_evo = false },
            .weight = weight_level,
        };
        n += 1;
    }

    // A new passive.
    for (passives, 0..) |lvl, i| {
        if (lvl != 0) continue;
        cands[n] = .{
            .option = .{ .item_id = passivesId(@intCast(i)), .next_level = 1, .is_evo = false },
            .weight = weight_new,
        };
        n += 1;
    }

    // Evolutions: weapon at level 8 and its named passive at max.
    for (evolutions) |evo| {
        if (!holdsWeaponAtLevel(weapons, evo.weapon_id, root.max_weapon_level)) continue;
        const max = passiveMaxLevelById(evo.passive_id) orelse continue;
        if (!holdsPassiveAtLevel(passives, evo.passive_id, max)) continue;
        if (holdsEvolution(weapons, evo.id)) continue;
        cands[n] = .{
            .option = .{ .item_id = evo.id, .next_level = root.max_weapon_level, .is_evo = true },
            .weight = weight_evolution,
        };
        n += 1;
    }

    // Pad with Overclock if the loadout offers fewer than three candidates.
    while (n < 3) {
        const id: u8 = ids.overclock_damage + @as(u8, @intCast(n % 3));
        cands[n] = .{
            .option = .{ .item_id = id, .next_level = 1, .is_evo = false },
            .weight = weight_overclock,
        };
        n += 1;
    }

    return weightedPick(&cands, n, r);
}

fn passivesId(index: usize) u8 {
    return passive_table[index].id;
}

/// Draw three distinct candidates, weighted, without replacement.
fn weightedPick(cands: []Candidate, n: usize, r: *rng.Rng) [3]UpgradeOption {
    var pool: [max_candidates]Candidate = undefined;
    @memcpy(pool[0..n], cands[0..n]);
    var pool_len = n;

    var out: [3]UpgradeOption = .{
        .{ .item_id = ids.no_item, .next_level = 0, .is_evo = false },
        .{ .item_id = ids.no_item, .next_level = 0, .is_evo = false },
        .{ .item_id = ids.no_item, .next_level = 0, .is_evo = false },
    };

    var chosen: usize = 0;
    while (chosen < 3 and pool_len > 0) : (chosen += 1) {
        var total: u32 = 0;
        for (pool[0..pool_len]) |c| total += c.weight;

        var roll: u32 = 0;
        if (total > 0) roll = @intCast(r.below(total));

        var idx: usize = 0;
        while (idx + 1 < pool_len) : (idx += 1) {
            if (roll < pool[idx].weight) break;
            roll -= pool[idx].weight;
        }

        out[chosen] = pool[idx].option;
        pool[idx] = pool[pool_len - 1];
        pool_len -= 1;
    }
    return out;
}

/// True when the loadout holds a weapon slot with base id `id`.
pub fn holdsWeapon(weapons: []const WeaponSlot, id: u8) bool {
    for (weapons) |slot| {
        if (slot.id == id) return true;
        if (isEvolutionId(slot.id) and baseWeaponId(slot.id) == id) return true;
    }
    return false;
}

/// True when the loadout holds `id` at `level` or higher.
pub fn holdsWeaponAtLevel(weapons: []const WeaponSlot, id: u8, level: u8) bool {
    for (weapons) |slot| {
        if (slot.isFree()) continue;
        const base = baseWeaponId(slot.id);
        if (base != id) continue;
        if (slot.level >= level) return true;
    }
    return false;
}

/// True when the loadout holds passive `id` at `level` or higher.
pub fn holdsPassiveAtLevel(passives: []const u8, id: u8, level: u8) bool {
    const i = passiveIndex(id) orelse return false;
    return passives[i] >= level;
}

/// True when the loadout already holds evolution `id`.
pub fn holdsEvolution(weapons: []const WeaponSlot, id: u8) bool {
    for (weapons) |slot| {
        if (slot.id == id) return true;
    }
    return false;
}

/// Find the weapon slot holding base weapon `id`, or `null`.
pub fn weaponSlot(weapons: []const WeaponSlot, id: u8) ?usize {
    for (weapons, 0..) |slot, i| {
        if (slot.isFree()) continue;
        if (baseWeaponId(slot.id) == id) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the XP curve matches DESIGN.md §1" {
    try std.testing.expectEqual(@as(u32, 16), xpForLevel(1));
    try std.testing.expectEqual(@as(u32, 26), xpForLevel(2));
    try std.testing.expectEqual(@as(u32, 38), xpForLevel(3));
    try std.testing.expectEqual(@as(u32, 54), xpForLevel(4));
    try std.testing.expectEqual(@as(u32, 72), xpForLevel(5));
    try std.testing.expectEqual(@as(u32, 210), xpForLevel(10));
    try std.testing.expect(xpForLevel(20) > xpForLevel(19));
}

test "passive ids are 16 + index in DESIGN.md §3 table order" {
    for (passive_table, 0..) |p, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), p.index);
        try std.testing.expectEqual(@as(u8, 16 + @as(u8, @intCast(i))), p.id);
    }
    try std.testing.expectEqual(@as(u8, 3), passive_table[5].max_level); // Prism Splitter
    try std.testing.expectEqual(@as(u8, 5), passive_table[0].max_level);
    try std.testing.expectEqual(@as(usize, 10), passive_table.len);
}

test "evolution ids are 32..39 and pair the DESIGN.md §3 weapon with its passive" {
    for (evolutions, 0..) |e, i| {
        try std.testing.expectEqual(@as(u8, 32 + @as(u8, @intCast(i))), e.id);
        try std.testing.expect(e.weapon_id < 4);
        try std.testing.expect(e.passive_id >= 16 and e.passive_id < 26);
    }
    try std.testing.expectEqual(ids.vorpal_blender, evolutionFor(ids.sword, ids.clockwork_gear).?.id);
    try std.testing.expectEqual(ids.cryo_flechette, evolutionFor(ids.gun, ids.stasis_capacitor).?.id);
    try std.testing.expect(evolutionFor(ids.sword, ids.spinach_core) == null);
    try std.testing.expectEqual(@as(u8, ids.sword), baseWeaponId(ids.vorpal_blender));
    try std.testing.expectEqual(@as(u8, ids.sword), baseWeaponId(ids.vorpal_blender));
}

test "synergy ids and the level-3 gate" {
    try std.testing.expectEqual(@as(usize, 5), synergies.len);
    var empty_weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var no_passives: [root.max_passives]u8 = @splat(0);
    try std.testing.expectEqual(@as(u16, 0), synergyMask(&empty_weapons, &no_passives));

    // Sword and axe at level 3 arm Cross-Slash Mastery.
    empty_weapons[0].id = ids.sword;
    empty_weapons[0].level = 3;
    empty_weapons[1].id = ids.axe;
    empty_weapons[1].level = 2;
    try std.testing.expectEqual(@as(u16, 0), synergyMask(&empty_weapons, &no_passives));
    empty_weapons[1].level = 3;
    try std.testing.expectEqual(@as(u16, 1 << 2), synergyMask(&empty_weapons, &no_passives));

    // Two passives at level 3 arm their synergy.
    no_passives[6] = 3; // Magnet Array
    no_passives[1] = 3; // Amplifier Lens
    try std.testing.expectEqual(@as(u16, 1 << 2 | 1 << 0), synergyMask(&empty_weapons, &no_passives));
}

test "resolveStats applies the ten passives" {
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };

    // Nothing held: the defaults.
    const base = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), base.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, root.xp_pickup_radius), base.pickup_radius, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), base.armor_flat, 1e-6);

    // Spinach Core 5: +50% damage.
    passives[0] = 5;
    // Amplifier Lens 5: +60% area.
    passives[1] = 5;
    // Clockwork Gear 5: -40% cooldown.
    passives[2] = 5;
    // Accelerator Coil 5: +75% projectile speed.
    passives[3] = 5;
    // Stasis Capacitor 5: +75% duration.
    passives[4] = 5;
    // Prism Splitter 3: +3 projectiles.
    passives[5] = 3;
    // Magnet Array 5: 3.0 * 2.75 = 8.25 pickup radius.
    passives[6] = 5;
    // Thruster Boots 5: +40% move speed.
    passives[7] = 5;
    // Titanium Plating 5: -15 flat armor.
    passives[8] = 5;
    // Nano Repair 5: +4.0 HP/s.
    passives[9] = 5;

    const s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), s.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.6), s.area_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), s.cooldown_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), s.proj_speed_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), s.duration_mult, 1e-6);
    try std.testing.expectEqual(@as(u8, 3), s.count_bonus);
    try std.testing.expectApproxEqAbs(@as(f32, 8.25), s.pickup_radius, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), s.move_speed_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), s.armor_flat, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), s.regen_per_sec, 1e-6);
}

test "overclock scales damage, attack speed and max HP without a cap" {
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };
    _ = &weapons;
    _ = &passives;

    overclock[0] = 10; // +20% damage
    overclock[1] = 10; // -15% cooldown
    overclock[2] = 10; // +250 max HP
    const s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), s.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), s.cooldown_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 250.0), s.max_hp_bonus, 1e-6);

    // No cap: 100 stacks still applies.
    overclock[0] = 100;
    try std.testing.expectApproxEqAbs(
        @as(f32, 3.0),
        resolveStats(&weapons, &passives, &overclock).damage_mult,
        1e-6,
    );
}

test "Overclock counts crossing 255 keep their bonuses" {
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };
    _ = &weapons;
    _ = &passives;

    // 255 was the old `u8` ceiling; 256 is where the wrapping add fell back
    // to zero. The bonus must be continuous across that boundary.
    overclock[0] = 255;
    overclock[2] = 255;
    var s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 6.1), s.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6375.0), s.max_hp_bonus, 1e-6);

    overclock[0] = 256;
    overclock[2] = 256;
    s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 6.12), s.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6400.0), s.max_hp_bonus, 1e-6);

    // And far beyond any byte: 1000 stacks.
    overclock[0] = 1000;
    overclock[2] = 1000;
    s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), s.damage_mult, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 25000.0), s.max_hp_bonus, 1e-6);
}

test "attack speed cooldown never goes non-positive" {
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };
    _ = &weapons;
    _ = &passives;

    // 63 purchases is the last count where the linear factor is still above
    // the floor: 1 - 0.015 * 63 = 0.055.
    overclock[1] = 63;
    var s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(@as(f32, 0.055), s.cooldown_mult, 1e-6);
    try std.testing.expect(s.cooldown_mult > 0.0);

    // 67 is where the old linear formula first went negative (-0.005); the
    // clamp holds the multiplier at the floor instead.
    overclock[1] = 67;
    s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(overclock_cooldown_floor, s.cooldown_mult, 1e-6);
    try std.testing.expect(s.cooldown_mult > 0.0);

    // The floor holds at any count, however large.
    overclock[1] = 1000;
    s = resolveStats(&weapons, &passives, &overclock);
    try std.testing.expectApproxEqAbs(overclock_cooldown_floor, s.cooldown_mult, 1e-6);
    try std.testing.expect(s.cooldown_mult > 0.0);
}

test "resolveSpec scales a weapon by the loadout" {
    const base = weapon.spec(@intFromEnum(weapon.Id.gun)).?;
    const s = Stats{
        .damage_mult = 1.5,
        .cooldown_mult = 0.5,
        .proj_speed_mult = 2.0,
        .duration_mult = 2.0,
        .count_bonus = 2,
        .area_mult = 1.25,
    };
    const r = resolveSpec(base, s);
    try std.testing.expectApproxEqAbs(@as(f32, 18.0), r.damage, 1e-6); // 12 * 1.5
    try std.testing.expectEqual(@as(u16, 8), r.cooldown_ticks); // 15 * 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 56.0), r.speed, 1e-6); // 28 * 2
    try std.testing.expectApproxEqAbs(@as(f32, 144), r.ttl_ticks, 1e-6); // 72 * 2
    try std.testing.expectEqual(@as(u8, 3), r.count); // 1 + 2
    try std.testing.expectApproxEqAbs(@as(f32, 0.3125), r.radius, 1e-6); // 0.25 * 1.25
}

test "generateOptions offers three distinct choices" {
    var r = rng.Rng.init(42);
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };

    // A fresh player: four level-1 weapons, no passives.
    for (&weapons, 0..) |*slot, i| slot.id = @intCast(i);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const opts = generateOptions(&weapons, &passives, &overclock, &r);
        for (opts) |o| {
            try std.testing.expect(o.item_id != ids.no_item);
            try std.testing.expect(o.next_level > 0);
        }
        // Distinct.
        try std.testing.expect(opts[0].item_id != opts[1].item_id);
        try std.testing.expect(opts[1].item_id != opts[2].item_id);
        try std.testing.expect(opts[0].item_id != opts[2].item_id);
    }
}

test "a maxed loadout offers only Overclock" {
    var r = rng.Rng.init(7);
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };
    for (&weapons, 0..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 8;
    }
    for (passives, 0..) |_, i| passives[i] = passiveMaxLevel(@intCast(i));

    try std.testing.expect(allMaxed(&weapons, &passives));
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const opts = generateOptions(&weapons, &passives, &overclock, &r);
        for (opts) |o| {
            try std.testing.expect(isOverclockId(o.item_id));
            try std.testing.expect(!o.is_evo);
        }
        // The three Overclock ids, once each.
        try std.testing.expectEqual(ids.overclock_damage, opts[0].item_id);
        try std.testing.expectEqual(ids.overclock_attack_speed, opts[1].item_id);
        try std.testing.expectEqual(ids.overclock_max_hp, opts[2].item_id);
    }
}

test "an evolution is offered once its weapon and passive are maxed" {
    var r = rng.Rng.init(99);
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };

    weapons[0].id = ids.sword;
    weapons[0].level = 8;
    passives[2] = 5; // Clockwork Gear maxed
    // Sword and Clockwork are maxed, so Vorpal Blender is a candidate. It is
    // weighted below levelling, but a draw of 400 must surface it.
    var seen_evo = false;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        for (generateOptions(&weapons, &passives, &overclock, &r)) |o| {
            if (o.item_id == ids.vorpal_blender) {
                seen_evo = true;
                try std.testing.expect(o.is_evo);
                try std.testing.expectEqual(@as(u8, 8), o.next_level);
            }
        }
    }
    try std.testing.expect(seen_evo);
}

test "the weighted draw never repeats an option" {
    var r = rng.Rng.init(1234);
    var weapons: [root.max_weapons]WeaponSlot = root.filledWithDefault(WeaponSlot, root.max_weapons);
    var passives: [root.max_passives]u8 = @splat(0);
    var overclock = [_]u32{ 0, 0, 0 };
    for (&weapons, 0..) |*slot, i| slot.id = @intCast(i);
    passives[0] = 1;
    passives[1] = 1;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const opts = generateOptions(&weapons, &passives, &overclock, &r);
        try std.testing.expect(opts[0].item_id != opts[1].item_id);
        try std.testing.expect(opts[0].item_id != opts[2].item_id);
        try std.testing.expect(opts[1].item_id != opts[2].item_id);
    }
}
