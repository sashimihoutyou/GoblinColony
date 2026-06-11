"""決定的 PRNG (xorshift128) — src/sim/rng.ts の Python 移植。

TS 版 (src/sim/rng.ts) とビット単位で一致させるため、JS の `>>> 0`
(符号なし32bit化) や `Math.imul` (32bit 符号付き乗算) のセマンティクスを
Python で `& 0xFFFFFFFF` マスクにより再現する。

- JS の `>>> 0` ≒ Python の `& 0xFFFFFFFF` (両者とも結果は非負 32bit 整数)。
- JS の `<<` は左辺を一旦 32bit 符号付きへ変換してからシフトし、
  結果も 32bit 符号付きになる。本実装では直後に `>>> 0` (マスク) するため、
  シフト前に `& 0xFFFFFFFF` で 32bit 範囲へ落としてから `<<` し、
  最後に `& 0xFFFFFFFF` すれば符号の有無に関わらず同じビット列になる。
- `Math.imul(a, b)` は a, b を 32bit 符号付きとみなした乗算の下位32bitを
  返す (符号付き)。本実装では直後に `>>> 0` するため、`(a * b) & 0xFFFFFFFF`
  で同じビット列が得られる (符号は無視できる)。
- `nextFloat()` は `nextUint32() / 0x100000000` (整数 ÷ 2^32) であり、
  IEEE754 double で正確に表現できるため Python/JS で同一結果になる。
"""

MASK32 = 0xFFFFFFFF


class Rng:
    def __init__(self, seed: int = 0):
        # seed から初期状態を散らす (splitmix風の単純な拡散)。
        # 0 シードでも全状態が 0 にならないよう定数を混ぜる。
        s = (seed ^ 0x9E3779B9) & MASK32

        def next_state():
            nonlocal s
            s = (s + 0x6D2B79F5) & MASK32
            t = s
            t = ((t ^ (t >> 15)) * (t | 1)) & MASK32
            t = (t ^ (t + (((t ^ (t >> 7)) * (t | 61)) & MASK32))) & MASK32
            return (t ^ (t >> 14)) & MASK32

        self.x = next_state()
        self.y = next_state()
        self.z = next_state()
        self.w = next_state()

    def next_uint32(self) -> int:
        """次の 32bit 符号なし乱数 (0 .. 2^32-1)。"""
        t = (self.x ^ ((self.x << 11) & MASK32)) & MASK32
        self.x = self.y
        self.y = self.z
        self.z = self.w
        self.w = (self.w ^ (self.w >> 19) ^ (t ^ (t >> 8))) & MASK32
        return self.w

    def next_float(self) -> float:
        """[0, 1) の浮動小数。53bit ではなく 32bit 精度 (移植の一致を優先)。"""
        return self.next_uint32() / 0x100000000

    def snapshot(self):
        """状態のスナップショット (セーブ用)。"""
        return [self.x, self.y, self.z, self.w]

    def restore(self, s):
        """状態の復元 (ロード用)。"""
        self.x = s[0] & MASK32
        self.y = s[1] & MASK32
        self.z = s[2] & MASK32
        self.w = s[3] & MASK32
