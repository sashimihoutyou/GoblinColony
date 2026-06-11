extends RefCounted
class_name SimParams
## 力学定数の単一の真実源 (KI-01)。
##
## game_spec_v1.md §3-10 / §6 (§NUMBERS) と src/sim/params.ts を基に、
## α版 (空間あり・オートプレイ) で必要な定数だけを GDScript へ移植したもの。
## 未確定数値 (§NUMBERS) は暫定値。安易に変えると KI-22/25 の相互作用が崩れる。
##
## ★ tick/day の規律 (KI-02): レート・所要時間は「日単位」で定義し、_init() が
## ticks_per_day で per-tick 値へ変換する。per-tick 定数を素で書かないこと。
## 1 tick = 1 実秒 (main.gd MS_PER_TICK) × ticks_per_day=60 で 1 日 = 実 60 秒。

# --- 時間 (§3-10) ---
# 1 tick = 0.25 実秒 (main.gd MS_PER_TICK) × ticks_per_day=240 で 1 日 = 実 60 秒。
# tick を細かくしたのは連続移動 (RimWorld 風) を滑らかにサンプリングするため。
var ticks_per_day: int = 240
var day_ticks: int = 144         # 昼の tick 数 (= 日の 6 割)
var final_day: int = 30          # 規定日数 (最終日にラストバトル)

# --- 個体ステートマシン (閾値は比率なので解像度に依らない) ---
var fear_hp_frac: float = 0.45
var dying_hp_frac: float = 0.25
var hunger_on: float = 0.7
var hunger_off: float = 0.2
var sleep_on: float = 0.8
var sleep_off: float = 0.15
# 欲求ペーシング (§15 調整。Web 版ダッシュボードと同じ「観賞に耐える日次リズム」):
#  - 空腹ゲージは満腹から 1.2 日で限界に達する。発火 (hunger_on=0.7) は約 0.84 日
#    ごと = 1 日 1.2 回食事。食事は集積所到着で即時 (一括消費)。
#  - 睡眠: 夜 (日の後ろ 4 割 = 0.4 日) に巣全体で就寝する (夜トリガー §5)。昼の
#    疲労発火 (sleep_on=0.8) は予備経路。夜 0.4 日 × 解消 3.25/日 = 1.3 で昼の
#    蓄積 (0.6) を完全に解消できる。
var hunger_rate: float
var sleep_rate: float
var hp_regen_per_tick: float
var sleep_relieve_per_tick: float
var fear_clear_ticks: int        # 安全確認 0.4 日
var unique_downed_grace_ticks: int  # 搬送猶予 1.5 日

# --- 戦闘 (§3-4 / §8 簡易ランチェスター) ---
# 攻撃力は「1 日あたり」で定義し tick へ割る = 戦闘の所要「日数割合」が
# tick 解像度に依らない (旧 20tpd で 1.2/tick = 24/日)。
var goblin_attack: float
var enemy_attack: float
var enemy_hp: float = 6.0
var equip_bonus: float = 0.3     # 装備ボーナス +30% (§3-16)

# --- 敵の隊列 (§3-14 衝突) ---
# 同一タイルに入れる敵の数。1 = 単縦列 (隘路防衛が強く立つ・現行の安定帯)。
# 2 にすると襲撃が一気に苛烈になる (§15 調整ノブ。多シードで 1:6/6 勝, 2:1/6 勝)。
var enemy_tile_capacity: int = 1

# --- 襲撃スケジューラ (§3-5 / §3-7) ---
var base_enemies: int = 5        # 大規模襲撃の基礎頭数
var enemy_per_day: float = 0.4   # 日が進むごとの規模増加
var big_raid_interval_peace: int = 5   # 敵対度 0 のときの間隔 (日)
var big_raid_interval_max: int = 1     # 敵対度 MAX のときの間隔 (日)
var small_raid_prob: float = 0.3       # 小規模襲撃 (恵み) の 1 日あたり発生確率
var final_mult: float = 2.5            # ラストバトル倍率 (FINAL_MULT)

# --- 増殖 (§3-6) ---
var court_base_chance: float           # 求愛の誘い発火 1 tick 確率 (日次 3.0 を変換)
var court_timeout_ticks: int           # 求愛ランデブーのタイムアウト (0.5 日を変換)
var pregnancy_ticks: int               # 妊娠から出産まで (= 1 日)
var child_grow_ticks: int              # 子→成体 (= 1 日)
var litter_weights: Array = [0.30, 0.30, 0.18, 0.12, 0.06, 0.04]  # 一腹 1..6
var surge_trigger: float = 0.25        # 損耗割合がこれを超えると妊娠率バフ発火
var surge_gain: float = 2.0
var surge_max: float = 1.5
var surge_decay: float = 0.2

# --- 移動 (§3-0 連続移動。タイル/日で定義し per-tick へ変換) ---
# 成体 150 タイル/日 = 2.5 タイル/実秒 (1 日 60 秒)。巣の端から端まで約 10 秒。
var move_per_tick: float           # ゴブリン成体の 1 tick 移動量 (タイル)
var enemy_move_per_tick: float     # 敵 (やや遅い = 巣口到達までの猶予)
var child_move_factor: float = 0.7 # 子の速度倍率
var urgent_move_factor: float = 1.3 # 戦闘/恐怖の速度倍率
var wander_retarget_per_tick: float # 放浪が次の行き先を引く 1 tick 確率

