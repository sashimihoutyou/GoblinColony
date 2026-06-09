/**
 * 個体ゴブリンの型 (§5 自律行動 AI)。
 *
 * KI-09 §14.5.1 の保存対象②(個体ごと) を満たす:
 *   id / HP / 現ステート / 性格 / 役職 / 妊娠フラグと経過tick /
 *   ヒステリシスの向き / 外征中なら帰還tick / つがい関係 (将来) / ユニーク専用フラグ。
 * これらはすべてプレーンな値で、JSON でまるごと保存できる。
 *
 * 第一期スコープ: 位置・パス探索は持たない。ステート遷移・欲求・HP の
 * 力学に絞り、集計モデル (cycle.ts) の安定帯と照合してから空間を足す。
 */

/** §5 ステート (上から優先・数値が小さいほど高優先)。 */
export enum GoblinState {
  Dead = 0, // 死亡 (終端)
  Enraged = 1, // 激昂 (逃げず欲求も変化しない / 奇跡「名誉ある死」の受け皿)
  Fear = 2, // 恐怖 (敵から離れる。安全確認で解除)
  Combat = 3, // 戦闘
  Dying = 4, // 瀕死 (寝床へ)
  Hungry = 5, // 空腹
  Sleep = 6, // 睡眠
  Work = 7, // 仕事
  Wander = 8, // 放浪
}

/** 役職 (§7 部屋システム / §2.5 巣立ち選定で「無役」が流動プール)。 */
export enum Role {
  None = 0, // 無役 = 流動的な労働力プール (派遣・巣立ち対象)
  Shaman = 1,
  Chief = 2, // 族長 (ユニーク・恐怖を持たない盾 §8)
  WitchDoctor = 3,
  NurseryHost = 4, // 苗床配置 (巣の機能として留まる)
  Concubine = 5, // 側室 (奴隷妻 / KI-19)。娶られた捕虜。戦線・労働に出ず子のみ産む。
}

/**
 * 性別 (世界観バイブル: ゴブリンは雌雄で気質が大きく異なる)。
 * - 雄 (Male): バカで突撃しがち、数多く産まれる。戦闘の主力で恐怖耐性が高い。
 * - 雌 (Female): 食べ物やカラフルなものに目がなく、戦闘からすぐ逃げる。
 *   希少 (出生比 7:3) で、増殖の律速を握る = 巣の生命線。
 * この非対称性が「巣の人間関係 (ゴブリン関係) の観察」の中心になる。
 */
export enum Sex {
  Male = 0,
  Female = 1,
}

/**
 * 性格 (§5: 閾値と重みを変える。順位は原則固定)。
 * 各値は基準閾値に対する乗算・加算の補正。
 */
export interface Personality {
  /** 恐怖の発火 HP 閾値の補正。臆病=高い(早く逃げる)/勇敢=低い(粘る)。 */
  fearHpBias: number;
  /** 空腹閾値の補正。食いしん坊=早い。 */
  hungerBias: number;
  /** 採掘/仕事の優先重み。穴掘り好き=高い。 */
  workBias: number;
  /** 採餌・収集への重み。高いほど食料/光り物に惹かれる (雌で高い)。 */
  forageBias: number;
}

export interface Goblin {
  id: number;
  sex: Sex; // 雌雄 (世界観バイブル: 気質が大きく異なる)
  state: GoblinState;
  role: Role;
  hp: number; // 0..maxHp
  maxHp: number;
  hunger: number; // 0(満腹)..1(限界)
  sleepiness: number; // 0..1
  personality: Personality;

  // --- ヒステリシスの向き (KI-09: 必ず保存。境界往復=ジッタ防止 §5) ---
  // 各欲求が「上昇中(true)=満たすべき / 下降中(false)=満ちた」のラッチ。
  hungerLatched: boolean; // true: 空腹を満たしに行く状態に入っている
  sleepLatched: boolean;

  // --- 進行中フラグ (§2.5 / KI-09 保存対象) ---
  pregnant: boolean;
  pregnantTicks: number; // 妊娠してからの経過 tick
  expeditionReturnTick: number | null; // 外征中なら帰還 tick、いなければ null

  isUnique: boolean; // 族長・アミナ等 (事故死無効・瀕死保護 §8)
  downedTicks: number | null; // ユニークが HP0 で倒れてからの経過 (搬送猶予 §8)

  // 恐怖中、敵がいなかった連続 tick (安全確認ベースの解除 §5)。
  // 0 = 恐怖でない or 直前に敵を見た。
  fearSafeTicks: number;
  // 子ゴブリンとして生まれた tick。null = 成体。childGrowTicks 経過で成体化 (§2.5)。
  childBornTick: number | null;

  // --- 求愛・つがい (乱婚制 / KI-18) ---
  // つがいの相手 id。null = 固定の相手なし (乱婚で誰とでも)。
  mateId: number | null;
  // お気に入りの相手 id。片思い可。求愛成功率を上げる。null = なし。
  favoriteId: number | null;
  // 魅力の指紋 (相性計算の種)。2個体の charmSeed から相性を決定的に算出する。
  // 全ペアの相性表 (O(n^2)) を持たず、個体ごと 1 値で済ませる。
  charmSeed: number;
  // 求愛/性行為の進行 tick (寝床へ移動中・最中の管理)。-1 = 関与していない。
  matingTicks: number;
  // 現在の性行為の相手 id (寝床に一緒にいる相手)。null = 関与なし。
  matingWithId: number | null;
  // つがいを失った雄は悲しみで二度と繁殖しない (永続・KI-19)。
  // 雌は喪失しても false のまま (あっさり次を探す)。KI-09 保存対象。
  bereaved: boolean;

