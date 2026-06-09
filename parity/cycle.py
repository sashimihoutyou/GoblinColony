"""照合用 Python 版中心サイクル (共有 Rng を使用)。

元 verify_trinity_cycle_v5.py は Python 標準 random を使うため、
TS 実装 (決定的 Rng / KI-09) とは乱数列が一致しない。本ファイルは
標準 random を共有 Rng (parity/rng.py) に差し替えただけのもので、
ロジックは元 v5 と同一。これと src/sim/cycle.ts が一致すれば、
「力学が TS に正しく移植された」と言える (KI 横断: 力学を共有せよ)。

乱数の消費順序を TS と厳密に揃える:
  小規模襲撃判定 next_float() → (起きたら) 報酬分岐 next_float()
"""
import json
import sys

sys.path.insert(0, "parity")
from rng import Rng

RAID_INTERVAL_DAYS = 3


def rank_from_cumulative(cum, thresholds):
    r = 0
    for t in thresholds:
        if cum >= t:
            r += 1
        else:
            break
    return r


def simulate_raid(enemies, fighters, faith, p, allow_aoe=False):
    gp, ep = p["GOBLIN_POWER"], p["ENEMY_POWER"]
    cost, dmg = p["SPELL_COST"], p["SPELL_DAMAGE"]
    g, e, casts = float(fighters), float(enemies), 0
    if allow_aoe:
        purge_cost = p["PURGE_COST"]
        while faith >= purge_cost and e > g:
            e *= 1.0 - p["PURGE_FRAC"]
            faith -= purge_cost
            casts += 1
        if faith >= p["WARD_COST"]:
            ep *= 1.0 - p["WARD_REDUCE"]
            faith -= p["WARD_COST"]
            casts += 1
    for _ in range(1000):
        if g <= 0 or e <= 0:
            break
        if faith >= cost and e > g:
            e -= dmg
            faith -= cost
            casts += 1
            if e <= 0:
                break
        de, dg = g * gp, e * ep
        e -= de
        g -= dg
    return max(g, 0.0), max(e, 0.0), casts, faith


