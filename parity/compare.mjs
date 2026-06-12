// Python ↔ TS パリティ照合ハーネス (KI 横断: 力学を共有せよ)。
//
// parity/cycle.py --trace (Python 版 src/sim/cycle.ts 相当) と
// parity/cycle_ts.ts (TS 版本体) を同一シード・同一シナリオで実行し、
// 全シナリオ・全日・全フィールドが完全一致するか machine 的に検証する。
//
// 一致すれば ALL_MATCH を出力して終了 (exit 0)。
// 不一致なら最初の相違点 (シナリオ/日/フィールド/両値) を表示して非ゼロ終了。
import { spawnSync } from "node:child_process";

function runPython() {
  const r = spawnSync("python3", ["parity/cycle.py", "--trace"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) {
    if (r.error.code === "ENOENT") {
      console.error("python3 が見つかりません。Python 側の照合をスキップできません。");
    }
    throw r.error;
  }
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`parity/cycle.py --trace が exit ${r.status} で終了しました`);
  }
  return JSON.parse(r.stdout);
}

function runTs() {
  const r = spawnSync(
    process.execPath,
    ["--experimental-transform-types", "parity/cycle_ts.ts"],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  );
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`parity/cycle_ts.ts が exit ${r.status} で終了しました`);
  }
  return JSON.parse(r.stdout);
}

/** 数値は完全一致 (===) を要求する。NaN 同士は一致扱い。 */
function valuesEqual(a, b) {
  if (typeof a === "number" && typeof b === "number") {
    if (Number.isNaN(a) && Number.isNaN(b)) return true;
    return a === b;
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((v, i) => valuesEqual(v, b[i]));
  }
  return a === b;
}

function main() {
  const py = runPython();
  const ts = runTs();

  const pyNames = Object.keys(py);
  const tsNames = Object.keys(ts);
  if (pyNames.length !== tsNames.length || pyNames.some((n, i) => n !== tsNames[i])) {
    console.error("シナリオ集合が一致しません:");
    console.error("  python:", pyNames);
    console.error("  ts    :", tsNames);
    process.exit(1);
  }

  let total = 0;
  for (const name of pyNames) {
    const pyDays = py[name];
    const tsDays = ts[name];
    if (pyDays.length !== tsDays.length) {
      console.error(`シナリオ ${name}: 日数が一致しません (python=${pyDays.length}, ts=${tsDays.length})`);
      process.exit(1);
    }
    for (let i = 0; i < pyDays.length; i++) {
      const pd = pyDays[i];
      const td = tsDays[i];
      const fields = new Set([...Object.keys(pd), ...Object.keys(td)]);
      for (const field of fields) {
        const pv = pd[field];
        const tv = td[field];
        total++;
        if (!valuesEqual(pv, tv)) {
          console.error("MISMATCH");
          console.error(`  scenario : ${name}`);
          console.error(`  day      : ${pd.day ?? i + 1}`);
          console.error(`  field    : ${field}`);
          console.error(`  python   : ${JSON.stringify(pv)}`);
          console.error(`  ts       : ${JSON.stringify(tv)}`);
          process.exit(1);
        }
      }
    }
  }

  console.log(`checked ${pyNames.length} scenarios, ${total} field comparisons`);
  console.log("ALL_MATCH");
}

main();
