/**
 * TickDriver のテスト (KI-09)。
 * 実時間を注入して決定的に検証する。
 */
import { TickDriver } from "../src/sim/tick_driver.ts";

let failures = 0;
function check(name: string, cond: boolean) {
  console.log(`${cond ? "OK  " : "FAIL"} ${name}`);
  if (!cond) failures++;
}

// 制御可能な擬似時計
function fakeClock() {
  let t = 0;
  return {
    advance: (ms: number) => {
      t += ms;
    },
    now: () => t,
  };
}

// --- 1. 1x で 1 秒経過 → ちょうど ticksPerSecond tick ---
{
  const clk = fakeClock();
  const d = new TickDriver({ ticksPerSecondAt1x: 10, now: clk.now });
  d.pump(); // 初回は lastNow セットのみ (0 tick)
  clk.advance(1000);
  const ticks = d.pump();
  check("1x/1秒 = 10 tick", ticks === 10);
}

// --- 2. 3x は 1x の 3 倍消化 ---
{
  const clk = fakeClock();
  const d = new TickDriver({ ticksPerSecondAt1x: 10, now: clk.now });
  d.setSpeed(3);
  d.pump();
  clk.advance(1000);
  check("3x/1秒 = 30 tick", d.pump() === 30);
}

// --- 3. 停止(0x)は進まない ---
{
  const clk = fakeClock();
  const d = new TickDriver({ ticksPerSecondAt1x: 10, now: clk.now });
  d.setSpeed(0);
  d.pump();
  clk.advance(5000);
  check("停止中は 0 tick", d.pump() === 0);
}

// --- 4. 端数の持ち越し: 細切れの dt でも合計 tick 数は一定 ---
{
  const clk1 = fakeClock();
  const d1 = new TickDriver({ ticksPerSecondAt1x: 10, now: clk1.now });
  d1.pump();
  clk1.advance(1000);
  const oneShot = d1.pump(); // 一括 1 秒

  const clk2 = fakeClock();
  const d2 = new TickDriver({ ticksPerSecondAt1x: 10, now: clk2.now });
  d2.pump();
  let summed = 0;
  for (let i = 0; i < 100; i++) {
    clk2.advance(10); // 10ms × 100 = 1000ms を細切れに
    summed += d2.pump();
  }
  check("細切れでも合計 tick が一括と一致(端数持ち越し)", oneShot === summed && summed === 10);
}

// --- 5. フレームレート非依存: 33ms と 16ms で同じ実時間なら同じ総 tick ---
{
  const total = 3000;
  const sim = (frameMs: number): number => {
    const clk = fakeClock();
    const d = new TickDriver({ ticksPerSecondAt1x: 10, now: clk.now });
    d.pump();
    let acc = 0;
    let elapsed = 0;
    while (elapsed < total) {
      clk.advance(frameMs);
      elapsed += frameMs;
      acc += d.pump();
    }
    return acc;
  };
  // 30fps と 60fps で総 tick が一致 (端数が持ち越されるため)
  check("フレームレート非依存(30fps=60fps の総tick)", sim(33) === sim(16));
}

// --- 6. 暴走防止: 長時間バックグラウンド後の巨大 dt が上限で頭打ち ---
{
  const clk = fakeClock();
  const d = new TickDriver({ ticksPerSecondAt1x: 10, maxTicksPerFrame: 300, now: clk.now });
  d.pump();
  clk.advance(10 * 60 * 1000); // 10 分放置
  const ticks = d.pump();
  check("巨大 dt は maxTicksPerFrame で頭打ち", ticks === 300);
}

// --- 7. resync 後は経過分を破棄 (復帰後 最初の pump で時計合わせ → 次から進む) ---
{
  const clk = fakeClock();
  const d = new TickDriver({ ticksPerSecondAt1x: 10, now: clk.now });
  d.pump();
  clk.advance(5000);
  d.resync(); // ロード/タブ復帰直後を模す
  // 復帰後の最初の pump は lastNow を取り直すだけ (放置中の経過を捨てる)。
  const first = d.pump();
  check("resync 後の最初の pump は 0 (放置分を破棄)", first === 0);
  // 以降は通常どおり進む。
  clk.advance(1000);
  check("resync 後 次フレームから通常進行", d.pump() === 10);
}

console.log(failures === 0 ? "TICKDRIVER_OK" : `TICKDRIVER_FAIL(${failures})`);
if (failures > 0) process.exit(1);
