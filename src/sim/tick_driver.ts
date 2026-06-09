/**
 * tick 駆動層 (TickDriver)。
 *
 * KI-09 の核心: **実時間 (performance.now) を触ってよいのはこの層だけ**。
 * シミュレーションロジック (cycle.ts / 今後の個体層) は実時間を一切見ず、
 * 「何 tick 進めるか」という整数だけを受け取る。これにより:
 *   - 速度倍率 (停止/1x/3x) は「1 実秒あたり何 tick 消化するか」で表現でき、
 *     倍速中でもロジックは同じ step を回すだけなので壊れない (§12/§10)。
 *   - セーブ対象に実時間が混ざらない (§14.5.1 のグローバル状態は tick/day のみ)。
 *
 * この層は「いつ・何 tick 進めるか」を決めるだけで、進め方 (step の中身) は知らない。
 * advance コールバックに tick 数を渡す関心の分離。
 */

export type Speed = 0 | 1 | 3; // 停止 / 1x / 3x (§10 速度コントロール)

/** 1x のとき 1 実秒で消化する tick 数。実数調整対象 (§15 昼長と一体)。 */
export const TICKS_PER_SECOND_AT_1X = 10;

export interface TickDriverOptions {
  /** 1x のときの 1 秒あたり tick 数。既定 TICKS_PER_SECOND_AT_1X。 */
  ticksPerSecondAt1x?: number;
  /** 1 フレームで進める tick 数の上限 (タブ復帰時の暴走を防ぐ)。 */
  maxTicksPerFrame?: number;
  /** 実時間取得関数 (テストで差し替え可能。既定 performance.now)。 */
  now?: () => number;
}

/**
 * 実時間の経過を tick 数へ変換するアキュムレータ。
 * tick 自体は整数で蓄積し、端数 (accumulatorMs) を持ち越すことで
 * フレームレートに依らず一定速度で進む (可変 dt でも tick 数は決定的)。
 */
export class TickDriver {
  private speed: Speed = 1;
  private accumulatorMs = 0;
  private lastNow: number | null = null;
  private readonly msPerTickAt1x: number;
  private readonly maxTicksPerFrame: number;
  private readonly now: () => number;

  constructor(opts: TickDriverOptions = {}) {
    const tps = opts.ticksPerSecondAt1x ?? TICKS_PER_SECOND_AT_1X;
    this.msPerTickAt1x = 1000 / tps;
    this.maxTicksPerFrame = opts.maxTicksPerFrame ?? 300;
    this.now =
      opts.now ??
      (typeof performance !== "undefined"
        ? () => performance.now()
        : () => Date.now());
  }

  setSpeed(speed: Speed): void {
    this.speed = speed;
    // 速度変更時は端数を捨てる (停止→再開で取り残し tick が一気に出るのを防ぐ)。
    if (speed === 0) this.accumulatorMs = 0;
  }

  getSpeed(): Speed {
    return this.speed;
  }

  /** lastNow をリセット (タブ復帰・ロード直後に呼び、経過分を破棄)。 */
  resync(): void {
    this.lastNow = null;
    this.accumulatorMs = 0;
  }

  /**
   * フレームごとに呼ぶ。前回からの実時間経過を蓄積し、
   * 消化すべき tick 数を返す。advance はこの数だけ step すればよい。
   * 実時間を見るのはここだけ。
   */
  pump(): number {
    const t = this.now();
    if (this.lastNow === null) {
      this.lastNow = t;
      return 0;
    }
    const dt = t - this.lastNow;
    this.lastNow = t;
    if (this.speed === 0) return 0;

    this.accumulatorMs += dt * this.speed;
    let ticks = Math.floor(this.accumulatorMs / this.msPerTickAt1x);
    this.accumulatorMs -= ticks * this.msPerTickAt1x;

    if (ticks > this.maxTicksPerFrame) {
      // タブが長時間バックグラウンドだった等。端数も含めて切り捨て、
      // 一気にシミュレーションが飛ぶのを防ぐ (復帰は resync 推奨)。
      ticks = this.maxTicksPerFrame;
      this.accumulatorMs = 0;
    }
    return ticks;
  }
}
