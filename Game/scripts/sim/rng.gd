extends RefCounted
class_name Rng
## 決定的 PRNG (xorshift128)。
##
## KI-09: セーブ/ロードで展開が変わらないよう内部状態を完全に取り出せる必要がある。
## randf 等の Godot 組み込み乱数は状態を保存できないため使わない。
## 状態は 4 つの 32bit 符号なし整数。snapshot()/restore() で丸ごと保存・復元できる。
##
## 全演算は MASK32 で 32bit に畳む。TS 版 (src/sim/rng.ts) と同一アルゴリズム。

const MASK32 := 0xFFFFFFFF

var x: int
var y: int
var z: int
var w: int

func _init(seed: int = 0) -> void:
	# seed から初期状態を散らす (splitmix 風の単純な拡散)。
	var s := (seed ^ 0x9e3779b9) & MASK32
	x = _seed_next(s); s = (s + 0x6d2b79f5) & MASK32
	y = _seed_next(s); s = (s + 0x6d2b79f5) & MASK32
	z = _seed_next(s); s = (s + 0x6d2b79f5) & MASK32
	w = _seed_next(s)

func _seed_next(s_in: int) -> int:
	var s := (s_in + 0x6d2b79f5) & MASK32
	var t := s
	t = _imul(t ^ (t >> 15), t | 1) & MASK32
	t = (t ^ (t + _imul(t ^ (t >> 7), t | 61))) & MASK32
	return (t ^ (t >> 14)) & MASK32

## 32bit 符号なし乗算 (JS Math.imul 相当)。
static func _imul(a: int, b: int) -> int:
	return (a * b) & MASK32

## 次の 32bit 符号なし乱数 (0 .. 2^32-1)。
func next_uint32() -> int:
	var t := (x ^ ((x << 11) & MASK32)) & MASK32
	x = y
	y = z
	z = w
	w = (w ^ (w >> 19) ^ (t ^ (t >> 8))) & MASK32
	return w

## [0, 1) の浮動小数。
func next_float() -> float:
	return float(next_uint32()) / 4294967296.0

## [0, n) の整数。
func next_int(n: int) -> int:
	if n <= 0:
		return 0
	return next_uint32() % n

## 状態のスナップショット (セーブ用)。
func snapshot() -> Array:
	return [x, y, z, w]

## 状態の復元 (ロード用)。
func restore(state: Array) -> void:
	x = int(state[0]) & MASK32
	y = int(state[1]) & MASK32
	z = int(state[2]) & MASK32
	w = int(state[3]) & MASK32
