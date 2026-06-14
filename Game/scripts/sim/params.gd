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
# 難度 (易=0/並=1/難=2。§14.5.2: 初期盤面は共通、難度差は「初期敵対度位置」と
# 「最初の襲撃の早さ=助走窓」のみ。本当の難度はプレイ中の §13 4 ルート選択で立てる)。
# 並 (=1) は確定済み安定帯の基準 (初期敵対度 0・通常スケジュール) を厳守。難 (=2) は
# 初期敵対度を上げて最初の襲撃を早める。易 (=0) は助走窓を延ばすだけ (敵対度は並と同じ 0)。
var start_human_hostility_by_diff: Array = [0.0, 0.0, 0.15]
var start_tribe_hostility_by_diff: Array = [0.0, 0.0, 0.15]
var first_raid_grace_easy_days: float = 2.0   # 易のみ最初の大規模襲撃をこの日数ぶん遅らせる
# ラストバトルの波状期 (§11/B10): 最終日の手前 final_wave_days 日間は、敵対度に
# よらず襲撃間隔を final_wave_interval_days (下限) でキャップし、波状に圧を高める
# (静かなまま最終決戦に入らせない climax の助走)。即時量・日単位。
var final_wave_days: int = 4
var final_wave_interval_days: float = 2.0

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

# --- 食料従属 (§2.5・B3。world.ts と同じ規律・同値)。在庫(food)/頭数の比率が
# 閾値を割ると求愛成立率を抑制 + 妊娠個体が確率流産、超えると控えめなバフ。
# Godot は実食料経済 (牧場生産・集積所消費) を持つので不足は内生的に起こりうる。
var food_per_capita_shortage: float = 0.5   # 在庫/頭数がこれ未満なら食料不足
var food_per_capita_surplus: float = 2.0    # 在庫/頭数がこれ超なら食料過剰
var food_shortage_court_mult: float = 0.5   # 不足時、求愛成立率に乗じる係数 (<1)
var food_surplus_court_bonus: float = 0.15  # 過剰時、求愛成立率の乗数へ加える上乗せ
var food_shortage_miscarry_per_day: float = 0.1  # 不足時、妊娠個体が1日に流産する確率
var food_shortage_miscarry_per_tick: float       # _init() で per-tick へ変換 (KI-02)

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

# --- 工房 (§7 / B6。キノコ農園=薬草 / 泥鍛冶屋=装備。牧場と同じ「稼働個体数 ×
# 日次レート」方式。部屋は A1 建築 + プレイヤー任命で稼働する)。日次→tick 変換 (KI-02)。
var herb_per_farmer_tick: float        # キノコ農園 1 稼働あたりの薬草 (日次 4.0 を変換)
var equip_per_smith_tick: float        # 泥鍛冶屋 1 稼働あたりの装備 (日次 1.5 を変換)
# --- 装備経済 (§14.5.6 / spec 3-16 / B8) ---
# 襲撃開始時、未装備の戦闘員が共有在庫 (equipment) から 1 ずつ取って装備する
# (id 順・在庫が尽きるまで)。装備は攻撃 +equip_bonus。死亡で消滅。襲撃終了ごとに
# 軽い消耗で一定確率に壊れる (装備需要を循環させる §15 ダイヤル)。
var equip_wear_chance: float = 0.2     # 襲撃 1 回ごとに装備が壊れる確率 (イベント単位)

# --- まじない医 (§6 / spec 3-17 / B4)。効果は控えめ (D1 調整前提。GDD §6
# 「被ダメ低下は決定打にせず気休め程度に」)。
# 平時: 巣内の負傷個体 (hp < max_hp で寝床休息中) の HP 回復を加速。herb を消費し、
# herb=0 なら加速なし (素の hp_regen のみ = キノコ農園との経済従属 §7/B6)。
var medic_heal_bonus_per_day: float = 1.5   # 加速ぶん (hp_regen_per_tick=1.5/日に上乗せ→倍速)
var medic_heal_bonus_per_tick: float
# 治療 1 体・1 tick あたりの薬草消費 (日次で定義し変換。KI-02)。
var herb_per_medic_heal_per_day: float = 0.5
var herb_per_medic_heal_per_tick: float
# 戦時 (spec 3-17): 防衛ライン (DefensePoint) から巣中心方向へ下がる後衛座標までの
# タイル数 (確定値)。後衛のまじない医は被ダメ低下 + 近接の負傷個体を遠距離治療する。
var medic_backline_offset: int = 3
var medic_dmg_reduce: float = 0.2           # 後衛時の被ダメ低下 (気休め程度)
var medic_field_heal_radius: int = 3        # 遠距離治療の範囲 (チェビシェフ距離)
var medic_field_heal_per_day: float = 3.0   # 遠距離治療 1 体・1 日あたりの回復量
var medic_field_heal_per_tick: float

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

