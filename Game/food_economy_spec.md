# 食料経済の再設計 仕様書（Godot 版 / Game/ 限定）

> **改訂 (2026-06)**: 食事は即時化された（HUNGRY で集積所到着 → `hunger=0`、在庫は
> `food_per_meal` を一括消費）。`hunger_rate` は `1/1.2` 日（満腹→空腹MAXが1.2日）へ
> 変更。本文 §2 の `food_eat_amount` / `hunger_relieve` 関連の記述は旧仕様（per-tick 漸次回復）
> を前提にしており現状と一致しない。
>
> **改訂 (2026-06b)**: 食料の単位を一食=1.0 単位へ再スケール（食料カウンタ=残り食事回数）。
> `food_per_meal=1.0`、牧場生産 `food_per_rancher_tick` は日次 **8.0**。需要 ≈ 1.19 食/体/日。
> 単純な比率換算（旧 10/2.625 ≒ 4.5/日）では多シード勝率が 5/6→1/6 に崩壊した。旧均衡は
> 「抽象救済のトリクル + 一括消費のクランプ（在庫が僅かでも一食まるごと食べられる）」という
> 隠れ補助に依存しており、補助の廃止で真の赤字が露出して飢餓スパイラル（餓死→surge→
> 出生爆発→さらに飢餓）に陥るため。8.0/日（割当 alive×0.34 × 稼働率 ~55% で実効
> ≈1.5 食/体/日 ＞ 需要 1.19）+ 初期在庫 15 食で帳尻を実収支で合わせ、勝率 5/6 を回復。
> 抽象的な救済湧き `food_passive_per_tick` は**廃止**し、実体のある「パン虫」へ置換した
> （巣内の床に 1 日 0〜2 匹ほど自然湧きする食用ザコ。攻撃せず・足が遅い・うろつくだけ。
> 空腹個体が視界内に見つけると集積所より優先して狩りに向かい、隣接で捕食 = 即時満腹。
> 在庫は減らない）。本文 §3 の救済床の記述（`food_passive_per_tick`）はこの実体化で置換済み。

対象: `Game/scripts/sim/`（Godot 4.6 / GDScript）。TS コア（`src/sim/`）には食料力学が
無いため**今回は触らない**。実装者（Codex）はこの仕様に沿って `params.gd` / `world.gd` /
`state_machine.gd` を変更する。GDD/`game_spec_v1.md` §3-11・§2.5、`Game/README.md`、
KI-01/02/09 に整合させること。

---

## 0. 背景と目的

現状、食料が回らず全個体が慢性的に飢える。原因は次の4点。

1. **収支が約6倍の赤字**（生産 18/日 ≪ 需要 ~105/日 @10体）。`Game/README.md:100` に既知として明記。
2. **飢餓ペナルティが無い** — 在庫0でも HP が減らず、餓死しない。
3. **救済の自然湧きが無い** — 在庫が0になると牧場係も飢えて働けず回復不能になる。
4. **ネズミ牧場が建て置き** — 割当頭数を数えるだけで、寝ていても逃げていても牧場に居なくても生産する。

本仕様はこの4点を、以下4機能で解消する。

- **① 食料収支の再校正**（消費・生産レートの日次値見直し）
- **② ネズミ牧場の稼働判定**（実際に牧場で働く個体だけが生産 + 日境界の動的再割当）
- **③ パン虫の自然湧き（救済床）**（在庫低下時のみ湧く安全弁）
- **④ 飢餓ペナルティと餓死**（飢餓中は HP 回復停止 + HP ドレイン + 餓死）

### 現状数値の根拠（`params.gd` / `world.gd`）

`ticks_per_day = 240` で日次レートから収支を求める。

需要: 自然空腹 `hunger_rate=1.75/日`、解消 `hunger_relieve=10/日`、消費 `food_eat_amount=60/日`。
食事のハンガー1単位あたり食料コスト = 60/10 = 6 food/単位。1体は1日に 1.75 単位ぶん空腹が
上昇しそれを食べ切るので **約 10.5 food/体/日**。

供給: `food_per_rancher_tick=6/日` × 初期割当3体 = **18 food/日**（戦闘で敵撃破ごとに +1.0）。