def run_campaign(p, days=30):
    RI = p["RAID_INTERVAL"]
    thr = p["RANK_THRESHOLDS"]
    pop = float(p["START_GOBLINS"])
    cap_pop = float(p["START_CAP_POP"])
    cap_pop_max = p["CAP_POP_MAX"]
    death = p["DEATH_RATE"]
    faith, cum = 0.0, 0.0
    fledge_total = 0.0
    pop_min, pop_max = float(p["START_GOBLINS"]), float(p["START_GOBLINS"])
    surge = 0.0
    food_buff = 0.0
    captives = 0.0
    human_captives = 0.0
    final_win = None
    rng = Rng(p.get("SEED", 0))
    cond2, log = [], []
    for day in range(1, days + 1):
        rank = rank_from_cumulative(cum, thr)
        slot = 1 + rank
        if p.get("SHAMAN_MODE", "max") == "ratio":
            shamans = min(slot, int(pop * p["SHAMAN_RATIO"]), int(pop))
        else:
            shamans = min(slot, int(pop))
        shamans = max(shamans, 0)
        labor = max(pop - shamans, 0)
        faith_per_day = shamans * p["FAITH_PER_SHAMAN"] * (RI / RAID_INTERVAL_DAYS)
        cum += faith_per_day
        cap = p["BASE_CAP"] + p["CAP_PER_RANK"] * rank
        faith = min(faith + faith_per_day, cap)
        head = max(0.0, 1.0 - cap_pop / cap_pop_max)
        cap_pop += labor * p["EXPAND_PER_LABOR"] * head

        pop -= pop * death
        breed_mult = 1.0 + surge + food_buff
        pop += labor * p["BREED_PER_LABOR"] * breed_mult
        if p.get("CAPTIVE_STRATEGY", "nursery") in ("nursery", "mixed"):
            usable_n = max(0.0, captives - human_captives)
            if usable_n > 0:
                born = usable_n * p["NURSERY_RATE"]
                pop += born
                captives = max(human_captives, captives - born * p["CAPTIVE_CONSUME"])
        surge = max(0.0, surge - p["SURGE_DECAY"])
        food_buff = max(0.0, food_buff - p["FOOD_DECAY"])

        if rng.next_float() < p["SMALL_PROB"]:
            pop -= pop * p["SMALL_LOSS_FRAC"]
            roll = rng.next_float()
            rs = p.get("SMALL_REWARD_SCALE", 1.0)
            if roll < p["SMALL_FOOD_ONLY"]:
                food_buff = min(p["FOOD_BUFF_MAX"], food_buff + p["FOOD_GAIN"] * rs)
            elif roll < p["SMALL_FOOD_ONLY"] + p["SMALL_CAPTIVE_ONLY"]:
                _g = p["CAPTIVE_GAIN"] * rs
                captives += _g
                human_captives += _g * p["HUMAN_CAPTIVE_FRAC"]
            else:
                food_buff = min(p["FOOD_BUFF_MAX"], food_buff + p["FOOD_GAIN"] * rs)
                _g = p["CAPTIVE_GAIN"] * rs
                captives += _g
                human_captives += _g * p["HUMAN_CAPTIVE_FRAC"]
            if pop < 0:
                pop = 0.0

        if pop > cap_pop:
            fledge_total += pop - cap_pop
            pop = cap_pop
        if pop < 0:
            pop = 0.0
        pop_min = min(pop_min, pop)
        pop_max = max(pop_max, pop)

        FINAL = p["FINAL_DAY"]
        siege_start = FINAL - p["SIEGE_LEN"]
        is_final = day == FINAL
        is_siege = siege_start <= day < FINAL
        if is_final:
            raid_today = True
        elif is_siege:
            raid_today = day % p["SIEGE_INTERVAL"] == 0
        else:
            raid_today = day % p["BIG_RAID_DAYS"] == 0
        if raid_today:
            enemies = p["BASE_ENEMIES"] + day * p["ENEMY_SLOPE"] + p["ENEMY_PER_RANK"] * rank
            if is_final:
                enemies *= p["FINAL_MULT"]
            if p.get("RELEASE_MODE", "none") == "release" and (is_siege or is_final):
                strat = p.get("CAPTIVE_STRATEGY", "nursery")
                summon_cost = p["SUMMON_COST"]
                if strat == "mixed":
                    target = cap_pop * p["MIXED_TARGET_FRAC"]
                    safety = 0
                    while pop < target and pop < cap_pop and safety < 200:
                        safety += 1
                        if faith < summon_cost:
                            usable = captives - human_captives
                            if usable >= 1.0:
                                faith += p["SACRIFICE_FAITH"]
                                cum += p["SACRIFICE_FAITH"]
                                captives -= 1.0
                            else:
                                break
                        if faith >= summon_cost:
                            pop += p["SUMMON_POP"]
                            faith -= summon_cost
                elif strat == "sacrifice":
                    usable = max(0.0, captives - human_captives)
                    if usable > 0:
                        gained_f = usable * p["SACRIFICE_FAITH"]
                        faith += gained_f
                        cum += gained_f
                        captives -= usable
                    while faith >= summon_cost and pop < cap_pop:
                        pop += p["SUMMON_POP"]
                        faith -= summon_cost
                else:
                    while faith >= summon_cost and pop < cap_pop:
                        pop += p["SUMMON_POP"]
                        faith -= summon_cost
                    usable = max(0.0, captives - human_captives)
                    if usable > 0:
                        burst = usable * p["CAPTIVE_BURST"]
                        pop += burst
                        captives -= burst
            fighters = pop
            faith_avail = faith
            if p.get("HOARD_MODE", "spend") == "hoard" and is_siege:
                faith_avail = 0.0
            gA, _, _, _ = simulate_raid(enemies, fighters, 0.0, p, allow_aoe=is_final)
            gB, _, casts, faith2 = simulate_raid(
                enemies, fighters, faith_avail, p, allow_aoe=is_final
            )
            faith_after = (
                faith2
                if (faith_avail > 0 or not (p.get("HOARD_MODE", "spend") == "hoard" and is_siege))
                else faith
            )
            lose_A, win_B = gA <= 0, gB > 0
            narrow_B = win_B and gB <= fighters * 0.5
            if lose_A and narrow_B:
                cond2.append(day)
            if is_final:
                final_win = win_B
            phase = "FINAL" if is_final else ("siege" if is_siege else "norm")
            log.append(
                {
                    "day": day,
                    "phase": phase,
                    "rank": rank,
                    "enemy": int(enemies),
                    "pop": round(pop, 1),
                    "gA": round(gA, 1),
                    "gB": round(gB, 1),
                    "casts": casts,
                    "faith": round(faith),
                    "captives": round(captives, 1),
                }
            )
            pre = fighters
            pop = gB
            faith = faith_after
            if win_B:
                captives += p["BIG_RAID_CAPTIVE_GAIN"]
                human_captives += p["BIG_RAID_CAPTIVE_GAIN"] * p["HUMAN_CAPTIVE_FRAC"]
            if pre > 0:
                loss_frac = (pre - pop) / pre
                if loss_frac >= p["SURGE_TRIGGER"]:
                    surge = min(p["SURGE_MAX"], surge + loss_frac * p["SURGE_GAIN"])
            pop_min = min(pop_min, pop)
            pop_max = max(pop_max, pop)
    return {
        "finalWin": final_win,
        "cond2": cond2,
        "log": log,
        "popMin": round(pop_min, 4),
        "popMax": round(pop_max, 4),
        "captives": round(captives, 4),
    }


