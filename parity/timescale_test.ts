/**
 * tick 解像度変換のテスト (KI-02: tick/day を混同しない)。
 *
 * 力学定数は基準解像度 (TICKS_PER_DAY_BASE=10) で校正されている。
 * makeWorldParams(ticksPerDay) が別解像度でも「日単位のレート・所要日数」を
 * 不変に保つこと、および基準解像度では恒等であることを機械的に確認する。
 * 可視化 (1 日 = 実 60 秒 / ticksPerDay=120) はこの変換に依存する。
 */
import {
  makeWorldParams,
  scaleStateMachineParams,
  TICKS_PER_DAY_BASE,
} from "../src/sim/world_params.ts";
import { defaultStateMachineParams } from "../src/sim/state_machine.ts";
import { initWorld, stepWorld, beginRaid, livePop } from "../src/sim/world.ts";

let failures = 0;
function check(name: string, cond: boolean, detail = "") {
  console.log(`${cond ? "OK  " : "FAIL"} ${name}${detail ? "  " + detail : ""}`);
  if (!cond) failures++;
}
const close = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

// --- 1. 基準解像度では恒等 (既存の検証帯と同じ値が出る) ---
{
  const p = makeWorldParams(TICKS_PER_DAY_BASE);
  const sm = defaultStateMachineParams;
  check(
    "基準解像度で sm が既定値と一致 (恒等変換)",
    p.sm.hungerRate === sm.hungerRate &&
      p.sm.sleepRate === sm.sleepRate &&
      p.sm.hpRegenPerTick === sm.hpRegenPerTick &&
      p.sm.fearClearTicks === sm.fearClearTicks &&
      p.sm.uniqueDownedGraceTicks === sm.uniqueDownedGraceTicks
  );
  check(
    "基準解像度で求愛系の per-tick 値が校正値と一致",
    close(p.courtBaseChance, 0.08) &&
      close(p.matedCourtBonus, 0.3) &&
      close(p.rivalryChance, 0.05) &&
      p.matingDurationTicks === 3
  );
}

// --- 2. 日単位レートの不変性: per-tick レート × ticksPerDay が解像度に依らない ---
{
  const base = makeWorldParams(TICKS_PER_DAY_BASE);
  for (const tpd of [60, 120, 240]) {
    const p = makeWorldParams(tpd);
    const ratesOk =
      close(p.deathPerTick * tpd, base.deathPerTick * TICKS_PER_DAY_BASE) &&
      close(p.pregnancyChancePerFemale * tpd, base.pregnancyChancePerFemale * TICKS_PER_DAY_BASE) &&
      close(p.courtBaseChance * tpd, base.courtBaseChance * TICKS_PER_DAY_BASE) &&
      close(p.matedCourtBonus * tpd, base.matedCourtBonus * TICKS_PER_DAY_BASE) &&
      close(p.favoriteCourtBonus * tpd, base.favoriteCourtBonus * TICKS_PER_DAY_BASE) &&
      close(p.rivalryChance * tpd, base.rivalryChance * TICKS_PER_DAY_BASE) &&
      close(p.captiveBondChance * tpd, base.captiveBondChance * TICKS_PER_DAY_BASE) &&
      close(p.maleCaptiveJoinChancePerTick * tpd, base.maleCaptiveJoinChancePerTick * TICKS_PER_DAY_BASE) &&
      close(p.faithPerTickPerShaman * tpd, base.faithPerTickPerShaman * TICKS_PER_DAY_BASE) &&
      close(p.sm.hungerRate * tpd, base.sm.hungerRate * TICKS_PER_DAY_BASE) &&
      close(p.sm.sleepRate * tpd, base.sm.sleepRate * TICKS_PER_DAY_BASE) &&
      close(p.sm.hpRegenPerTick * tpd, base.sm.hpRegenPerTick * TICKS_PER_DAY_BASE) &&
      close(p.sm.hungerRelievePerTick * tpd, base.sm.hungerRelievePerTick * TICKS_PER_DAY_BASE) &&
      close(p.sm.sleepRelievePerTick * tpd, base.sm.sleepRelievePerTick * TICKS_PER_DAY_BASE);
    check(`tpd=${tpd}: 日次レートが不変`, ratesOk);

    // 所要時間 (tick 数) は日数で見て不変。丸めぶんの許容は 1 tick。
    const durOk =
      close(p.matingDurationTicks / tpd, base.matingDurationTicks / TICKS_PER_DAY_BASE, 1 / tpd) &&
      close(p.sm.fearClearTicks / tpd, base.sm.fearClearTicks / TICKS_PER_DAY_BASE, 1 / tpd) &&
      close(p.sm.uniqueDownedGraceTicks / tpd, base.sm.uniqueDownedGraceTicks / TICKS_PER_DAY_BASE, 1 / tpd) &&
      p.pregnancyTicks === tpd &&
      p.childGrowTicks === tpd &&
      p.nurseryPeriodTicks === tpd * 2 &&
      p.fledgeGraceTicks === tpd;
    check(`tpd=${tpd}: 所要日数が不変`, durOk);
  }
}