→ 10体で需要 105/日 ≫ 供給 18/日。初期在庫 20 は即枯渇し以後ゼロ常態。

---

## 1. 不変条件（必読・違反するとリグレッション）

- **KI-02（tick/day 規律）**: レート・所要時間は**日単位で定義**し、`SimParams._init()` で
  `ticks_per_day` から per-tick へ変換する。**per-tick 定数を素書きしない**。
- **KI-09（全状態は tick の関数 / スナップショット往復一致）**:
  - 新しい**永続フィールドを増やさない**設計とする。飢餓状態は既存 `hunger`/`hp` から導出。
  - 牧場の動的再割当が触る `map.rooms[i].assigned` は `map.snapshot()` が深いコピーで保存・
    復元するので往復一致は保たれる（`tile_map.gd:72`）。順序を乱さないこと（後述）。
- **決定性 / RNG 消費順序**: 本仕様の追加処理は**いずれも RNG を消費しない**（`rng.next_*` を
  呼ばない）。既存の RNG 消費箇所（増殖・事故死・襲撃判定）の順序・回数を一切変えないこと。
- **純粋性の規律**: `state_machine.gd` は個体1体・1tick の状態遷移のみ（副作用は `g` の書き換え）。
  ダメージ・死亡集約は `world.gd` 側に置く（既存規律）。

---

## 2. `params.gd` の変更

### 2-1. 既存定数の改値（日次値のみ変更。`_init()` の変換式はそのまま）

| 変数 | 現（日次） | 変更後（日次） | 理由 |
|---|---|---|---|
| `food_eat_amount` | `60.0 / tpd` | **`15.0 / tpd`** | 需要 10.5→約 2.6 food/体/日 |
| `food_per_rancher_tick` | `6.0 / tpd` | **`10.0 / tpd`** | 稼働牧場係1体で約4体分（②で稼働中のみ計上） |

### 2-2. 新規定数の追加

宣言部（`# --- 食料 (§3-11) ---` ブロック近辺）に追加し、`_init()` で変換する。

```gdscript
# --- 食料 (§3-11) ---
var food_per_rancher_tick: float       # ネズミ牧場・稼働1体あたり (日次 10.0 を変換)
var food_eat_amount: float             # 食事 1 tick の消費 (日次 15.0 を変換 = KI-02)
var food_passive_per_tick: float       # パン虫の自然湧き・救済床 (日次 4.0 を変換)
var ranch_assign_frac: float = 0.34    # 無役成体のうち牧場へ割り当てる目標割合 (比率=解像度非依存)

# --- 飢餓ペナルティ (§2.5) ---
var starve_threshold: float = 0.95     # この空腹以上 & 在庫0 で餓死進行 (比率=解像度非依存)
var starve_hp_per_tick: float          # 飢餓中の HP ドレイン (日次 6.0 を変換)
```

`_init()` 末尾の食料ブロックに変換を追加（既存 `food_per_rancher_tick` / `food_eat_amount` の
右辺も上表の新しい日次値へ差し替える）:

```gdscript
	food_per_rancher_tick = 10.0 / tpd
	food_eat_amount = 15.0 / tpd
	food_passive_per_tick = 4.0 / tpd
	starve_hp_per_tick = 6.0 / tpd
```

> 比率系（`ranch_assign_frac`, `starve_threshold`）は解像度に依らないので `_init()` 変換不要。

### 2-3. 数値の位置づけ

上記はすべて **§15 多シード調整の初期値**。`test_seeds.gd` の勝率・平均HP・平均在庫・餓死数を
見ながら詰める前提。安易な微調整は KI-22/25 の相互作用を崩すので、まず本仕様どおりの値で実装し、
収支が定常黒字へ収束することを確認してから調整する。

#### 収支の検算（実装の妥当性チェック用）

- 需要 ≈ `hunger_rate × food_eat_amount/hunger_relieve` = 1.75 × 15/10 = **2.625 food/体/日**。
- 12体・稼働牧場係4体: 供給 = 4×10 + 4(パン虫) = 44/日 ＞ 需要 31.5/日（黒字でバッファ蓄積）。
- 襲撃中に牧場係が戦線へ抜けると供給がパン虫4/日のみへ低下し在庫が削れる（=設計された緊張。
  襲撃は短時間なので回復可能）。

---

