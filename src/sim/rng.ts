/**
 * 決定的 PRNG (xorshift128).
 *
 * KI-09: セーブ/ロードで展開が変わらないよう、RNG の内部状態を
 * 完全に取り出せる必要がある。Math.random は状態を取得できないため不可。
 * 状態は 4 つの 32bit 符号なし整数。snapshot() で丸ごと保存・復元できる。
 *
 * 全演算は >>> 0 で 32bit 符号なしに畳む。これにより JS/TS と
 * Python(同アルゴリズム移植) で完全にビット一致する。
 */
export type RngState = [number, number, number, number];

export class Rng {
  private x: number;
  private y: number;
  private z: number;
  private w: number;

  constructor(seed = 0) {
    // seed から初期状態を散らす (splitmix風の単純な拡散)。
    // 0 シードでも全状態が 0 にならないよう定数を混ぜる。
    let s = (seed ^ 0x9e3779b9) >>> 0;
    const next = () => {
      s = (s + 0x6d2b79f5) >>> 0;
      let t = s;
      t = (Math.imul(t ^ (t >>> 15), t | 1)) >>> 0;
      t = (t ^ (t + Math.imul(t ^ (t >>> 7), t | 61))) >>> 0;
      return (t ^ (t >>> 14)) >>> 0;
    };
    this.x = next();
    this.y = next();
    this.z = next();
    this.w = next();
  }

  /** 次の 32bit 符号なし乱数 (0 .. 2^32-1)。 */
  nextUint32(): number {
    const t = (this.x ^ (this.x << 11)) >>> 0;
    this.x = this.y;
    this.y = this.z;
    this.z = this.w;
    this.w = (this.w ^ (this.w >>> 19) ^ (t ^ (t >>> 8))) >>> 0;
    return this.w;
  }

  /** [0, 1) の浮動小数。53bit ではなく 32bit 精度 (移植の一致を優先)。 */
  nextFloat(): number {
    return this.nextUint32() / 0x100000000;
  }

  /** 状態のスナップショット (セーブ用)。 */
  snapshot(): RngState {
    return [this.x, this.y, this.z, this.w];
  }

  /** 状態の復元 (ロード用)。 */
  restore(s: RngState): void {
    this.x = s[0] >>> 0;
    this.y = s[1] >>> 0;
    this.z = s[2] >>> 0;
    this.w = s[3] >>> 0;
  }
}
