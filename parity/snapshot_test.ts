/**
 * スナップショット往復テスト (KI-09)。
 *
 * 「途中の日で state を保存 → 別オブジェクトに復元 → 以降を進める」と、
 * 「中断せず通しで進める」が、完全に一致することを確認する。
 * RNG 内部状態 (state.rng) まで保存しているので一致するはず。
 *
 * KI-09 はこれを骨格段階 (状態変数が少ないうち) に確立し、
 * 以降フラグが増えるたびに state へ足すだけにせよ、と指定している。
 */
import { baseParams, type SimParams } from "../src/sim/params.ts";
import { initState, step, type SimState } from "../src/sim/cycle.ts";

function cloneState(s: SimState): SimState {
  // セーブ相当: JSON 経由の完全な値コピー (参照を断つ)。
  return JSON.parse(JSON.stringify(s)) as SimState;
}

function runStraight(p: SimParams, days: number): SimState {
  let s = initState(p);
  for (let d = 0; d < days; d++) s = step(s, p).state;
  return s;
}

function runWithSaveLoad(p: SimParams, days: number, saveAt: number): SimState {
  let s = initState(p);
  for (let d = 0; d < saveAt; d++) s = step(s, p).state;
  // ここでセーブ → ロード (途中の日で中断復帰を模す)
  const saved = cloneState(s);
  let resumed = cloneState(saved);
  for (let d = saveAt; d < days; d++) resumed = step(resumed, p).state;
  return resumed;
}

function statesEqual(a: SimState, b: SimState): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function main() {
  const scenarios: Array<{ name: string; p: SimParams }> = [
    { name: "base", p: { ...baseParams } },
    {
      name: "ratio+release+mixed",
      p: {
        ...baseParams,
        SHAMAN_MODE: "ratio",
        RELEASE_MODE: "release",
        CAPTIVE_STRATEGY: "mixed",
        SIEGE_INTERVAL: 2,
      },
    },
    { name: "seed7", p: { ...baseParams, SEED: 7 } },
  ];

  let allOk = true;
  const days = 30;
  for (const { name, p } of scenarios) {
    const straight = runStraight(p, days);
    // 複数の中断ポイントで検査
    for (const saveAt of [1, 9, 15, 23, 29]) {
      const sl = runWithSaveLoad(p, days, saveAt);
      const ok = statesEqual(straight, sl);
      if (!ok) {
        allOk = false;
        console.log(`DIFF ${name} saveAt=${saveAt}`);
        console.log("  straight:", JSON.stringify(straight));
        console.log("  saveload:", JSON.stringify(sl));
      }
    }
    console.log(`${name}: snapshot round-trip checked`);
  }
  console.log(allOk ? "SNAPSHOT_ROUNDTRIP_OK" : "SNAPSHOT_ROUNDTRIP_FAIL");
  if (!allOk) process.exit(1);
}

main();