## 3. `world.gd` の変更

### 3-1. `tick_once()` の配線（順序が重要）

現行の呼び出し順（`world.gd:124-134`）:

```
_update_raid_schedule → _step_enemies → _step_goblins → _resolve_combat
→ _step_breeding → _step_accidents → _step_food → _step_faith
→ _cleanup_dead → _step_fledge → _check_outcome
```

変更: `_step_food` の**直後**に新規 `_step_starvation()` を挿入する。

```
... → _step_food → _step_starvation → _step_faith → _cleanup_dead → ...
```

理由: その tick の生産（牧場 + パン虫）で在庫が復活したら飢餓ドレインは発生させない
（救済床が先に効く）。死亡は従来どおり `_cleanup_dead` が集計する。

### 3-2. `_step_food()` の書き換え（② + ③）

現行は割当数を素で数える。これを「**牧場矩形内で WORK 中の生存個体**」だけ数える形に変え、
パン虫の救済床を加える。RNG 不使用・決定的。

```gdscript
func _step_food() -> void:
	# 生産: ネズミ牧場で実際に働いている個体だけが産む (建て置き禁止)。
	# 割当 (r.assigned) されていても、寝ている/逃げている/戦っている/牧場に居ない
	# 個体は計上しない。state==WORK かつ牧場矩形内に居ることを要件とする。
	var active_ranchers := 0
	for r in map.rooms:
		if r.room_type != TileMapData.RoomType.RAT_RANCH:
			continue
		for gid in (r.assigned as Array):
			var g := _goblin_by_id(gid)
			if g == null or g.state == Goblin.State.DEAD:
				continue
			if g.state == Goblin.State.WORK and _in_room(r, g.pos()):
				active_ranchers += 1
	food += active_ranchers * params.food_per_rancher_tick

	# 救済床 (③ パン虫の自然湧き §3): 在庫が生存頭数を下回る時だけ微量に湧く。
	# 在庫が積み上がっている時は湧かさない (経済をトリビアル化しない安全弁)。
	if food < float(_alive_count()):
		food += params.food_passive_per_tick
```

補助関数（未存在なら追加。`_alive_count()` は既存）:

```gdscript
func _goblin_by_id(id: int) -> Goblin:
	for g in goblins:
		if g.id == id:
			return g
	return null

func _in_room(r: Dictionary, p: Vector2i) -> bool:
	return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
```

> 補足: 割当ゴブリンは `_work_target`（`world.gd:327`）で既に牧場床へ向かう。本変更で
> 「牧場に到着して WORK 状態の個体だけ」が生産主体になる。

### 3-3. 牧場の動的再割当（②・出産による頭数増への追従）

現行は初期化時に固定3体割当（`world.gd:83`）。出産で頭数が増えても供給が頭打ちになるため、
**日境界で割当数を頭数に追従**させる。`_on_day_boundary()`（`world.gd:140`）に1行追加し、
新規 `_rebalance_ranch()` を実装する。RNG 不使用・決定的（id 昇順で選ぶ）。

```gdscript
func _on_day_boundary() -> void:
	if surge > 0.0:
		surge = max(0.0, surge - params.surge_decay)
	_rebalance_ranch()                       # ← 追加
	if day == params.final_day:
		_spawn_raid(true, true)

# 牧場係の頭数を生存頭数に追従させる (建て置き → 動的運用)。
# 目標 = 無役成体相当の約 ranch_assign_frac。決定的に id 昇順で増減する。
func _rebalance_ranch() -> void:
	var target := int(round(_alive_count() * params.ranch_assign_frac))
	for r in map.rooms:
		if r.room_type != TileMapData.RoomType.RAT_RANCH:
			continue
		var assigned: Array = r.assigned
		# 死亡・巣立ちで消えた id を掃除。
		var cleaned: Array = []
		for gid in assigned:
			var g := _goblin_by_id(gid)
			if g != null and g.state != Goblin.State.DEAD:
				cleaned.append(gid)
		assigned = cleaned
		# 不足ぶんを無役・非ユニーク・非子の成体から id 昇順で補充。
		if assigned.size() < target:
			var pool: Array = []
			for g in goblins:
				if g.role == Goblin.Role.NONE and not g.is_unique and not g.is_child() \
						and not (g.id in assigned):
					pool.append(g.id)
			pool.sort()
			for gid in pool:
				if assigned.size() >= target:
					break
				assigned.append(gid)
		# 過剰ぶんは末尾 (新しく入った id) から外す。
		while assigned.size() > target:
			assigned.pop_back()
		r.assigned = assigned
```