# --- §11.5 外征の種別・距離抽選 (A4) ---
# 種別ロット (FieldResource.Kind 0..6 の順。合計 1.0。FORAGE が主役、MAIDEN は稀)。
# 採取系 (FORAGE) を変えると既存の食料供給バランスが崩れるため最も大きく確保する。
var field_kind_weights: Array = [
	0.50,  # FORAGE   植物 (既存)
	0.16,  # ANIMAL   動物
	0.10,  # TRAVELER 旅人
	0.10,  # WANDERER ゴブリン放浪者
	0.08,  # CAMP     敵性キャンプ
	0.04,  # RUINS    廃墟
	0.02,  # MAIDEN   行き倒れの少女 (稀)
]
# 距離 (0=近い/1=遠い) の抽選。遠いほどリターン良いが往復が長く、襲撃に間に合わない
# ことがある (§11.5「遅れて来る増援」)。近場優先 = 遠いは控えめ。
var field_far_chance: float = 0.35
# 遠い出現物は巣口から離れたマップ縁寄り (_field_tiles_far)。近い出現物は巣口に近い
# 内側 (_field_tiles_near)。両方が空なら通常の _field_tiles へフォールバック。
var field_far_min_gate_dist: int = 8  # 遠い候補と判定する巣口からのチェビシェフ距離下限

# --- §11.5 種別ごとのリターン (A4。FORAGE は既存挙動を一切変えない) ---
# ANIMAL: 食料 (多め) + 低確率でゴブリン捕虜 (狩りで弱った放浪個体を保護)。
var field_animal_carry_value: float = 2.0     # FORAGE の field_carry_value(1.0) より多い
var field_animal_captive_chance: float = 0.08 # 持ち帰り時の捕虜獲得ロール
# RUINS: 建材 mud (まとめて) + 低確率で gems。
var field_ruins_mud_value: float = 3.0
var field_ruins_gem_chance: float = 0.12
var field_ruins_gem_value: float = 1.0
# TRAVELER: 交易 (B5 までの最小実装)。少量 gems か herb のどちらかを持ち帰る。
var field_traveler_gem_chance: float = 0.5
var field_traveler_gem_value: float = 1.0
var field_traveler_herb_value: float = 1.0
# 業の漏れ (§13): 派遣のたび低確率で粗相し、人間敵対度がわずかに上がる
# (RNG 消費順序を変えないよう、TRAVELER 到着判定の最後に追加の 1 ロールとして置く)。
var field_traveler_faux_pas_chance: float = 0.05
var field_traveler_faux_pas_hostility: float = 0.02
# WANDERER: 帰還で +1 加入。部族差 (§13 自然悪化レートと同じ傾向: ブン・タ＝タが
# 加入しやすく、苦魚族はほぼ寝返らない)。"" (出自不明) は中間値。
var field_wanderer_join_chance_bunta: float = 0.85
var field_wanderer_join_chance_kugyo: float = 0.05
var field_wanderer_join_chance_other: float = 0.5
# CAMP: 戦闘系。出発前に共有装備在庫から武装 (B8 _equip_fighters_from_stock 流用)。
# 勝率は派遣人数 vs キャンプ戦力の比で単調に変化 (人数が多いほど安全)。
# win_chance = clamp(headcount / (headcount + camp_strength), min, max)。
var field_camp_strength: float = 2.0          # キャンプの基礎戦力 (派遣人数と同じ単位)
var field_camp_win_chance_min: float = 0.15   # 1 体だけで突っ込んでも全くのゼロにはしない
var field_camp_win_chance_max: float = 0.95   # 大量投入でも僅かに不確実性を残す
# 勝利: gems + equipment + 捕虜 (ゴブリン優先で敵勢力捕虜)。
var field_camp_win_gem_value: float = 1.0
var field_camp_win_equip_value: float = 1.0
var field_camp_win_captive_chance: float = 0.3
# 敗北: 即・致命にしない (§0/§9)。負傷 (HP 減) のみ。死亡なし。
var field_camp_loss_hp_min: float = 1.0
var field_camp_loss_hp_spread: float = 2.0
# MAIDEN: 行き倒れの少女 → 人間雌捕虜としてカウント (アミナの種、§14)。
# 連れ帰った直後は通常の cap_female_human と同じ枠に入るが、A4 のアミナ装置が
# 別途その個体を保持・観察する (world 側のタイマーで管理 / 消費系に渡さない限り)。

# --- §14 アミナ装置 (A4。人間雌捕虜を消費せず保持し続けると懐く) ---
# 保持ティック数 (日次で定義し _init() で tick へ変換)。MAIDEN 到着〜加入までの目安。
var amina_hold_days: float = 3.0
var amina_hold_ticks: int
# 懐き予兆 (foreshadow) を出すタイミング: 保持期間のうちこの割合を過ぎたら
# 「懐き予兆」イベントを 1 回だけ発火する (不可逆点が近いことを知らせる)。
var amina_foreshadow_frac: float = 0.5

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

