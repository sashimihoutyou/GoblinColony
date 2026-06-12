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
## 1 tick = 0.375 実秒 (main.gd MS_PER_TICK) × ticks_per_day=240 で 1 日 = 実 90 秒。

# --- 時間 (§3-10) ---
# 1 tick = 0.375 実秒 (main.gd MS_PER_TICK) × ticks_per_day=240 で 1 日 = 実 90 秒。
# tick を細かくしたのは連続移動 (RimWorld 風) を滑らかにサンプリングするため。
var ticks_per_day: int = 240
var day_ticks: int = 168         # 昼の tick 数 (= 日の 7 割。_init で再計算)
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
#  - 睡眠: 夜 (日の後ろ 3 割 = 0.3 日) に巣全体で就寝する (夜トリガー §5)。ただし
#    ゲージの減少 (と HP 回復) は寝床 (NEST) に到着してから始まる (巣内の移動
#    ≈ 0.1〜0.2 日かかる)。夜トリガーから到着までの徒歩ぶんを差し引いた
#    実消化時間 (≈ 0.1〜0.2 日) で、解消 4.5/日 × ≈0.15 日 ≈ 0.7 を確保し、
#    昼の蓄積 (0.7 日 × 1.0/day = 0.7) を朝までに解消できる。昼の疲労発火
#    (sleep_on=0.8) は予備経路。
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

# --- 捕虜プール + 敵対度 (§2.5/§13。world.ts の捕虜・敵対度セクションの移植 KI-17/23/24) ---
# 捕虜は cap_male_goblin/cap_female_goblin/cap_male_human/cap_female_human の
# 4 区分 (float 連続量。world.ts と同じ)。性別×種族の振り分けは下記 maleFrac で行う。
var captive_male_frac_goblin: float = 0.7   # ゴブリン勢力からの捕虜の雄割合 (CAPTIVE_COMP.goblin)
var captive_male_frac_human: float = 0.55   # 人間勢力からの捕虜の雄割合 (CAPTIVE_COMP.human)
# 撃退報酬の捕虜獲得数 (1 回の戦闘終了あたり総数。即時量なので _init() の
# per-tick 変換は通さない = KI-02 の対象外。world.ts BIG_RAID_CAPTIVE_GAIN)。
var big_raid_captive_gain: float = 2.0
# 小規模襲撃 (恵み §11/KI-05) の捕虜報酬は控えめ (world.ts captiveGainSmall)。
# 大規模と同量にすると恵み側の報酬がインフレし KI-25 の前提が崩れる。
var small_raid_captive_gain: float = 1.0
# 生贄 (§2.5): 捕虜 1 体 → 信仰へ変換。即時量なので変換不要 (world.ts SACRIFICE_FAITH)。
var sacrifice_faith: float = 15.0
var male_sacrifice_factor: float = 0.5      # 雄捕虜の生贄は雌の半分 (安い燃料 / world.ts と同値)
# 敵対度 (§13): 残虐な仕打ちで上昇し、解放で下降。0..1 にクランプして
# raid_interval_days() が大規模襲撃間隔へ写像する (KI-08)。即時量なので変換不要。
var hostility_per_human_sacrifice: float = 0.05  # 人間捕虜 1 体の生贄あたり上昇
var hostility_release_drop: float = 0.04         # 人間捕虜 1 体の解放での下降 (控えめ)
# 雄ゴブリン捕虜の平時自動加入 (KI-17)。日次レートを _init() で per-tick へ変換 (KI-02)。
# world.ts の maleCaptiveJoinChancePerTick (基準解像度 10tick/日で 0.02) は
# 日次換算 0.2 (= 0.02 / (tpd/10) = 0.2/tpd) に相当する。
var male_captive_join_chance_per_day: float = 0.2
var male_captive_join_chance_per_tick: float