> 既存の初期化 `_assign_to_room(TileMapData.RoomType.RAT_RANCH, 3)`（`world.gd:83`）は
> 残してよい（初日0時点の割当）。`_rebalance_ranch()` が以後の各日境界で上書き調整する。
> 1部屋構成（`map_template.gd` は RAT_RANCH 1室）を前提に書いてよいが、複数室でも壊れないよう
> 上記は全 RAT_RANCH 室を走査する形にしてある。

### 3-4. `_step_starvation()` の新設（④）

`_step_accidents`（`world.gd:526`）と同じ死亡パターンを踏襲する。RNG 不使用・決定的。

```gdscript
# --- 飢餓ペナルティ (§2.5: ステートマシン外の独立レイヤー) ---
# 在庫が尽き、空腹が限界の個体は HP を失い、0 で餓死する。
# _step_food の後に呼ぶ (その tick の生産・パン虫で在庫が戻れば飢えない)。
func _step_starvation() -> void:
	if food > 0.0:
		return  # 在庫があれば誰も飢えない
	for g in goblins:
		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		if g.hunger < params.starve_threshold:
			continue
		g.hp -= params.starve_hp_per_tick
		if g.hp <= 0.0:
			if g.is_unique:
				# ユニークは hp<=0 を直接死亡にしない。次 tick の state_machine が
				# KNOCKED_OUT + 搬送猶予 (§3-21) を適用する。HP は 0 で止める。
				g.hp = 0.0
				continue
			g.hp = 0.0
			g.state = Goblin.State.DEAD
			g.death_logged = true
			_event({"t": "death", "id": g.id, "sex": g.sex, "cause": "starvation"})
```

> 死因 `"starvation"` を新しい cause として導入。非ユニークは即時に確定死。ユニークは既存の
> 搬送猶予ロジック（`state_machine.gd:28-34`）に委ね、餓死では死因が既定（cleanup の
> `"combat"`）にフォールバックする（許容するエッジ）。

---

## 4. `state_machine.gd` の変更（④ 飢餓中は HP 回復停止）

飢餓中（`hunger >= starve_threshold` かつ在庫無し）は、DYING / SLEEP の自然回復を**止める**。
これがないと、餓死ドレインで HP が下がっても DYING に落ちて回復し、閾値付近で停滞して餓死しない。

Context には既に `food_in_stock`（`state_machine.gd:21`）があるのでこれを使う。新フィールド不要。

`step()` 内、`hp_frac` 算出（`state_machine.gd:56`）の直後に飢餓フラグを定義:

```gdscript
	var hp_frac := g.hp / g.max_hp
	# 飢餓中は HP 自然回復を止める (餓死を成立させる。world._step_starvation が HP を削る)。
	var starving := g.hunger >= p.starve_threshold and not ctx.food_in_stock
```

回復している3箇所を `starving` で抑止する。

1. 瀕死（`state_machine.gd:91-94`）:

```gdscript
	if hp_frac < p.dying_hp_frac:
		g.state = Goblin.State.DYING
		if not starving:
			g.hp = min(g.max_hp, g.hp + p.hp_regen_per_tick)
		return
```

2. 睡眠（`state_machine.gd:106-110`）:

```gdscript
	if g.sleep_latched:
		g.state = Goblin.State.SLEEP
		g.sleepiness = max(0.0, g.sleepiness - p.sleep_relieve_per_tick)
		if not starving:
			g.hp = min(g.max_hp, g.hp + p.hp_regen_per_tick)
		return
```

> 空腹分岐（`state_machine.gd:99-103`）の「在庫が無く眠気も限界なら睡眠を優先」の救済則
> （不眠の飢餓ループ対策）は**そのまま残す**。睡眠に逃げても `starving` なら回復しないので、
> 飢餓は確実に進行する。眠気・睡眠ステート自体は維持（演出・力学の整合のため）。

---

## 5. テスト要件

### 5-1. 既存テスト（必ず緑のまま）