# --- 資源・ジョブ (§3-11/§3-12/§3-15。コスト・収量は §NUMBERS 暫定) ---
# 建材は当面 mud (泥) に一本化する。wood (枝) は外征 (§11.5/A4) の戦利品経路が
# 主供給のため、採掘からは出さない (§7「供給は既存挙動に寄せる」)。
var start_mud: float = 6.0            # 初期盤面「少量の建材」(GDD §14.5.2)
var mine_yield_mud: float = 4.0       # 採掘ノード 1 つの建材収量 (イベント単位)
var gem_mine_chance: float = 0.15     # 採掘完了ごとの宝石ロール (§7 採掘で稀)
var mine_work_per_tick: float         # 採掘進捗 (1 ノード 0.5 日ぶんの労働を変換)
var build_work_per_tick: float        # 建設進捗 (1 部屋 1.0 日ぶんの労働を変換)
var repair_work_per_tick: float       # 壁修復進捗 (1 枚 0.25 日ぶんの労働を変換)
var wall_repair_cost: float = 1.0     # 壁修復 1 枚の建材 (イベント単位)
# 掘削 (§10 巣穴拡張): 素の壁を掘って床化し、掘り出した土から少量の建材を得る。
# 鉱脈より遅く・収量も少ない (拡張が主目的で建材は副産物。大量供給は鉱脈/外征)。
# マップ大半が岩なので労働律速の持続供給源 (§15 で量を調整)。
var dig_yield_mud: float = 1.0        # 壁 1 枚の掘削で得る建材 (イベント単位)
var dig_work_per_tick: float          # 掘削進捗 (1 枚 0.6 日ぶんの労働を変換)
# ジョブ取得の性格重み (§3-12「最寄り×性格重み」): work_bias 1.0 の個体は
# job_affinity_tiles タイルぶん遠いジョブでも同点とみなす距離換算。
var job_affinity_tiles: float = 8.0
# 部屋テンプレート (spec 3-15 固定サイズ) と建材コスト (§NUMBERS 暫定)。
const ROOM_BUILD_SIZE := {
	TileMapData.RoomType.RAT_RANCH: Vector2i(4, 3),
	TileMapData.RoomType.MUSHROOM: Vector2i(3, 3),
	TileMapData.RoomType.SMITHY: Vector2i(3, 3),
	TileMapData.RoomType.NURSERY: Vector2i(4, 3),
	TileMapData.RoomType.WITCH: Vector2i(3, 3),
}
const ROOM_BUILD_COST := {
	TileMapData.RoomType.RAT_RANCH: 6.0,
	TileMapData.RoomType.MUSHROOM: 4.0,
	TileMapData.RoomType.SMITHY: 6.0,
	TileMapData.RoomType.NURSERY: 6.0,
	TileMapData.RoomType.WITCH: 4.0,
}

# --- ブリーチング + 防衛配分 (§9 / §3-17 / §3-20。数値は §NUMBERS 暫定) ---
var breacher_from_day: int = 8       # この日以降の大規模襲撃に壁破壊役が混ざる (襲撃カーブ §15)
var breacher_every: int = 4          # 何体に 1 体を壁破壊役にするか (決定的。1/4 = 25%)
# 壁 1 枚 (WALL_HP=20) を割る速さ。日次で定義し _init() で per-tick 整数へ変換
# (wall_hp が int 配列のため最低 1/tick。既定 240/日 × tpd=240 → 1/tick = 壁 1 枚
# 約 0.083 日 ≒ 実 7.5 秒。泥の抱擁 (寿命 0.25 日) で塞ぎ直す猶予が出る設計)。
var wall_damage_per_day: float = 240.0
var wall_damage_per_tick: int
var wall_rebuild_cost: float = 2.0   # 破られた壁跡の再建コスト (修復 1.0 より重い §9 復興)
var totem_panic_radius: int = 6      # 敵がトーテムへこの距離まで踏み込んだら環防衛へ収束

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
	food_shortage_miscarry_per_tick = food_shortage_miscarry_per_day / tpd
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
	herb_per_farmer_tick = 4.0 / tpd
	equip_per_smith_tick = 1.5 / tpd
	medic_heal_bonus_per_tick = medic_heal_bonus_per_day / tpd
	herb_per_medic_heal_per_tick = herb_per_medic_heal_per_day / tpd
	medic_field_heal_per_tick = medic_field_heal_per_day / tpd
	field_spawn_per_tick = 2.5 / tpd
	mite_spawn_per_tick = 1.2 / tpd
	mite_move_per_tick = 30.0 / tpd
	mite_retarget_per_tick = 24.0 / tpd
	starve_hp_per_tick = 6.0 / tpd
	faith_per_shaman_tick = 2.0 / tpd
	totem_repair_per_tick = 20.0 / tpd
	# 壁破壊は int 配列 (wall_hp) を削るので 1 以上へ丸める (KI-02 の整数版)。
	wall_damage_per_tick = maxi(1, roundi(wall_damage_per_day / tpd))
	# ジョブの労働量 = 1 体が張り付いたときの所要日数の逆数 (KI-02)。
	mine_work_per_tick = 1.0 / (0.5 * tpd)
	build_work_per_tick = 1.0 / (1.0 * tpd)
	repair_work_per_tick = 1.0 / (0.25 * tpd)
	dig_work_per_tick = 1.0 / (0.6 * tpd)
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
	amina_hold_ticks = int(amina_hold_days * tpd)
