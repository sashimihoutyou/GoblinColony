extends RefCounted
class_name Goblin
## 個体ゴブリン (§5)。src/sim/goblin.ts の移植 + §3-0 で座標フィールドを追加。
##
## ステート遷移は state_machine.gd が、移動・戦闘・増殖は world.gd が扱う。
## 全フィールドはプレーン値で、snapshot() で JSON 化できる (KI-09)。

# §5 ステート (値が小さいほど高優先)。state_machine.gd と共有。
enum State {
	DEAD = 0,
	ENRAGED = 1,
	FEAR = 2,
	COMBAT = 3,
	DYING = 4,
	HUNGRY = 5,
	SLEEP = 6,
	WORK = 7,
	WANDER = 8,
	KNOCKED_OUT = 10,  # §3-21 HP0 で倒れたユニーク
}

enum Role { NONE = 0, SHAMAN = 1, CHIEF = 2, WITCH_DOCTOR = 3, NURSERY_HOST = 4, CONCUBINE = 5, GUARD = 6 }
enum Sex { MALE = 0, FEMALE = 1 }
enum Origin { FOUNDER = 0, BORN = 1, NURSERY = 2, SUMMONED = 3, CAPTIVE_JOINED = 4, CONCUBINE = 5 }

var id: int = 0
var sex: int = Sex.MALE
var state: int = State.WANDER
var role: int = Role.NONE
var hp: float = 10.0
var max_hp: float = 10.0
var hunger: float = 0.0       # 0(満腹)..1(限界)
var sleepiness: float = 0.0

# 性格 (§5: 閾値と重みの補正)
var fear_hp_bias: float = 0.0
var hunger_bias: float = 0.0
var work_bias: float = 0.0
var forage_bias: float = 0.0
var clumsy: float = 0.5    # ドジ度 0..1 (転倒・事故死のロール係数)
var temper: float = 0.5    # 気性の荒さ 0..1 (ケンカの発火条件)

# ヒステリシス (KI-09: 必ず保存)
var hunger_latched: bool = false
var sleep_latched: bool = false
# その夜すでに寝てゲージを抜いたか (§5)。夜入りで毎回 false にリセットし、
# sleep_off まで抜けて起きたら true にする (同じ夜に再ラッチしない)。
var night_sleep_done: bool = false

# 増殖 (§2.5)
var pregnant: bool = false
var pregnant_ticks: int = 0
var mate_id: int = -1
var bereaved: bool = false
# 求愛ランデブー (§3-6): 雌が雄を寝床に誘い、寝床で合流して初めて妊娠が成立する。
# courting_id は雌雄両方に相手 id を相互設定する (-1 = 非求愛)。court_ticks は
# タイムアウト用の経過 tick (雌側でカウント)。
var courting_id: int = -1
var court_ticks: int = 0

var is_unique: bool = false
var downed_ticks: int = -1     # -1 = 倒れていない
# §3-21 搬送: 倒れたユニークを担いでいる相手の id (-1 = 搬送していない)。
# 搬送中は世界層が NEST へ向けて移動目標を上書きし、戦闘割り当てもブロックする。
var carrying_id: int = -1
var fear_safe_ticks: int = 0
var child_born_tick: int = -1  # -1 = 成体
var quarrel_cd: int = 0        # ケンカのクールダウン (tick。0 で発火可)

# 仕事フラグ (§3-11)
var carrying_food: bool = false  # T4 採集: キノコを摘んで集積所へ運搬中か
var guard_gate: int = -1         # T5 見張り: 担当巣口 index (-1 = 見張りでない)
# §11.5 派遣: 回収を命じられた巣外出現物の id (-1 = 派遣されていない)。
# 運搬中 (carrying_food) は出現物が消えても集積所への配達を済ませてから解除する。
var dispatch_id: int = -1

# 出自 (KI-20)
var born_tick: int = 0
var mother_id: int = -1
var father_id: int = -1
var origin: int = Origin.FOUNDER

# --- 空間 (§3-0) ---
# fx/fy が真の位置 (タイル単位の連続座標。fx=3.0 = タイル 3 の中心)。
# x/y は丸めた派生値で、隣接判定・部屋判定などタイルベースの力学が使う。
var x: int = 0
var y: int = 0
var fx: float = 0.0
var fy: float = 0.0
var target_x: int = -1         # -1 = 移動目標なし
var target_y: int = -1
var path: Array = []           # Array[Vector2i] A* 計算済みパス
var equipped: bool = false     # §3-16 装備済み

# 死亡イベントの二重記録防止 (同一 tick 内のみ有効。スナップショット対象外)。
var death_logged: bool = false

func pos() -> Vector2i:
	return Vector2i(x, y)

func is_child() -> bool:
	return child_born_tick >= 0

## 2 個体の相性 (0..1)。id から決定的に算出 (rng を消費しない / charmSeed 相当)。
static func compatibility(a: Goblin, b: Goblin) -> float:
	var sa := (a.id * 2654435761) & 0xFFFFFFFF
	var sb := (b.id * 2654435761) & 0xFFFFFFFF
	var lo: int = min(sa, sb)
	var hi: int = max(sa, sb)
	var mixed: int = ((lo + 1) * 2246822519) ^ ((hi + 1) * 3266489917)
	return float((mixed & 0xFFFFFFFF) % 1000) / 1000.0

func snapshot() -> Dictionary:
	return {
		"id": id, "sex": sex, "state": state, "role": role,
		"hp": hp, "max_hp": max_hp, "hunger": hunger, "sleepiness": sleepiness,
		"fear_hp_bias": fear_hp_bias, "hunger_bias": hunger_bias,
		"work_bias": work_bias, "forage_bias": forage_bias,
		"clumsy": clumsy, "temper": temper,
		"hunger_latched": hunger_latched, "sleep_latched": sleep_latched,
		"night_sleep_done": night_sleep_done,
		"pregnant": pregnant, "pregnant_ticks": pregnant_ticks,
		"mate_id": mate_id, "bereaved": bereaved,
		"courting_id": courting_id, "court_ticks": court_ticks,
		"is_unique": is_unique, "downed_ticks": downed_ticks, "carrying_id": carrying_id,
		"fear_safe_ticks": fear_safe_ticks, "child_born_tick": child_born_tick,
		"quarrel_cd": quarrel_cd,
		"carrying_food": carrying_food, "guard_gate": guard_gate,
		"dispatch_id": dispatch_id,
		"born_tick": born_tick, "mother_id": mother_id, "father_id": father_id,
		"origin": origin, "x": x, "y": y, "fx": fx, "fy": fy,
		"target_x": target_x, "target_y": target_y,
		"path": path.map(func(p): return [p.x, p.y]),
		"equipped": equipped,
	}

static func from_snapshot(d: Dictionary) -> Goblin:
	var g := Goblin.new()
	for k in d.keys():
		if k == "path":
			g.path = (d.path as Array).map(func(p): return Vector2i(p[0], p[1]))
		else:
			g.set(k, d[k])
	return g