  // 捕虜とゴブリンが自然に絆を結び、プレイヤーの承認を待つ状態 (KI-21)。
  // true = この個体は自然つがい化した捕虜側で、承認/引き離し待ち。
  // 承認で false + 巣に貢献開始、引き離しで処刑/追放。
  pendingBond: boolean;

  // --- 出自 (死亡ログ・血統用 / KI-20) ---
  bornTick: number; // 生まれた (or 巣に加わった) tick。childBornTick と違い不変。
  motherId: number | null; // 母の id (自然出産のみ。召喚/捕虜は null)。
  fatherId: number | null; // 父の id。
  origin: GoblinOrigin; // どこから来た個体か。
}

/** 個体の出自 (死亡ログ・物語追跡用)。 */
export enum GoblinOrigin {
  Founder = 0, // 初期メンバー
  Born = 1, // 巣で自然出産
  Nursery = 2, // 苗床産
  Summoned = 3, // 信仰で召喚
  CaptiveJoined = 4, // 捕虜から加入 (雄ゴブリンの即加入)
  Concubine = 5, // 奴隷妻/夫として娶られた捕虜
}

/** 個体生成のデフォルト。 */
export function makeGoblin(
  id: number,
  personality: Personality,
  role = Role.None,
  sex: Sex = Sex.Male,
  opts: {
    bornTick?: number;
    motherId?: number | null;
    fatherId?: number | null;
    origin?: GoblinOrigin;
  } = {}
): Goblin {
  return {
    id,
    sex,
    state: GoblinState.Wander,
    role,
    hp: sex === Sex.Female ? 8 : 10, // 雌はやや脆い (戦闘不向き)
    maxHp: sex === Sex.Female ? 8 : 10,
    hunger: 0,
    sleepiness: 0,
    personality,
    hungerLatched: false,
    sleepLatched: false,
    pregnant: false,
    pregnantTicks: 0,
    expeditionReturnTick: null,
    isUnique: role === Role.Chief,
    downedTicks: null,
    fearSafeTicks: 0,
    childBornTick: null,
    mateId: null,
    favoriteId: null,
    // charmSeed: id から決定的に散らす (rng を増やさずスナップショット安全)。
    charmSeed: (Math.imul(id ^ 0x9e3779b9, 2654435761) >>> 0) % 1000,
    matingTicks: -1,
    matingWithId: null,
    bereaved: false,
    pendingBond: false,
    bornTick: opts.bornTick ?? 0,
    motherId: opts.motherId ?? null,
    fatherId: opts.fatherId ?? null,
    origin: opts.origin ?? GoblinOrigin.Founder,
  };
}

/**
 * 2 個体の相性 (0..1)。両者の charmSeed から決定的に算出する。
 * 全ペアの相性表 (O(n^2) メモリ) を持たず、個体の charmSeed 1 値ずつで
 * 対称な相性を導く。a,b の順序によらず同じ値を返す (対称性)。
 * 高いほど「気が合う」= 求愛成功率・つがい成立率が上がる。
 */
export function compatibility(a: Goblin, b: Goblin): number {
  // 対称にするため小さい方・大きい方で混ぜる。
  const lo = Math.min(a.charmSeed, b.charmSeed);
  const hi = Math.max(a.charmSeed, b.charmSeed);
  const mixed = (Math.imul(lo + 1, 2246822519) ^ Math.imul(hi + 1, 3266489917)) >>> 0;
  return (mixed % 1000) / 1000;
}

/** 平均的性格 (補正なし)。 */
export const neutralPersonality: Personality = {
  fearHpBias: 0,
  hungerBias: 0,
  workBias: 0,
  forageBias: 0,
};

/**
 * 性別ごとのデフォルト性格 (世界観バイブルの気質を性格バイアスに翻訳)。
 * jitter (個体差) を rng から渡して散らす。新しい仕組みを足さず、既存の
 * ステートマシンが読む閾値・重みを性別で振るだけ (アーキテクチャ不変)。
 */
export function sexedPersonality(sex: Sex, jitter: () => number): Personality {
  if (sex === Sex.Female) {
    // 雌: 臆病 (恐怖閾値↑=早く逃げる)、食い意地・収集癖が強い、仕事は控えめ。
    return {
      fearHpBias: 0.25 + jitter() * 0.1, // HP が高くても早めに逃げる
      hungerBias: 0.05 + jitter() * 0.05,
      workBias: -0.1 + jitter() * 0.2,
      forageBias: 0.6 + jitter() * 0.3, // 光り物・食べ物に目がない
    };
  }
  // 雄: 勇敢/無謀 (恐怖閾値↓=粘る/突撃)、仕事好き、収集には無頓着。
  return {
    fearHpBias: -0.2 + jitter() * 0.15, // HP が低くても突っ込む
    hungerBias: jitter() * 0.05,
    workBias: 0.15 + jitter() * 0.25,
    forageBias: jitter() * 0.15,
  };
}
