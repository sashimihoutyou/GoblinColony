extends RefCounted
class_name SimParams
## 力学定数の単一の真実源 (KI-01)。
##
## game_spec_v1.md §3-10 / §6 (§NUMBERS) と src/sim/params.ts を基に、
## α版 (空間あり・オートプレイ) で必要な定数だけを GDScript へ移植したもの。
## 未確定数値 (§NUMBERS) は暫定値。安易に変えると KI-22/25 の相互作用が崩れる。

# --- 時間 (§3-10) ---
var ticks_per_day: int = 20      # 1日 = 20 tick
var day_ticks: int = 12          # 昼 = tick 0..11
var final_day: int = 30          # 規定日数 (最終日にラストバトル)

# --- 個体ステートマシン (state_machine.ts defaultStateMachineParams) ---
var fear_hp_frac: float = 0.45
var dying_hp_frac: float = 0.25
var fear_clear_ticks: int = 8
var hunger_on: float = 0.7
var hunger_off: float = 0.2
var sleep_on: float = 0.8
var sleep_off: float = 0.15
var hunger_rate: float = 0.01
var sleep_rate: float = 0.008
var hp_regen_per_tick: float = 0.15
var hunger_relieve_per_tick: float = 0.2
var sleep_relieve_per_tick: float = 0.15
var unique_downed_grace_ticks: int = 30

# --- 戦闘 (§3-4 / §8 簡易ランチェスター) ---
var goblin_attack: float = 1.2   # 1 tick あたり攻撃力 (隣接敵へ)
var enemy_attack: float = 1.0
var enemy_hp: float = 6.0
var equip_bonus: float = 0.3     # 装備ボーナス +30% (§3-16)

# --- 襲撃スケジューラ (§3-5 / §3-7) ---
var base_enemies: int = 5        # 大規模襲撃の基礎頭数
var enemy_per_day: float = 0.4   # 日が進むごとの規模増加
var big_raid_interval_peace: int = 5   # 敵対度 0 のときの間隔 (日)
var big_raid_interval_max: int = 1     # 敵対度 MAX のときの間隔 (日)
var small_raid_prob: float = 0.3       # 小規模襲撃 (恵み) の 1 日あたり発生確率
var final_mult: float = 2.5            # ラストバトル倍率 (FINAL_MULT)

# --- 増殖 (§3-6) ---
var court_base_chance: float = 0.15    # 1 tick あたり求愛成功基礎確率
var pregnancy_ticks: int = 20          # 妊娠から出産まで (= 1 日)
var child_grow_ticks: int = 20         # 子→成体 (= 1 日)
var litter_weights: Array = [0.30, 0.30, 0.18, 0.12, 0.06, 0.04]  # 一腹 1..6
var surge_trigger: float = 0.25        # 損耗割合がこれを超えると妊娠率バフ発火
var surge_gain: float = 2.0
var surge_max: float = 1.5
var surge_decay: float = 0.2

# --- 事故死 (§3-3 / §2.5 放浪レイヤー) ---
var accident_prob: float = 0.002       # 放浪中 1 tick あたりの事故死確率

# --- 頭数 (§2.5 二段収束) ---
var start_goblins: int = 10
var cap_pop: int = 40                  # 頭数上限 (CAP_POP_MAX)
var fledge_grace_ticks: int = 40       # 上限超過が続いたら巣立ち (安全弁)

# --- 食料 (§3-11) ---
var food_per_rancher_tick: float = 0.3 # ネズミ牧場の割当ゴブリンあたり生産
var food_eat_amount: float = 1.0       # 空腹解消 1 回の消費

# --- 信仰 (§3-1。α版は集計のみ) ---
var faith_per_shaman_tick: float = 0.1

var seed: int = 0
