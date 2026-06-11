extends RefCounted
class_name StateMachine
## §5 ゴブリン自律行動 AI のステートマシン (個体 1 体・1 tick)。
## src/sim/state_machine.ts の忠実な移植。
##
## - ステート順位は固定 (State の enum 値が小さいほど高優先)。
## - 緊急系 (死亡・激昂・恐怖・戦闘) は即時割り込み。
## - 欲求系 (睡眠・空腹・仕事) は行動の切れ目で再評価。ヒステリシスで往復防止。
##   睡眠は空腹に優先する (夜は就寝するが、ゲージが抜けたら夜中でも起きて
##   活動に戻る。同じ夜に再ラッチはしない)。
## - 恐怖解除は「敵がいない連続 tick が一定数」= 安全確認ベース。
## - 族長(ユニーク)は恐怖を持たない盾 (§8)。
## - 事故死/戦闘ダメージは別レイヤー (world.gd)。ここでは状態遷移のみ。
##
## g を直接書き換える (Goblin は参照型)。world 側で 1 tick ごとに呼ぶ。

# ステートマシンが参照する環境 (個体の外側の状況)。
class Context:
	var enemy_nearby: bool = false
	var in_raid: bool = false
	var assigned_to_combat: bool = false
	var assigned_to_room: bool = false
	var food_available: bool = false   # この個体がいま食べられるか (集積所 + 在庫)
	var food_in_stock: bool = true     # 巣に在庫があるか (飢餓判定)
	var is_night: bool = false         # 夜か。夜は巣全体で就寝する (§5)

static func step(g: Goblin, ctx: Context, p: SimParams) -> void:
	if g.state == Goblin.State.DEAD:
		return

	# --- ユニークの瀕死保護 (§8 / §3-21) ---
	if g.hp <= 0.0:
		if g.is_unique:
			g.downed_ticks = (g.downed_ticks if g.downed_ticks >= 0 else 0) + 1
			g.state = Goblin.State.KNOCKED_OUT
			if g.downed_ticks > p.unique_downed_grace_ticks:
				g.state = Goblin.State.DEAD
			return
		else:
			g.state = Goblin.State.DEAD
			return
	elif g.downed_ticks >= 0:
		g.downed_ticks = -1  # 搬送・回復で起き上がる

	# --- 欲求の自然上昇 (激昂中は変化しない) ---
	if g.state != Goblin.State.ENRAGED:
		g.hunger = min(1.0, g.hunger + p.hunger_rate)
		g.sleepiness = min(1.0, g.sleepiness + p.sleep_rate)

	# --- ヒステリシス更新 ---
	# 空腹ラッチ ON のしきい値は hunger_bias で揺らぐ (食いしん坊/小食。hunger_off は不変)。
	var hunger_on: float = clampf(p.hunger_on + g.hunger_bias, 0.4, 0.95)
	if not g.hunger_latched and g.hunger >= hunger_on:
		g.hunger_latched = true
	elif g.hunger_latched and g.hunger <= p.hunger_off:
		g.hunger_latched = false
	# 睡眠: 夜になったら巣全体で寝るが、ゲージ (sleepiness) が抜けたら夜中でも
	# 起きて活動に戻る (同じ夜に再ラッチはしない / §5)。交戦中は夜トリガーで
	# 寝ない (防衛輪を崩さない)。疲労限界 (sleep_on) による発火は昼・交戦中の
	# 予備経路として残す。
	if not ctx.is_night:
		g.night_sleep_done = false  # 朝にリセット
	if not g.sleep_latched and ((ctx.is_night and not ctx.in_raid and not g.night_sleep_done) or g.sleepiness >= p.sleep_on):
		g.sleep_latched = true
	elif g.sleep_latched and g.sleepiness <= p.sleep_off:
		g.sleep_latched = false
		if ctx.is_night:
			g.night_sleep_done = true  # 同じ夜に再ラッチしない

	var hp_frac := g.hp / g.max_hp
	var starving: bool = g.hunger >= p.starve_threshold and not ctx.food_in_stock

	# === 緊急系の即時割り込み ===

	# 激昂: 外部 (奇跡) が設定し、ここでは維持/解除のみ。
	if g.state == Goblin.State.ENRAGED:
		if not ctx.in_raid and not ctx.enemy_nearby:
			g.state = Goblin.State.WANDER
		return

	# 恐怖: 族長は恐怖を持たない (§8)。
	if not g.is_unique:
		if g.state == Goblin.State.FEAR:
			if ctx.enemy_nearby:
				g.fear_safe_ticks = 0
			else:
				g.fear_safe_ticks += 1
				if g.fear_safe_ticks >= p.fear_clear_ticks:
					g.fear_safe_ticks = 0
					g.state = Goblin.State.DYING if hp_frac < p.dying_hp_frac else Goblin.State.WANDER
			return
		var fear_threshold: float = clampf(p.fear_hp_frac + g.fear_hp_bias, 0.0, 1.0)
		if ctx.enemy_nearby and hp_frac < fear_threshold:
			g.state = Goblin.State.FEAR
			g.fear_safe_ticks = 0
			return

	# 戦闘: 交戦中で戦線割り当て + 敵が近い。
	if ctx.in_raid and ctx.assigned_to_combat and ctx.enemy_nearby:
		g.state = Goblin.State.COMBAT
		return

	# === 欲求系 ===

	# 瀕死: 寝床へ + 回復。
	if hp_frac < p.dying_hp_frac:
		g.state = Goblin.State.DYING
		if not starving:
			g.hp = min(g.max_hp, g.hp + p.hp_regen_per_tick)
		return

	# 睡眠は空腹に優先する (夜は空腹でも寝るが、ゲージが sleep_off まで抜けたら
	# 夜中でも起きて食事に向かう。食事は即時化済みなので昼の食事時間は十分とれる)。
	# 飢餓中 (starving) は回復が止まるので、睡眠に逃げても餓死は進行する
	# (KI-26: 慢性飢餓へ戻らないための核心)。
	if g.sleep_latched:
		g.state = Goblin.State.SLEEP
		g.sleepiness = max(0.0, g.sleepiness - p.sleep_relieve_per_tick)
		if not starving:
			g.hp = min(g.max_hp, g.hp + p.hp_regen_per_tick)
		return

	# 空腹 (睡眠の下位。眠気が解消されてから食べに行く)。
	if g.hunger_latched:
		g.state = Goblin.State.HUNGRY
		if ctx.food_available:
			# 食事は即時: 集積所に到着した tick で満腹になる
			# (在庫消費は world 側が一食ぶん引く)。
			g.hunger = 0.0
		return

	# 仕事 (役職持ち優先)。
	if g.role != Goblin.Role.NONE or ctx.assigned_to_room:
		g.state = Goblin.State.WORK
		return

	# 放浪 (受け皿)。
	g.state = Goblin.State.WANDER