# --- 事故死 (§3-3 / §2.5 放浪レイヤー) ---
var accident_prob: float               # 放浪中の事故死 (日次 0.04 を変換)
var fumble_prob: float                  # ドジ (転倒・非致死。日次 0.25 を変換)

# --- 社会 (§5 個性配線。雄同士の小競り合い) ---
var quarrel_prob: float                 # 隣接ケンカの 1 tick 発火確率 (日次 4.0 を変換)
var quarrel_damage: float = 0.6         # ケンカ 1 回の HP ダメージ (イベント単位 = KI-02 変換不要)
var quarrel_cooldown_ticks: int         # ケンカ後のクールダウン (0.5 日を変換)

# --- 頭数 (§2.5 二段収束) ---
var start_goblins: int = 10
var cap_pop: int = 40                  # 頭数上限 (CAP_POP_MAX)
var fledge_grace_ticks: int            # 上限超過 2 日で巣立ち (安全弁)

# --- 食料 (§3-11) ---
var food_per_rancher_tick: float       # ネズミ牧場 (日次 8.0 を変換)
# 食事 1 回の在庫消費 (イベント単位なので tick 解像度非依存 = KI-02 変換不要)。
# 一食 = 1.0 単位 (食料カウンタ = 残り食事回数)。
# 需要 ≈ hunger_rate/hunger_on ≈ 1.19 食/体/日。
var food_per_meal: float = 1.0
var ranch_assign_frac: float = 0.34    # 無役成体のうち牧場へ寄せる目標割合

# --- パン虫 (§3-11 救済床の実体化。攻撃してこない食用ザコ) ---
var mite_spawn_per_tick: float     # 自然湧き確率 (日次 1.2 を変換。上限と合わせ 1 日 0〜2 匹ほど)
var mite_max: int = 2              # 同時存在の上限
var mite_move_per_tick: float      # 移動速度 (30 タイル/日 を変換。ゴブリン 150 よりずっと遅い)
var mite_retarget_per_tick: float  # うろつきの行き先再抽選確率 (日次 24 を変換)
var mite_sight: int = 6            # 空腹ゴブリンがパン虫に気づく距離 (タイル)
var starve_threshold: float = 0.95     # 在庫0で飢餓ダメージが始まる空腹度
var starve_hp_per_tick: float          # 飢餓 HP ドレイン (日次 6.0 を変換)

# --- トーテム (§3-20) ---
var totem_hp_max: float = 60.0         # トーテム耐久 (0 で破壊 = 敗北)
var totem_repair_per_tick: float       # 平時の修繕 (日次 20.0 を変換)

# --- 信仰 (§3-1。α版は集計のみ) ---
var faith_per_shaman_tick: float       # 日次 2.0 を変換

var seed: int = 0

func _init() -> void:
	# 日次レート → per-tick (KI-02)。値そのものは旧 20tpd 校正の日次等価。
	var tpd := float(ticks_per_day)
	day_ticks = int(tpd * 0.6)
	hunger_rate = (1.0 / 1.2) / tpd
	sleep_rate = 1.0 / tpd
	hp_regen_per_tick = 1.5 / tpd
	sleep_relieve_per_tick = 3.25 / tpd
	fear_clear_ticks = int(0.4 * tpd)
	unique_downed_grace_ticks = int(1.5 * tpd)
	goblin_attack = 24.0 / tpd
	enemy_attack = 20.0 / tpd
	court_base_chance = 3.0 / tpd
	court_timeout_ticks = int(0.5 * tpd)
	pregnancy_ticks = ticks_per_day
	child_grow_ticks = ticks_per_day
	accident_prob = 0.04 / tpd
	fumble_prob = 0.25 / tpd
	quarrel_prob = 4.0 / tpd
	quarrel_cooldown_ticks = int(0.5 * tpd)
	fledge_grace_ticks = ticks_per_day * 2
	# 牧場 8.0 食/日: 割当 alive×0.34 のうち食事・睡眠で稼働率 ~55% に落ちるため、
	# 実効 ≈ 0.34×0.55×8.0 ≈ 1.5 食/体/日 で需要 1.19 食/体/日 をわずかに上回る。
	# (旧 4.5 相当は、廃止した抽象救済 + 一括消費クランプ (在庫が僅かでも一食に
	# なる) の隠れ補助に依存した見かけの均衡で、キャップ人口で飢餓スパイラル化)
	food_per_rancher_tick = 8.0 / tpd
	mite_spawn_per_tick = 1.2 / tpd
	mite_move_per_tick = 30.0 / tpd
	mite_retarget_per_tick = 24.0 / tpd
	starve_hp_per_tick = 6.0 / tpd
	faith_per_shaman_tick = 2.0 / tpd
	totem_repair_per_tick = 20.0 / tpd
	move_per_tick = 150.0 / tpd
	enemy_move_per_tick = 110.0 / tpd
	wander_retarget_per_tick = 8.0 / tpd
