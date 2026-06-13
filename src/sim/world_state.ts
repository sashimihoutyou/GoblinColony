/**
 * World 層の状態 (§14.5.1 の保存 3 分類に対応)。
 *
 * 個体ステートマシン (state_machine.ts) を群れ全体で tick 駆動し、
 * 戦闘解決・事故死・増殖・巣立ち (§2.5/§8) の離散イベントを降らせる。
 * これらの集計挙動が、机上検証済みのマクロ安定帯 (cycle.ts) と
 * 整合することを照合で確認する (KI 横断: 力学を共有せよ)。
 *
 * KI-09 保存 3 分類:
 *   ① グローバル: tick/day/faith/totemRank/各敵対度/RNG 状態 ...
 *   ② 個体ごと: goblins 配列 (各 Goblin が id/HP/state/flags を保持)
 *   ③ 進行中イベント: surge 残量・巣立ち超過の経過・襲撃予兆の進行 ...
 * すべてプレーン値で JSON 化でき、丸ごとスナップショット保存できる。
 */
import type { RngState } from "./rng.ts";
import type { Goblin, Sex, Role, GoblinOrigin } from "./goblin.ts";

/** 死因 (死亡ログ用 / KI-20)。 */
export type DeathCause =
  | "accident" // 事故死 (§2.5 離散イベント)
  | "combat" // 戦闘死
  | "fledge" // 巣立ち (去った = 巣からの除外)
  | "unique_downed" // ユニークが搬送猶予を超えて死亡 (§8)
  | "execution" // プレイヤーによる処刑 (つがい引き剥がし等 / KI-21)
  | "banishment"; // プレイヤーによる追放 (KI-21)

/**
 * 死亡ログ 1 件 (KI-20)。死亡個体の属性スナップショットを丸ごと残し、
 * バグ調査と物語の追跡を可能にする。
 */
export interface DeathLogEntry {
  tick: number; // 死亡 tick
  day: number; // 死亡日
  id: number;
  sex: Sex;
  role: Role;
  origin: GoblinOrigin;
  bornTick: number; // 生まれた/加わった tick
  ageDays: number; // 生存日数 ((tick-bornTick)/ticksPerDay)
  hp: number;
  maxHp: number;
  state: number; // 死亡時のステート (Dead 直前の値が取れない場合は Dead)
  mateId: number | null;
  favoriteId: number | null;
  motherId: number | null;
  fatherId: number | null;
  bereaved: boolean;
  cause: DeathCause;
}

/** 襲撃フェーズ (§9 フェーズ設計)。 */
export type RaidPhase =
  | "peace" // 平時 (巣立ち判定が動くのはここ)
  | "omen" // 予兆 (配分を決める猶予)
  | "combat"; // 交戦 (この間はセーブしない / 巣立ちしない §2.5/§14.5.1)

export interface WorldState {
  // --- ① グローバル ---
  tick: number;
  day: number;
  ticksPerDay: number; // 1 日 = N tick (§12 仮置き 10、外征で再調整 §15)
  faith: number;
  cum: number; // 累計信仰 (ランク用・減らない §3)
  totemRank: number;
  capPop: number; // 頭数上限 (建築でのみ増加 §2.5)
  // 人間勢力の敵対度メーター (§13。0=和平 .. 1=MAX)。人間捕虜への残虐な仕打ち
  // (苗床で潰す・生贄) で上昇し、解放/朝貢で下降する。§11/KI-08 の「敵対度連動の
  // 大規模襲撃間隔 (1〜5日)」を駆動する静的難度ダイヤル = プレイヤーの選択で動く
  // 表のメーターであり、KI-10 が却下した「裏で追従する DDA」とは別物。
  // humanHostility > 0 は人間への加害が始まった = 中立ルート (§13) から外れた印。
  humanHostility: number;
  // ゴブリン 2 部族の敵対度メーター (§13 3 勢力分離 / KI-24 残り)。
  // 人間と違い「常時の業」(小ノイズ層 §13) で放置でもじわじわ悪化する (自然位置が
  // やや敵対寄り)。苦魚族は同種に容赦なく悪化が最速、ブン・タ＝タ族は友好的で最遅。
  // 朝貢 (tributeCaptive = 捕虜の返還) で下げられる (§13 双方向化)。
  // 人間メーターにドリフトを乗せないのは §14.5.7 の中立ルート保護のため:
  // humanHostility は「加害でのみ動く」からこそ中立グッドエンドの判定に使える。
  buntaHostility: number;
  kugyoHostility: number;
  rng: RngState;

  // --- 捕虜 (§2.5 ワイルドカード資源 / 性別×種族で出口が変わる) ---
  // 性別導入で捕虜の価値が二極化した (KI-17):
  //   - 雌ゴブリン: 苗床に置ける希少な産み手。遅く持続する基準の母体。
  //   - 雄ゴブリン: 苗床不可。即加入の前衛 or 安価な生贄 (雄は自前で増える)。
  //   - 雌人間: 中立ルート以外なら苗床可 (§2.5 異種交配)。大柄ゆえ多産だが
  //     消耗も速い高価値な母体。中立ルート (§13) では加害不可で生贄/追放も封じ保持のみ。
  //   - 雄人間: 苗床/加入不可。生贄か追放のみ。
  // 連続量 (浮動小数) で保持。スナップショット往復はそのまま通る。
  capMaleGoblin: number;
  capFemaleGoblin: number;
  capMaleHuman: number;
  capFemaleHuman: number;
  nurseryTimer: number; // 苗床の確定生産タイマー (tick)

  // --- ② 個体ごと ---
  goblins: Goblin[];
  nextGoblinId: number;

  // --- 死亡ログ (KI-20。調査・物語追跡用。スナップショット保存対象) ---
  deathLog: DeathLogEntry[];

  // --- ③ 進行中イベント ---
  phase: RaidPhase;
  surge: number; // 損耗時バフ残量 (§2.5 必須骨格 / KI-04)
  foodBuff: number; // 小規模襲撃の食料バフ残量 (§11/KI-05。増殖を底上げ・減衰)
  // 食料在庫 (§2.5・B3: 増殖の食料従属)。単位は「食事回数」(Godot food と同概念)。
  // 生存頭数比例で生産/消費し (KI-02 で tick 次へ変換)、在庫/頭数の比率が
  // 不足/過剰の閾値を割る/超えると求愛成立率・流産率に効く (stepReproduction)。
  foodStock: number;
  overCapTicks: number; // 上限超過が続いた平時 tick (巣立ち猶予 §2.5)
  nextBigRaidTick: number; // 次の大規模襲撃を発火する tick (自動スケジューラ §11)
  enemiesRemaining: number; // 交戦中の残敵数 (0 なら非交戦)
  raidLossThisFight: number; // この戦闘で失った頭数 (参考指標)
  raidStartPop: number; // 戦闘開始時の頭数 (全滅判定の分母)
  raidStartHp: number; // 戦闘開始時の総 HP (損耗 = HP 損失で測る / KI-13)
  raidIsHuman: boolean; // 現襲撃の敵が人間勢力か (撃退時の捕虜種族を決める)
  raidMaleFrac: number; // 現襲撃から取れる捕虜の雄割合
  raidFaction: Faction; // 現襲撃の勢力 (§13。raidIsHuman の精密版・部族の色付け用)
}

/** 3 勢力 (§13): 人間 (強・敵対) / ブン・タ＝タ族 (友好的) / 苦魚族 (容赦ない)。 */
export type Faction = "human" | "bunta" | "kugyo";
