/**
 * 中心サイクル (§3 信仰経済 ⇄ §2.5 頭数力学) の集計モデル パラメータ。
 *
 * これは個体エージェント (§5) ではなく、GDD §12 / known_issues の
 * 机上検証 (verify_trinity_cycle_v5.py) が確かめた「マクロな安定帯」を
 * そのまま TS へ移すもの。個体層はこのマクロ層が一致してから被せる。
 *
 * KI-01: 頭数の二段収束 (日常死亡=確率減衰 / 巣立ち=決定キャップ) を必ず持つ。
 * KI-02: 死亡・増殖・巣拡張は「日」単位の事象。tick と混同しない。
 * KI-03: シャーマンは枠使い切りでなく頭数比例 (ratio) を既定にする。
 * KI-04: 損耗時バフ (surge) は安定帯成立の必須骨格。省略不可。
 */

export type ShamanMode = "max" | "ratio";
export type HoardMode = "spend" | "hoard";
export type ReleaseMode = "none" | "release";
export type CaptiveStrategy = "nursery" | "sacrifice" | "mixed";

export interface SimParams {
  // --- 信仰・襲撃の基礎 ---
  SPELL_COST: number;
  SPELL_DAMAGE: number;
  RAID_INTERVAL: number; // tick 数 (3日 × 10tick = 30)
  BASE_ENEMIES: number;
  ENEMY_SLOPE: number;
  GOBLIN_POWER: number;
  ENEMY_POWER: number;
  START_GOBLINS: number;
  START_CAP_POP: number;
  FAITH_PER_SHAMAN: number;
  BASE_CAP: number;
  RANK_THRESHOLDS: number[];
  CAP_PER_RANK: number;
  ENEMY_PER_RANK: number;
  EXPAND_PER_LABOR: number;
  BREED_PER_LABOR: number;
  CAP_POP_MAX: number; // [KI-01修正2] 巣規模の硬い上限
  DEATH_RATE: number; // [KI-01修正1] 日常死亡率 (1日あたり)

  // --- シャーマン配分 (KI-03) ---
  SHAMAN_MODE: ShamanMode;
  SHAMAN_RATIO: number;

  // --- 損耗時バフ (KI-04: 必須骨格) ---
  SURGE_TRIGGER: number; // 損耗割合がこれを超えると発火 (変化率ベース)
  SURGE_GAIN: number;
  SURGE_MAX: number;
  SURGE_DECAY: number;

  // --- 二層襲撃 (KI-05) ---
  BIG_RAID_DAYS: number;
  BIG_RAID_CAPTIVE_GAIN: number;
  SMALL_PROB: number;
  SMALL_LOSS_FRAC: number;
  SMALL_FOOD_ONLY: number;
  SMALL_CAPTIVE_ONLY: number;
  FOOD_GAIN: number;
  FOOD_BUFF_MAX: number;
  FOOD_DECAY: number;
  CAPTIVE_GAIN: number;
  NURSERY_RATE: number;
  CAPTIVE_CONSUME: number;
  SMALL_REWARD_SCALE: number;

  // --- ラストバトル (KI-06) ---
  FINAL_DAY: number;
  SIEGE_LEN: number;
  SIEGE_INTERVAL: number;
  FINAL_MULT: number;
  HOARD_MODE: HoardMode;

  // --- 備え放出 (KI-06: 召喚 / 苗床緊急投下) ---
  RELEASE_MODE: ReleaseMode;
  SUMMON_COST: number;
  SUMMON_POP: number;
  CAPTIVE_BURST: number;

  // --- 特大戦の範囲奇跡 (KI-06) ---
  PURGE_COST: number;
  PURGE_FRAC: number;
  WARD_COST: number;
  WARD_REDUCE: number;

  // --- 捕虜の生贄出口 / 戦略 (KI-07) ---
  CAPTIVE_STRATEGY: CaptiveStrategy;
  MIXED_TARGET_FRAC: number;
  SACRIFICE_FAITH: number;
  HUMAN_CAPTIVE_FRAC: number; // 人間捕虜の割合 (中立ルートでは生贄/苗床不可 §13)

  SEED: number;
}

/** verify_trinity_cycle_v5.py の base 辞書と同一の既定値。 */
export const baseParams: SimParams = {
  SPELL_COST: 60.0,
  SPELL_DAMAGE: 8.0,
  RAID_INTERVAL: 30.0,
  BASE_ENEMIES: 6,
  ENEMY_SLOPE: 0.5,
  GOBLIN_POWER: 0.5,
  ENEMY_POWER: 0.4,
  START_GOBLINS: 10,
  START_CAP_POP: 14.0,
  FAITH_PER_SHAMAN: 1.0,
  BASE_CAP: 60.0,
  RANK_THRESHOLDS: [120, 300, 540, 840],
  CAP_PER_RANK: 40.0,
  ENEMY_PER_RANK: 3.0,
  EXPAND_PER_LABOR: 0.05,
  BREED_PER_LABOR: 0.2,
  CAP_POP_MAX: 40.0,
  DEATH_RATE: 0.15,
  SHAMAN_MODE: "max",
  SHAMAN_RATIO: 0.3,
  SURGE_TRIGGER: 0.25,
  SURGE_GAIN: 2.0,
  SURGE_MAX: 1.5,
  SURGE_DECAY: 0.2,
  BIG_RAID_DAYS: 3,
  BIG_RAID_CAPTIVE_GAIN: 2.0,
  SMALL_PROB: 0.5,
  SMALL_LOSS_FRAC: 0.03,
  SMALL_FOOD_ONLY: 0.35,
  SMALL_CAPTIVE_ONLY: 0.25,
  FOOD_GAIN: 0.15,
  FOOD_BUFF_MAX: 0.6,
  FOOD_DECAY: 0.1,
  CAPTIVE_GAIN: 1.0,
  NURSERY_RATE: 0.08,
  CAPTIVE_CONSUME: 0.3,
  SMALL_REWARD_SCALE: 1.0,
  FINAL_DAY: 30,
  SIEGE_LEN: 6,
  SIEGE_INTERVAL: 1,
  FINAL_MULT: 2.5,
  HOARD_MODE: "spend",
  RELEASE_MODE: "none",
  SUMMON_COST: 20.0,
  SUMMON_POP: 2.0,
  CAPTIVE_BURST: 0.6,
  PURGE_COST: 40.0,
  PURGE_FRAC: 0.35,
  WARD_COST: 30.0,
  WARD_REDUCE: 0.5,
  CAPTIVE_STRATEGY: "nursery",
  MIXED_TARGET_FRAC: 0.8,
  SACRIFICE_FAITH: 15.0,
  HUMAN_CAPTIVE_FRAC: 0.0,
  SEED: 0,
};
