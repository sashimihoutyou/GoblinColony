/**
 * ダッシュボードのスモークテスト (ブラウザなし)。
 *
 * ビルド済み HTML (viz/goblin_colony_dashboard.html) から <script> を抜き出し、
 * 最小限の DOM スタブ上で実行して数日ぶん回す。可視化ロジックの
 * ReferenceError・未定義 API 呼び出し・無限 NaN などを CI 相当で検出する。
 * 描画の見た目は検証しない (それはブラウザで行う)。
 *
 * 実行: npm run build && node viz/dashboard_smoke.mjs  →  DASHBOARD_SMOKE_OK
 */
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("./goblin_colony_dashboard.html", import.meta.url), "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
if (scripts.length < 2) {
  console.error("DASHBOARD_SMOKE_FAIL: script ブロックが見つからない (build 済みか?)");
  process.exit(1);
}

// ── 最小 DOM スタブ ──
const noop = () => {};
function stubCtx() {
  const grad = { addColorStop: noop };
  return new Proxy(
    { createRadialGradient: () => grad, createLinearGradient: () => grad, measureText: () => ({ width: 0 }) },
    { get: (t, k) => (k in t ? t[k] : noop), set: () => true }
  );
}
const elements = new Map();
function el(id) {
  if (!elements.has(id)) {
    const e = {
      id,
      width: 680,
      height: 380,
      innerHTML: "",
      textContent: "",
      style: {},
      dataset: {},
      classList: { add: noop, remove: noop, contains: () => false },
      addEventListener: noop,
      getContext: () => stubCtx(),
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 680, height: 380 }),
    };
    elements.set(id, e);
  }
  return elements.get(id);
}
let rafCb = null;
let anonId = 0;
const documentStub = {
  getElementById: el,
  // オフスクリーンキャンバス (背景描画) 用。毎回新しい要素を返す。
  createElement: () => el(`__anon${anonId++}`),
  querySelectorAll: () => [],
  addEventListener: noop,
  hidden: false,
  body: { innerHTML: "" },
};

// 実時間を完全に制御する (TickDriver は performance.now を読む)。
let fakeNow = 0;
globalThis.performance = { now: () => fakeNow };
globalThis.document = documentStub;
globalThis.window = globalThis;
globalThis.requestAnimationFrame = (cb) => { rafCb = cb; };

// ── コアバンドル + 可視化スクリプトを実行 ──
for (const src of scripts) {
  (0, eval)(src);
}
if (!globalThis.GoblinSim) {
  console.error("DASHBOARD_SMOKE_FAIL: GoblinSim が公開されていない");
  process.exit(1);
}
if (!rafCb) {
  console.error("DASHBOARD_SMOKE_FAIL: メインループが起動していない");
  process.exit(1);
}

// ── フレームを回す: 100ms × 2600 = 実時間 260 秒 ≒ 4 日ちょい ──
let frames = 0;
try {
  for (let i = 0; i < 2600; i++) {
    fakeNow += 100;
    const cb = rafCb;
    rafCb = null;
    cb(fakeNow);
    frames++;
    if (!rafCb) throw new Error("ループが再スケジュールされなかった");
  }
} catch (err) {
  console.error(`DASHBOARD_SMOKE_FAIL: frame ${frames} で例外:`, err);
  process.exit(1);
}

// ── 事後検証: HUD が進み、ログと分布が描かれている ──
const day = parseInt(el("day").textContent, 10);
const logHtml = el("log").innerHTML;
const statesHtml = el("states").innerHTML;
const checks = [
  [Number.isFinite(day) && day >= 4, `日が進む (day=${el("day").textContent})`],
  [logHtml.includes("log-entry"), "記録フィードが描画される"],
  [statesHtml.includes("state-row"), "ステート分布が描画される"],
  [el("s-pop").textContent !== "0", `頭数が表示される (pop=${el("s-pop").textContent})`],
  [!el("meters").innerHTML.includes("NaN"), "メーターに NaN が出ない"],
];
let failed = 0;
for (const [ok, name] of checks) {
  console.log(`${ok ? "OK  " : "FAIL"} ${name}`);
  if (!ok) failed++;
}
console.log(failed === 0 ? "DASHBOARD_SMOKE_OK" : `DASHBOARD_SMOKE_FAIL(${failed})`);
process.exit(failed === 0 ? 0 : 1);