// --- 3. scaleStateMachineParams: 閾値は不変、レートのみ変換 ---
{
  const scaled = scaleStateMachineParams(defaultStateMachineParams, 12);
  const sm = defaultStateMachineParams;
  check(
    "閾値 (比率) は変換で不変",
    scaled.hungerOn === sm.hungerOn &&
      scaled.hungerOff === sm.hungerOff &&
      scaled.sleepOn === sm.sleepOn &&
      scaled.sleepOff === sm.sleepOff &&
      scaled.fearHpFrac === sm.fearHpFrac &&
      scaled.dyingHpFrac === sm.dyingHpFrac
  );
  check("レートは 1/scale、猶予 tick は ×scale",
    close(scaled.hungerRate * 12, sm.hungerRate) &&
    scaled.fearClearTicks === sm.fearClearTicks * 12);
}

// --- 4. 可視化解像度 (tpd=120) の挙動スモーク: 平時の安定帯に乗る ---
// 完全一致は粒度差で不可能 (KI-12 と同種) なので、「全滅せず育つ」帯を確認する。
{
  let allSurvive = true;
  const finals: number[] = [];
  for (const seed of [1, 2, 3]) {
    const p = makeWorldParams(120);
    let w = initWorld(p, { startGoblins: 10, capPop: 24, seed, withChief: true });
    let minPop = Infinity;
    for (let d = 0; d < 15; d++) {
      for (let i = 0; i < p.ticksPerDay; i++) w = stepWorld(w, p);
      minPop = Math.min(minPop, livePop(w));
    }
    if (minPop <= 0) allSurvive = false;
    finals.push(livePop(w));
  }
  const avg = finals.reduce((a, b) => a + b, 0) / finals.length;
  check("tpd=120 の平時 15 日で全滅しない", allSurvive);
  check("tpd=120 でも頭数が育つ帯に乗る (avg >= 8)", avg >= 8, `avg=${avg.toFixed(1)}`);
}

// --- 5. 可視化解像度 (tpd=120) で戦闘が有限 tick で決着する ---
{
  const p = makeWorldParams(120);
  let w = initWorld(p, { startGoblins: 20, capPop: 99, seed: 5, withChief: true });
  w = beginRaid(w, 12);
  let t = 0;
  while (w.phase === "combat" && t < 2000) {
    w = stepWorld(w, p);
    t++;
  }
  check("tpd=120 で戦闘が決着し平時へ戻る", w.phase === "peace", `ticks=${t}`);
  check("撃退後も生存者がいる", livePop(w) > 0, `pop=${livePop(w)}`);
}

console.log(failures === 0 ? "TIMESCALE_OK" : `TIMESCALE_FAIL(${failures})`);
if (failures > 0) process.exit(1);