# --- 苗床 (§2.5/§3-19。捕虜の母体による確定生産。B2 第二増分) ---
# world.ts nurseryPeriodTicks = ticksPerDay * 2 (= 2 日周期)。期間定義そのものなので
# ticks_per_day を直接掛ければ解像度に依らず 2 日になる (_init() で変換)。
var nursery_period_ticks: int
# world.ts nurseryYieldPerCaptive = NURSERY_RATE(0.08) * 2 = 0.16。母体 1 体・1 周期
# あたりの産出数 (イベント単位の係数なので tick 解像度に依らず同値 = KI-02 変換不要)。
var nursery_yield_per_captive: float = 0.16
# 苗床は産み手を緩やかに消耗する。1 体産出あたりの母体消費量 (world.ts CAPTIVE_CONSUME)。
var nursery_captive_consume: float = 0.3
# 人間母体を苗床に使えるか (中立ルートでは不可 §13。v1.0 はゲートのみ実装し既定 true)。
var human_nursery_allowed: bool = true
# 人間母体は大柄ゆえ多産 (基準レートの倍)。消耗も同じ消費量で速く進む (KI-17/23)。
var human_nursery_yield_factor: float = 2.0
# 人間母体の苗床産 1 体あたりの敵対度上昇 (§13)。
var hostility_per_human_nursery_birth: float = 0.03

# --- つがいバフ (§3-6/KI-18/KI-19。奴隷妻化・自然つがい承認で付与) ---
# 雄: 最大HP/HP 加算 (生存力↑)。雌: 仕事/採餌重みの加算 (内政効率↑)。
# いずれも即時加算量なので tick 解像度に依らない (KI-02 変換不要)。
var bond_male_hp_bonus: float = 3.0
var bond_male_fear_reduce: float = 0.1
var bond_female_work_bonus: float = 0.3

# --- 捕虜の自然つがい化 (§3-19/KI-21)。各 tick 平時にごくごく稀に発生。
# world.ts captiveBondChance = 0.002/scale (基準10tick/日) は日次換算 0.02/日に相当する。
var captive_bond_chance_per_day: float = 0.02
var captive_bond_chance_per_tick: float

# --- 3 勢力分離 (§13 / KI-24 残り。world.ts world_params.ts と同じ値・規律) ---
# 常時の業 (小ノイズ層): ゴブリン 2 部族は放置でじわじわ悪化する。人間にドリフトは
# 無い (加害でのみ動く = 中立ルート保護 §14.5.7)。日次で定義し _init() で
# per-tick へ変換する (KI-02。world.ts hostilityDriftPerTickBunta/Kugyo の日次相当)。
var hostility_drift_per_day_bunta: float = 0.002   # ブン・タ＝タ族の自然悪化 (友好的 = 最遅)
var hostility_drift_per_day_kugyo: float = 0.012   # 苦魚族の自然悪化 (同種に容赦ない = 最速)
var hostility_drift_per_tick_bunta: float
var hostility_drift_per_tick_kugyo: float
# 朝貢 (捕虜返還) 1 体での下降。解放 (hostility_release_drop) より大きい
# (能動的な外交手段の手応え §13)。即時量なので変換不要 (world.ts hostilityTributeDrop)。
var hostility_tribute_drop: float = 0.1
# 敵対度ゼロ同士のときゴブリン襲撃が苦魚族である割合 (残りはブン・タ＝タ)。
# 即時量なので変換不要 (world.ts kugyoBaseRaidShare)。
var kugyo_base_raid_share: float = 0.7

# --- トーテムランク (§3 / P3-04) ---
# 累計信仰 (cum_faith) がしきい値を超えるとランクが上がる (減らない)。残高キャップ・
# シャーマン任命枠・奇跡の性能/消費が連動する。しきい値は cycle.ts の RANK_THRESHOLDS
# を Godot の信仰経済規模 (faith_per_shaman=2.0/日) へ縮尺した暫定値 (§NUMBERS)。
var rank_thresholds: Array = [30.0, 80.0, 160.0, 280.0]
var faith_base_cap: float = 12.0       # 信仰残高キャップ (ランク 0)。超過は累計のみ積む (§3)
var faith_cap_per_rank: float = 8.0    # ランクごとのキャップ上積み
var shaman_base_slots: int = 1         # シャーマン任命枠 = base + rank (上限であって強制でない KI-03)
var miracle_rank_gain: float = 0.25    # 奇跡の性能/消費の一律ランクアップ率 (§4)

