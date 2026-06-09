/**
 * 中心サイクル集計モデルの本体 (verify_trinity_cycle_v5.py の移植)。
 *
 * 構造: 単一の state を、副作用のない step で 1 日進める。
 *   - これにより state をそのままスナップショット保存できる (KI-09)。
 *   - 描画なしでヘッドレスに回せる (§14.5.4 自動プレイヤー夜間バッチ)。
 *   - Python 検証コードと同じ入出力契約を持ち、力学一致を照合できる。
 *
 * 乱数は共有 Rng (xorshift128) を使い、消費順序を Python 版と厳密に揃える。
 * 元の検証は Python 標準 random だったが、本実装は KI-09 のため決定的 Rng に
 * 統一する。照合用 Python (parity/cycle.py) も同じ Rng を使う。
 */
import { Rng, type RngState } from "./rng.ts";
import type { SimParams } from "./params.ts";

export type Phase = "norm" | "siege" | "FINAL";

/** シミュレーション全状態。これ一つを保存すれば中断復帰できる (KI-09)。 */
export interface SimState {
  day: number;
  pop: number;
  capPop: number;
  faith: number;
  cum: number; // 累計信仰 (ランク判定用・減らない §3)
  surge: number; // 損耗時バフ残量 (§2.5)
  foodBuff: number; // 小規模襲撃の食料バフ
  captives: number; // 捕虜プール
  humanCaptives: number; // うち人間 (生贄/苗床不可 §13)
  fledgeTotal: number; // 巣立ち累計
  popMin: number;
  popMax: number;
  rng: RngState; // RNG 内部状態 (KI-09: 必ず保存対象)
  finalWin: boolean | null;
  cond2: number[]; // 辛勝した日のリスト (検証指標)
}

export interface RaidLogEntry {
  day: number;
  phase: Phase;
  rank: number;
  enemy: number;
  pop: number;
  gA: number; // 奇跡なしの残存戦力
  gB: number; // 奇跡ありの残存戦力
  casts: number;
  faith: number;
  captives: number;
}

export function rankFromCumulative(cum: number, thresholds: number[]): number {
  let r = 0;
  for (const t of thresholds) {
    if (cum >= t) r += 1;
    else break;
  }
  return r;
}

interface RaidResult {
  g: number;
  e: number;
  casts: number;
  faith: number;
}

/**
 * 1 回の襲撃を簡易ランチェスターで解く。
 * allowAoe=true (特大戦) は頭数の殴り合いでなく範囲奇跡で受ける (KI-06)。
 */
function simulateRaid(
  enemies: number,
  fighters: number,
  faithIn: number,
  p: SimParams,
  allowAoe: boolean
): RaidResult {
  const gp = p.GOBLIN_POWER;
  let ep = p.ENEMY_POWER;
  const cost = p.SPELL_COST;
  const dmg = p.SPELL_DAMAGE;
  let g = fighters;
  let e = enemies;
  let casts = 0;
  let faith = faithIn;

  if (allowAoe) {
    // 範囲殲滅を撃てるだけ撃つ (敵を割合削減)
    while (faith >= p.PURGE_COST && e > g) {
      e *= 1.0 - p.PURGE_FRAC;
      faith -= p.PURGE_COST;
      casts += 1;
    }
    // 防御 (泥の抱擁) を 1 枚張れれば被ダメ低減
    if (faith >= p.WARD_COST) {
      ep *= 1.0 - p.WARD_REDUCE;
      faith -= p.WARD_COST;
      casts += 1;
    }
  }

  for (let i = 0; i < 1000; i++) {
    if (g <= 0 || e <= 0) break;
    if (faith >= cost && e > g) {
      e -= dmg;
      faith -= cost;
      casts += 1;
      if (e <= 0) break;
    }
    const de = g * gp;
    const dg = e * ep;
    e -= de;
    g -= dg;
  }
  return { g: Math.max(g, 0), e: Math.max(e, 0), casts, faith };
}

/** 初期状態を生成。 */
export function initState(p: SimParams): SimState {
  const rng = new Rng(p.SEED);
  return {
    day: 0,
    pop: p.START_GOBLINS,
    capPop: p.START_CAP_POP,
    faith: 0,
    cum: 0,
    surge: 0,
    foodBuff: 0,
    captives: 0,
    humanCaptives: 0,
    fledgeTotal: 0,
    popMin: p.START_GOBLINS,
    popMax: p.START_GOBLINS,
    rng: rng.snapshot(),
    finalWin: null,
    cond2: [],
  };
}

/**
 * 1 日進める純粋 step。state を変更せず新しい state を返す。
 * 襲撃が起きた日は log エントリも返す。
 */
