/**
 * 照合ハーネス: src/sim/cycle.ts を Python 版 (parity/cycle.py --trace) と
 * 同一シード・同一シナリオで回し、日次の state トレースを JSON で stdout へ出す。
 *
 * シナリオ定義は parity/cycle.py の scenario_param_list() と一致させること。
 * 出力形式: { [シナリオ名]: SimState[] } (日次、1 日目から最終日まで)。
 * parity/compare.mjs がこれと Python 側の出力を突き合わせる。
 */
import { baseParams, type SimParams } from "../src/sim/params.ts";
import { initState, step, type SimState } from "../src/sim/cycle.ts";

/** parity/cycle.py の scenario_param_list() と同一のシナリオ集。 */
function scenarioParamList(): Array<{ name: string; p: SimParams; days: number }> {
  const out: Array<{ name: string; p: SimParams; days: number }> = [];

  // A: 詳細ログ相当 (ratio, spend, siege=2, release, mixed)
  const a: SimParams = {
    ...baseParams,
    SHAMAN_MODE: "ratio",
    SIEGE_INTERVAL: 2,
    RELEASE_MODE: "release",
    CAPTIVE_STRATEGY: "mixed",
  };
  out.push({ name: "A_detail", p: a, days: a.FINAL_DAY });

  // B: 既定 (max, none, nursery) 複数シード
  for (let seed = 0; seed < 4; seed++) {
    const b: SimParams = { ...baseParams, SEED: seed };
    out.push({ name: `B_base_s${seed}`, p: b, days: 30 });
  }

  // C: nursery release ratio
  for (let seed = 0; seed < 4; seed++) {
    const c: SimParams = {
      ...baseParams,
      SHAMAN_MODE: "ratio",
      RELEASE_MODE: "release",
      SIEGE_INTERVAL: 2,
      SEED: seed,
    };
    out.push({ name: `C_rel_s${seed}`, p: c, days: 30 });
  }

  return out;
}

function traceScenarios(): Record<string, SimState[]> {
  const out: Record<string, SimState[]> = {};
  for (const { name, p, days } of scenarioParamList()) {
    let s = initState(p);
    const trace: SimState[] = [];
    for (let d = 0; d < days; d++) {
      s = step(s, p).state;
      trace.push(s);
    }
    out[name] = trace;
  }
  return out;
}

console.log(JSON.stringify(traceScenarios()));