# --- 奇跡 (§4) ---
# 信仰残高を消費する即時介入。コスト/効果は固定値 × miracle_mult (ランク連動) で、
# レートではなく即時量なので _init() の per-tick 変換は通さない (KI-02 の対象外)。
# 持続時間だけは日数で定義し _init() で tick へ変換する。数値は §NUMBERS 暫定。
var lightning_cost: float = 4.0        # 嘲りの稲妻: 1 回の発動コスト (信仰残高)
var lightning_damage: float = 8.0      # 命中した敵への固定ダメージ (enemy_hp=6 を一掃)
var mites_cost: float = 3.0            # 恵みのパン虫: 平時の食料補給 (面的・維持系)
var mite_blessing_count: int = 4       # 1 回で湧くパン虫の頭数 (ランクで増える)
var honor_cost: float = 5.0            # 名誉ある死: 対象 1 体を激昂させる (博打・捨て身)
var honor_attack_mult: float = 1.5     # 激昂中の攻撃倍率 (恐怖なし・死ぬまで戦う)
var mud_cost: float = 6.0              # 泥の抱擁: 一時的な泥壁で侵入経路を塞ぐ (防御)
var mud_wall_ticks: int                # 泥壁の寿命 (0.25 日を変換。ランクで延びる)
var rage_cost: float = 8.0             # 抑えられない怒り: 範囲の敵を同士討ちさせる (間接)
var rage_radius: int = 4               # 範囲 (チェビシェフ距離)
var rage_ticks: int                    # 同士討ちの持続 (0.15 日を変換。ランクで延びる)
var summon_cost: float = 10.0          # 下僕召喚: 即時 1 体 (消費重く常用不可。頭数上限の対象)

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
# 牧場へ寄せる目標割合。雌は採集 (T4) へ移したぶん、牧場プールが雄のみになり
# 供給が上振れしないよう 0.34 → 0.30 へ下げる (採集の純増を相殺する置換)。
var ranch_assign_frac: float = 0.30    # 無役成体のうち牧場へ寄せる目標割合

# --- キノコ採集 (T4 メスの仕事。巣内のキノコ床から摘み集積所へ運ぶ) ---
var forage_regrow_ticks: int          # 摘んだ後の再生長 (1.5 日を _init() で変換)
# 1 回の運搬で集積所に加わる食料 (一食分。イベント単位なので KI-02 変換不要)。
var forage_carry_value: float = 1.0

# --- 巣外の出現物 (§11.5 昼の外征の縮小版: 採取系のみ) ---
var field_spawn_per_tick: float    # 自然湧き確率 (日次 2.5 を変換。昼のみ判定 = 実効 ≈ 1.75 個/日)
var field_max: int = 2             # 同時存在の上限
var field_amount_min: int = 2      # 出現物 1 つの収量の下限 (一食単位)
var field_amount_spread: int = 4   # 収量 = min + next_int(spread) → 2〜5 食
# 1 運搬で集積所に加わる食料 (一食分。イベント単位なので KI-02 変換不要)。
var field_carry_value: float = 1.0

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
	day_ticks = int(tpd * 0.7)
	hunger_rate = (1.0 / 1.2) / tpd
	sleep_rate = 1.0 / tpd
	hp_regen_per_tick = 1.5 / tpd
	sleep_relieve_per_tick = 4.5 / tpd
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
	field_spawn_per_tick = 2.5 / tpd
	mite_spawn_per_tick = 1.2 / tpd
	mite_move_per_tick = 30.0 / tpd
	mite_retarget_per_tick = 24.0 / tpd
	starve_hp_per_tick = 6.0 / tpd
	faith_per_shaman_tick = 2.0 / tpd
	totem_repair_per_tick = 20.0 / tpd
	move_per_tick = 150.0 / tpd
	enemy_move_per_tick = 110.0 / tpd
	wander_retarget_per_tick = 8.0 / tpd
	forage_regrow_ticks = int(1.5 * tpd)
	mud_wall_ticks = int(0.25 * tpd)
	rage_ticks = int(0.15 * tpd)
	male_captive_join_chance_per_tick = male_captive_join_chance_per_day / tpd
	hostility_drift_per_tick_bunta = hostility_drift_per_day_bunta / tpd
	hostility_drift_per_tick_kugyo = hostility_drift_per_day_kugyo / tpd
	nursery_period_ticks = ticks_per_day * 2
	captive_bond_chance_per_tick = captive_bond_chance_per_day / tpd