# base 辞書は params.ts と同一
base = {
    "SPELL_COST": 60.0, "SPELL_DAMAGE": 8.0, "RAID_INTERVAL": 30.0,
    "BASE_ENEMIES": 6, "ENEMY_SLOPE": 0.5, "GOBLIN_POWER": 0.5, "ENEMY_POWER": 0.4,
    "START_GOBLINS": 10, "START_CAP_POP": 14.0,
    "FAITH_PER_SHAMAN": 1.0, "BASE_CAP": 60.0, "RANK_THRESHOLDS": [120, 300, 540, 840],
    "CAP_PER_RANK": 40.0, "ENEMY_PER_RANK": 3.0,
    "EXPAND_PER_LABOR": 0.05, "BREED_PER_LABOR": 0.20,
    "CAP_POP_MAX": 40.0, "DEATH_RATE": 0.15,
    "SHAMAN_MODE": "max", "SHAMAN_RATIO": 0.3,
    "SURGE_TRIGGER": 0.25, "SURGE_GAIN": 2.0, "SURGE_MAX": 1.5, "SURGE_DECAY": 0.20,
    "BIG_RAID_DAYS": 3, "BIG_RAID_CAPTIVE_GAIN": 2.0,
    "SMALL_PROB": 0.5, "SMALL_LOSS_FRAC": 0.03,
    "SMALL_FOOD_ONLY": 0.35, "SMALL_CAPTIVE_ONLY": 0.25,
    "FOOD_GAIN": 0.15, "FOOD_BUFF_MAX": 0.6, "FOOD_DECAY": 0.10,
    "CAPTIVE_GAIN": 1.0, "NURSERY_RATE": 0.08, "CAPTIVE_CONSUME": 0.3,
    "SMALL_REWARD_SCALE": 1.0,
    "FINAL_DAY": 30, "SIEGE_LEN": 6, "SIEGE_INTERVAL": 1, "FINAL_MULT": 2.5,
    "HOARD_MODE": "spend", "RELEASE_MODE": "none",
    "SUMMON_COST": 20.0, "SUMMON_POP": 2.0, "CAPTIVE_BURST": 0.6,
    "PURGE_COST": 40.0, "PURGE_FRAC": 0.35, "WARD_COST": 30.0, "WARD_REDUCE": 0.5,
    "CAPTIVE_STRATEGY": "nursery", "MIXED_TARGET_FRAC": 0.8,
    "SACRIFICE_FAITH": 15.0, "HUMAN_CAPTIVE_FRAC": 0.0, "SEED": 0,
}


def scenarios():
    """照合シナリオ集 (TS と同一セットを走らせる)。"""
    out = {}
    # A: 詳細ログ相当 (ratio, spend, siege=2, release, mixed)
    a = dict(base)
    a["SHAMAN_MODE"] = "ratio"; a["SIEGE_INTERVAL"] = 2
    a["RELEASE_MODE"] = "release"; a["CAPTIVE_STRATEGY"] = "mixed"
    out["A_detail"] = run_campaign(a, days=a["FINAL_DAY"])
    # B: 既定 (max, none, nursery) 複数シード
    for seed in range(4):
        b = dict(base); b["SEED"] = seed
        out[f"B_base_s{seed}"] = run_campaign(b, days=30)
    # C: nursery release ratio
    for seed in range(4):
        c = dict(base); c["SHAMAN_MODE"] = "ratio"; c["RELEASE_MODE"] = "release"
        c["SIEGE_INTERVAL"] = 2; c["SEED"] = seed
        out[f"C_rel_s{seed}"] = run_campaign(c, days=30)
    return out


if __name__ == "__main__":
    print(json.dumps(scenarios(), ensure_ascii=False))