```
godot --headless --path Game --import
godot --headless --path Game --script res://scripts/test_smoke.gd        # SMOKE_OK
godot --headless --path Game --script res://scripts/test_scene_smoke.gd  # SCENE_SMOKE_OK
```

特に**スナップショット往復一致**（KI-09）が崩れないこと。`food` は既に snapshot 対象、
`rooms.assigned` は `map.snapshot()` の深いコピーで保存される。新永続フィールドは追加しない。

### 5-2. 新規テスト `Game/scripts/test_food.gd`（追加）

ヘッドレスで以下を検証（`test_seeds.gd` のハーネス様式に倣う）:

1. **定常黒字**: 既定パラメータで初期頭数から N 日（例: 15日、平時のみ。襲撃の有無に依らず）
   回したとき、平均在庫が時間とともに 0 から正へ立ち上がり、終盤で `food > 0` を一定割合の
   tick で満たす（慢性ゼロが解消している）。
2. **稼働判定**: 全牧場係を強制的に SLEEP/別部屋へ置いた tick では `food` が（パン虫ぶんを除き）
   増えない。WORK かつ牧場内の個体数 × `food_per_rancher_tick` ぶんだけ増える。
3. **餓死の成立**: `food=0` に固定し全個体の `hunger=1.0` にすると、数 tick 後に
   `hp` が単調減少し、やがて cause `"starvation"` の death イベントが発生する。
4. **救済床のゲート**: `food` を十分大きく（> 生存頭数）した tick ではパン虫が湧かない
   （`food_passive_per_tick` が加算されない）。`food < 生存頭数` の tick でのみ加算される。
5. **スナップショット往復**: 任意 tick で `snapshot()` → 別 World で `restore()` → 以後 M tick
   進めた結果が、元 World を M tick 進めた結果と完全一致（`food`・各個体 hp/hunger・
   `rooms.assigned` 含む）。

### 5-3. 多シード回帰（手動・任意）

```
godot --headless --path Game --script res://scripts/test_seeds.gd
```

勝率が本変更前から大きく悪化しないこと。悪化する場合は §2-3 の初期値（消費・牧場・パン虫・
餓死レート、`ranch_assign_frac`）を §15 調整対象として詰める。

---

## 6. ドキュメント更新

- `Game/README.md:100-102` の「食料経済は未調整（生産 18/日 ≪ 需要…）」と、それに伴う
  「不眠の飢餓ループ救済則」の記述を、本変更後の挙動（収支均衡 + 餓死導入 + パン虫救済床 +
  牧場稼働判定）に合わせて更新する。救済則は**残すが意味が変わる**（睡眠に逃げても飢餓中は
  回復しない）旨を明記。
- `known_issues_world.md` に本件を1項追加してよい（次番号 KI-26 想定。背景=慢性飢餓、
  解決=収支再校正/稼働判定/救済床/餓死、相互作用=襲撃中の牧場係離脱による供給低下が緊張源）。

---

## 7. 受け入れ基準（チェックリスト）

- [ ] `params.gd`: `food_eat_amount`=15/日、`food_per_rancher_tick`=10/日 へ改値。
      `food_passive_per_tick`=4/日、`starve_hp_per_tick`=6/日、`starve_threshold`=0.95、
      `ranch_assign_frac`=0.34 を追加（per-tick 系は `_init()` 変換、比率系は素のまま）。
- [ ] `world.gd`: `_step_food` を稼働判定 + 救済床へ書き換え。`_goblin_by_id`/`_in_room` 補助。
- [ ] `world.gd`: `_rebalance_ranch()` 追加、`_on_day_boundary()` から呼ぶ。
- [ ] `world.gd`: `_step_starvation()` 追加、`tick_once()` で `_step_food` の直後に配線。
- [ ] `state_machine.gd`: `starving` フラグを定義し、DYING/SLEEP の HP 回復を抑止。
- [ ] RNG を一切消費しない（既存の消費順序・回数を変えない）。新永続フィールドを追加しない。
- [ ] 既存スモーク（SMOKE_OK / SCENE_SMOKE_OK）が緑。スナップショット往復一致が維持。
- [ ] 新規 `test_food.gd` の5項目が通る。
- [ ] `Game/README.md` の食料経済記述を更新。