export function step(
  prev: SimState,
  p: SimParams
): { state: SimState; log: RaidLogEntry | null } {
  // state を複製 (純粋性のため)。配列もコピー。
  const s: SimState = {
    ...prev,
    rng: [...prev.rng] as RngState,
    cond2: [...prev.cond2],
  };
  const rng = new Rng(0);
  rng.restore(s.rng);

  const day = s.day + 1;
  s.day = day;
  const RI = p.RAID_INTERVAL;
  const RAID_INTERVAL_DAYS = 3;

  const rank = rankFromCumulative(s.cum, p.RANK_THRESHOLDS);

  // シャーマン配分 (KI-03)
  const slot = 1 + rank;
  let shamans: number;
  if (p.SHAMAN_MODE === "ratio") {
    shamans = Math.min(slot, Math.floor(s.pop * p.SHAMAN_RATIO), Math.floor(s.pop));
  } else {
    shamans = Math.min(slot, Math.floor(s.pop));
  }
  shamans = Math.max(shamans, 0);
  const labor = Math.max(s.pop - shamans, 0);

  // 信仰蓄積 (日次)
  const faithPerDay = shamans * p.FAITH_PER_SHAMAN * (RI / RAID_INTERVAL_DAYS);
  s.cum += faithPerDay;
  const cap = p.BASE_CAP + p.CAP_PER_RANK * rank;
  s.faith = Math.min(s.faith + faithPerDay, cap);

  // 巣拡張 (逓減つき / KI-01修正2)
  const head = Math.max(0.0, 1.0 - s.capPop / p.CAP_POP_MAX);
  s.capPop += labor * p.EXPAND_PER_LABOR * head;

  // 日常死亡 + 自然増 + 苗床 + バフ減衰 + 小規模襲撃 (D=1日精度)
  s.pop -= s.pop * p.DEATH_RATE; // 事故死
  const breedMult = 1.0 + s.surge + s.foodBuff;
  s.pop += labor * p.BREED_PER_LABOR * breedMult; // 出産

  // 捕虜の苗床経路 (nursery/mixed のみ)
  if (p.CAPTIVE_STRATEGY === "nursery" || p.CAPTIVE_STRATEGY === "mixed") {
    const usableN = Math.max(0.0, s.captives - s.humanCaptives);
    if (usableN > 0) {
      const born = usableN * p.NURSERY_RATE;
      s.pop += born;
      s.captives = Math.max(s.humanCaptives, s.captives - born * p.CAPTIVE_CONSUME);
    }
  }
  s.surge = Math.max(0.0, s.surge - p.SURGE_DECAY);
  s.foodBuff = Math.max(0.0, s.foodBuff - p.FOOD_DECAY);

  // 小規模襲撃 (乱数消費: まず発生判定、起きたら報酬分岐で 1 回)
  if (rng.nextFloat() < p.SMALL_PROB) {
    s.pop -= s.pop * p.SMALL_LOSS_FRAC;
    const roll = rng.nextFloat();
    const rs = p.SMALL_REWARD_SCALE;
    if (roll < p.SMALL_FOOD_ONLY) {
      s.foodBuff = Math.min(p.FOOD_BUFF_MAX, s.foodBuff + p.FOOD_GAIN * rs);
    } else if (roll < p.SMALL_FOOD_ONLY + p.SMALL_CAPTIVE_ONLY) {
      const g = p.CAPTIVE_GAIN * rs;
      s.captives += g;
      s.humanCaptives += g * p.HUMAN_CAPTIVE_FRAC;
    } else {
      s.foodBuff = Math.min(p.FOOD_BUFF_MAX, s.foodBuff + p.FOOD_GAIN * rs);
      const g = p.CAPTIVE_GAIN * rs;
      s.captives += g;
      s.humanCaptives += g * p.HUMAN_CAPTIVE_FRAC;
    }
    if (s.pop < 0) s.pop = 0;
  }

  // 巣立ち (上限超過分を決定的処理 / KI-01修正3)
  if (s.pop > s.capPop) {
    s.fledgeTotal += s.pop - s.capPop;
    s.pop = s.capPop;
  }
  if (s.pop < 0) s.pop = 0;
  s.popMin = Math.min(s.popMin, s.pop);
  s.popMax = Math.max(s.popMax, s.pop);

  // 終盤フェーズ判定
  const FINAL = p.FINAL_DAY;
  const siegeStart = FINAL - p.SIEGE_LEN;
  const isFinal = day === FINAL;
  const isSiege = siegeStart <= day && day < FINAL;
  let raidToday: boolean;
  if (isFinal) raidToday = true;
  else if (isSiege) raidToday = day % p.SIEGE_INTERVAL === 0;
  else raidToday = day % p.BIG_RAID_DAYS === 0;

  let log: RaidLogEntry | null = null;

  if (raidToday) {
    let enemies = p.BASE_ENEMIES + day * p.ENEMY_SLOPE + p.ENEMY_PER_RANK * rank;
    if (isFinal) enemies *= p.FINAL_MULT;

    // 備え放出 (release のときのみ / KI-06)
    if (p.RELEASE_MODE === "release" && (isSiege || isFinal)) {
      const strat = p.CAPTIVE_STRATEGY;
      const summonCost = p.SUMMON_COST;
      if (strat === "mixed") {
        const target = s.capPop * p.MIXED_TARGET_FRAC;
        let safety = 0;
        while (s.pop < target && s.pop < s.capPop && safety < 200) {
          safety += 1;
          if (s.faith < summonCost) {
            const usable = s.captives - s.humanCaptives;
            if (usable >= 1.0) {
              s.faith += p.SACRIFICE_FAITH;
              s.cum += p.SACRIFICE_FAITH;
              s.captives -= 1.0;
            } else {
              break;
            }
          }
          if (s.faith >= summonCost) {
            s.pop += p.SUMMON_POP;
            s.faith -= summonCost;
          }
        }
      } else if (strat === "sacrifice") {
        const usable = Math.max(0.0, s.captives - s.humanCaptives);
        if (usable > 0) {
          const gainedF = usable * p.SACRIFICE_FAITH;
          s.faith += gainedF;
          s.cum += gainedF;
          s.captives -= usable;
        }
        while (s.faith >= summonCost && s.pop < s.capPop) {
          s.pop += p.SUMMON_POP;
          s.faith -= summonCost;
        }
      } else {
        // nursery
        while (s.faith >= summonCost && s.pop < s.capPop) {
          s.pop += p.SUMMON_POP;
          s.faith -= summonCost;
        }
        const usable = Math.max(0.0, s.captives - s.humanCaptives);
        if (usable > 0) {
          const burst = usable * p.CAPTIVE_BURST;
          s.pop += burst;
          s.captives -= burst;
        }
      }
    }

    const fighters = s.pop;
    let faithAvail = s.faith;
    if (p.HOARD_MODE === "hoard" && isSiege) faithAvail = 0.0;

    const rA = simulateRaid(enemies, fighters, 0.0, p, isFinal);
    const rB = simulateRaid(enemies, fighters, faithAvail, p, isFinal);
    const faithAfter =
      faithAvail > 0 || !(p.HOARD_MODE === "hoard" && isSiege) ? rB.faith : s.faith;

    const loseA = rA.g <= 0;
    const winB = rB.g > 0;
    const narrowB = winB && rB.g <= fighters * 0.5;
    if (loseA && narrowB) s.cond2.push(day);
    if (isFinal) s.finalWin = winB;

    const phase: Phase = isFinal ? "FINAL" : isSiege ? "siege" : "norm";
    log = {
      day,
      phase,
      rank,
      enemy: Math.trunc(enemies),
      pop: round1(s.pop),
      gA: round1(rA.g),
      gB: round1(rB.g),
      casts: rB.casts,
      faith: Math.round(s.faith),
      captives: round1(s.captives),
    };

    const pre = fighters;
    s.pop = rB.g;
    s.faith = faithAfter;
    if (winB) {
      s.captives += p.BIG_RAID_CAPTIVE_GAIN;
      s.humanCaptives += p.BIG_RAID_CAPTIVE_GAIN * p.HUMAN_CAPTIVE_FRAC;
    }
    if (pre > 0) {
      const lossFrac = (pre - s.pop) / pre;
      if (lossFrac >= p.SURGE_TRIGGER) {
        s.surge = Math.min(p.SURGE_MAX, s.surge + lossFrac * p.SURGE_GAIN);
      }
    }
    s.popMin = Math.min(s.popMin, s.pop);
    s.popMax = Math.max(s.popMax, s.pop);
  }

  s.rng = rng.snapshot();
  return { state: s, log };
}

/** キャンペーン全体を回す (検証用ヘルパ)。 */
export function runCampaign(
  p: SimParams,
  days: number
): {
  finalWin: boolean | null;
  cond2: number[];
  log: RaidLogEntry[];
  popMin: number;
  popMax: number;
  captives: number;
} {
  let s = initState(p);
  const log: RaidLogEntry[] = [];
  for (let d = 0; d < days; d++) {
    const r = step(s, p);
    s = r.state;
    if (r.log) log.push(r.log);
  }
  return {
    finalWin: s.finalWin,
    cond2: s.cond2,
    log,
    popMin: s.popMin,
    popMax: s.popMax,
    captives: s.captives,
  };
}

function round1(x: number): number {
  return Math.round(x * 10) / 10;
}
