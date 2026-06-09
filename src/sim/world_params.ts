/**
 * World 層のパラメータ。
 *
 * KI-01「力学を一箇所に」: 頭数力学の率は cycle.ts の検証済み既定値
 * (baseParams) を唯一の出典とし、ここでは「日次 → tick 次」への
 * 変換だけを行う。率の値そのものを再定義しない (検証コード間の
 * 力学不整合 = KI-01 の諸悪の根源を避ける)。
 */
import { baseParams } from "./params.ts";
import {
  defaultStateMachineParams,
  type StateMachineParams,
} from "./state_machine.ts";

export interface WorldParams {
  ticksPerDay: number;

  // 個体ステートマシンの定数 (そのまま流用)
  sm: StateMachineParams;

  // 頭数力学 (cycle.ts 由来。1 日あたり率を tick 次へ割る)
  deathPerTick: number; // 事故死: 1 個体が 1 tick に死ぬ確率
  // --- 性別ベースの増殖 (世界観バイブル: 雌が律速・雄が多産) ---
  // 旧 pregnancyChancePerTick は「全個体が妊娠しうる」前提だった。性別導入で
  // 「雌のみが妊娠」に変わるため、全体増殖率を雌人口比で割り戻した、雌 1 体
  // あたりの妊娠率に置き換える。これで群れ全体の増殖は元のマクロ率に近づく。
  pregnancyChancePerFemale: number;
  maleBirthRatio: number; // 生まれる子が雄になる確率 (0.7 = 雄 7 割)
  femaleDeathFactor: number; // 雌の事故死率の倍率 (<1: 逃げ上手で死ににくい)
  pregnancyTicks: number; // 妊娠フラグ → 出産フラグまでの tick
  childGrowTicks: number; // 子 → 通常個体へ成長する tick
  // 1 回の出産で生まれる子の数 (一腹) の累積分布。litterCdf[i] = P(litter <= i+1)。
  // 末尾は必ず 1.0。drawLitterSize が rng と突き合わせて 1..litterCdf.length を引く。
  litterCdf: number[];

  // --- 求愛・つがい (乱婚制 / KI-18) ---
  matingDurationTicks: number; // 寝床にこもる tick (完了で雌が確定妊娠)
  courtBaseChance: number; // 雌 1 体が 1 tick に求愛成立する基礎確率 (相性0.5基準)
  favoriteCourtBonus: number; // お気に入り相手への求愛成功補正
  favoriteChance: number; // 性行為後、相性×これでお気に入り登録
  bondMaleHpBonus: number; // つがい雄: 最大 HP 増 (生存力)
  bondMaleFearReduce: number; // つがい雄: 恐怖閾値の引き下げ (より粘る)
  bondFemaleWorkBonus: number; // つがい雌: 仕事/採餌の重み増 (内政効率)

  // --- 雄同士のケンカ / 自然つがい化 (KI-19/KI-21) ---
  rivalryChance: number; // 競合雄ペアがケンカに発展する 1 tick 確率
  rivalryMateBonus: number; // ケンカ強さ: つがい持ちの雄に乗る補正
  rivalryInjury: number; // 敗者が負う HP 減
  captiveBondChance: number; // 捕虜が自然につがい化する 1 tick 確率 (ごく稀)

  // 損耗時バフ (§2.5 / KI-04: 必須骨格)
  surgeTrigger: number;
  surgeGain: number;
  surgeMax: number;
  surgeDecayPerDay: number;

  // 巣立ち (§2.5 安全弁)
  fledgeGraceTicks: number; // 上限超過が続いたら巣立ち発火する平時 tick

  // 戦闘 (§12 一括式 = simulateRaid と同じ係数)
  goblinPower: number;
  enemyPower: number;

  // 族長の盾 (§8: 周囲頭数で HP ボーナス・逓減上限)
  chiefHpPerAlly: number;
  chiefHpBonusMax: number;

  // --- 捕虜 (§2.5 ワイルドカード資源) ---
  // 苗床: 捕虜を産み手とする確定生産 (ラグを迂回する補充 / KI-13)。
  nurseryPeriodTicks: number; // 何 tick ごとに確定生産するか
  nurseryYieldPerCaptive: number; // 1 生産あたり、捕虜 1 人が産む頭数
  nurseryCaptiveConsume: number; // 1 体生むごとに消耗する雌捕虜数
  // 人間の雌捕虜も苗床の母体になれる (§2.5 異種交配: 仔は必ずゴブリン)。人間の
  // 胎は大柄ゆえ多産 = 産出が雌ゴブリンの humanNurseryYieldFactor 倍 (ゴブリンの
  // 残虐さ / 人間雌捕虜の価値高騰)。中立ルート (§13) は人間への加害不可のため
  // humanNurseryAllowed=false でこの出口を封じる (生贄/苗床/売却/朝貢の禁止と整合)。
  humanNurseryAllowed: boolean; // 人間雌捕虜を苗床に置けるか (中立ルートで false)
  humanNurseryYieldFactor: number; // 人間母体の産出倍率 (>1: 多産)

  // --- 人間勢力の敵対度 (§13 メーター → §11 大規模襲撃間隔 / KI-08) ---
  // 残虐な仕打ちで上昇し、解放/朝貢で下降。敵対度が高いほど大規模襲撃が短間隔
  // (高難度) になる。プレイヤーの選択で動く表の静的ダイヤル (KI-10 の DDA とは別)。
  hostilityPerHumanNurseryBirth: number; // 人間母体での 1 出産あたり上昇
  hostilityPerHumanSacrifice: number; // 人間捕虜 1 体の生贄あたり上昇
  hostilityReleaseDrop: number; // 人間捕虜 1 体の解放での下降 (§13 控えめ)
  raidIntervalDaysAtPeace: number; // 敵対度 0 のときの大規模襲撃間隔 (日)
  raidIntervalDaysAtMax: number; // 敵対度 1 (MAX) のときの間隔 (日・最短)
  // 召喚: 信仰を消費して即時頭数補充 (§4 下僕召喚)。
  summonCost: number; // 召喚 1 回の信仰コスト
  summonPop: number; // 召喚 1 回で増える頭数
  // 生贄: 捕虜を信仰へ変換 (§2.5 出口 / §3 燃料)。
  sacrificeFaith: number; // 捕虜 1 人あたりの基準信仰変換量 (雌ゴブリン基準)
  maleSacrificeFactor: number; // 雄捕虜の生贄信仰の倍率 (<1: 雄は安い燃料)
  captiveGainPerRaid: number; // 撃退成功 1 回で得る捕虜数 (総数)
  // 雄捕虜の即加入 (成体なので成長ラグなし。自前の雄より速い前衛 KI-17)。
  maleCaptiveJoinChancePerTick: number; // 投獄中の雄捕虜が加入する 1 tick 確率
  // 信仰蓄積 (シャーマン相当。第一期は頭数比例の簡易版)。
  faithPerTickPerShaman: number;
  shamanRatio: number; // 頭数のうちシャーマンに回す比率 (KI-03)
  faithCap: number; // 信仰残高の上限 (§3 青天井防止)
}

/**
 * 敵勢力ごとの捕虜性別構成 (世界観バイブル §13 の3勢力)。
 * maleFrac = 取れる捕虜のうち雄の割合。
 */
export interface CaptiveComposition {
  maleFrac: number;
  isHuman: boolean;
}
export const CAPTIVE_COMP = {
  // ゴブリン勢力 (ブン・タ=タ族など): 出生比どおり雄多め。
  goblin: { maleFrac: 0.7, isHuman: false } as CaptiveComposition,
  // 人間勢力: 雄やや多め (襲撃者は男が多い) だが雌も相応に取れる。
  human: { maleFrac: 0.55, isHuman: true } as CaptiveComposition,
} as const;

/**
 * 妊娠・成長ラグ (§2.5) による初期過渡の目減りを補う係数。
 * cycle.ts のラグなしマクロ増殖と、World のラグあり個体増殖が、
 * 平時の「実効純増」レベルで一致するための暫定補正。
 * 平時 30 日で全滅せず上限近くに育つ帯に乗る値として 2.5 を採用。
 * 最終値は実機調整 (§15) で詰める (known_issues KI-12)。
 */
const LAG_COMPENSATION = 2.5;

/**
 * 生まれる子が雄になる確率 (世界観バイブル: 雄が多産)。
 * 0.7 = 雄 7 : 雌 3。雌が希少資源になり、増殖の律速を握る。
 */
const MALE_BIRTH_RATIO = 0.7;

/** baseParams (日次・検証済み) を tick 次に変換して構築。 */
export function makeWorldParams(ticksPerDay = 10): WorldParams {
  const b = baseParams;
  return {
    ticksPerDay,
    sm: defaultStateMachineParams,

    // cycle.ts: pop += labor * BREED_PER_LABOR (1 日, ラグなしの即時増)。
    // World は妊娠ラグ (pregnancyTicks) + 子の成長ラグ (childGrowTicks) を持つ
    // ため (§2.5「自然増は遅い」)、同じ純増を保つにはラグ中の目減りを補う
    // 係数が要る。マクロ近似 (即時) と個体モデル (ラグあり) の粒度差の補正で、
    // 率そのものの再定義ではない (KI-01 の力学一致を「実効純増」のレベルで守る)。
    // 暫定値 lagComp は平時 30 日で全滅せず上限近くに育つ帯に乗るよう設定。
    // 最終値は実機調整 (§15) で詰める。known_issues KI-12 参照。
    deathPerTick: b.DEATH_RATE / ticksPerDay,
    // 性別ベース: 全体増殖率 (cycle 由来) を雌の人口比 (≒ 1-maleBirthRatio)
    // で割り戻し、雌 1 体あたりの妊娠率にする。雌が律速になっても群れ全体の
    // 増殖が元のマクロ率に近づくよう保つ (KI-01 を実効純増レベルで継承)。
    // 雌比 0.3 → 雌 1 体あたり率は全体率の約 3.3 倍。
    pregnancyChancePerFemale:
      ((b.BREED_PER_LABOR / ticksPerDay) * LAG_COMPENSATION) / (1 - MALE_BIRTH_RATIO),
    maleBirthRatio: MALE_BIRTH_RATIO,
    femaleDeathFactor: 0.33, // 雌は逃げ上手で事故死 1/3 (希少資源の保護)
    // 妊娠・成熟をどちらも 1 日に短縮 (生死を軽くする調整 §15)。出産も成体化も
    // 速くなり、個体が「すぐ産まれてすぐ一人前」= 1 体の重みが下がる方向。
    pregnancyTicks: ticksPerDay, // 約 1 日で出産フラグ
    childGrowTicks: ticksPerDay, // 約 1 日で成長 (短い成長ラグ)
    // 一腹の数 = 1〜6、中央値 2 (生死を軽くする: 1 回でまとまった補充)。
    // weights [.30,.30,.18,.12,.06,.04] → cdf。cdf(1)=.30<.5≤.60=cdf(2) で中央値 2。
    // 期待値 ≈ 2.46。少産が大半で稀に大量に産む裾の長い分布。
    litterCdf: [0.3, 0.6, 0.78, 0.9, 0.96, 1.0],

    // 求愛・つがい (KI-18)。確定妊娠＋出産直後即可の高回転のため、求愛頻度は
    // 控えめにして増殖速度を制御する。最終値は実機調整 (§15)。
    matingDurationTicks: 3, // 寝床に数 tick こもる
    courtBaseChance: 0.08, // 雌 1 体が 1 tick に求愛成立する基礎確率 (相性0.5基準)
    favoriteCourtBonus: 0.06, // お気に入り相手なら成功しやすい
    favoriteChance: 0.5, // 性行為後、相性×0.5 でお気に入り登録
    bondMaleHpBonus: 3, // つがい雄: 最大 HP +3 (生存力)
    bondMaleFearReduce: 0.1, // つがい雄: 恐怖閾値 -0.1 (より粘る)
    bondFemaleWorkBonus: 0.3, // つがい雌: 仕事/採餌 +0.3 (内政効率)

    // 雄同士のケンカ (KI-19) / 自然つがい化 (KI-21)。
    rivalryChance: 0.05, // 競合雄ペアが 1 tick にケンカへ発展する確率
    rivalryMateBonus: 3, // つがい持ちの雄はケンカで強い (HP 換算 +3)
    rivalryInjury: 3, // 敗者は HP-3 (即死はしない)
    captiveBondChance: 0.002, // 捕虜が自然つがい化する 1 tick 確率 (ごく稀)

    surgeTrigger: b.SURGE_TRIGGER,
    surgeGain: b.SURGE_GAIN,
    surgeMax: b.SURGE_MAX,
    surgeDecayPerDay: b.SURGE_DECAY,

    fledgeGraceTicks: ticksPerDay, // 約 1 日の平時継続で巣立ち (長い猶予 §2.5)

    goblinPower: b.GOBLIN_POWER,
    enemyPower: b.ENEMY_POWER,

    chiefHpPerAlly: 0.8, // 周囲 1 体ごとに族長 HP +0.8 (要調整 §8)
    chiefHpBonusMax: 12, // 盾ボーナス上限 (青天井防止 §8)

    // 捕虜 (cycle.ts の検証済み定数を出所に / KI-01)。
    // cycle: 苗床は born = usableCaptives * NURSERY_RATE (日次・連続)。
    // World は「数日に一度の確定生産」(§2.5) なので、周期生産に離散化する。
    // 等価性: 周期あたり産出 = NURSERY_RATE × 周期日数 を捕虜 1 人あたりに換算。
    nurseryPeriodTicks: ticksPerDay * 2, // 2 日に一度 確定生産
    nurseryYieldPerCaptive: b.NURSERY_RATE * 2, // 2 日ぶんをまとめて (≒0.16/捕虜)
    nurseryCaptiveConsume: b.CAPTIVE_CONSUME, // 出産で雌捕虜が消耗 (§2.5)
    // 人間母体: 中立ルート以外では解禁し、大柄ゆえ多産 (×2)。多産ぶん消耗も速く
    // 「速いが続かない人間 vs 遅く持続する雌ゴブリン」の前向きトレードオフになる。
    // 死蔵しがちだった人間雌捕虜 (KI-17) に高価値な出口を与える。最終値は §15。
    humanNurseryAllowed: true,
    humanNurseryYieldFactor: 2.0,
    // 敵対度 (§13)。苗床/生贄での人間捕虜の消費が積み上げ、解放が控えめに戻す
    // (GDD §13: 解放の低下量は「自然悪化一回ぶん」相当 = 増分の数倍は使い潰している)。
    // §11/KI-08 の検証帯に合わせ、和平 5 日 → MAX 1 日の間隔へ写像する。最終値は §15。
    hostilityPerHumanNurseryBirth: 0.03,
    hostilityPerHumanSacrifice: 0.05,
    hostilityReleaseDrop: 0.04,
    raidIntervalDaysAtPeace: 5,
    raidIntervalDaysAtMax: 1,
    summonCost: b.SUMMON_COST,
    summonPop: b.SUMMON_POP,
    sacrificeFaith: b.SACRIFICE_FAITH,
    maleSacrificeFactor: 0.5, // 雄捕虜の生贄は雌の半分 (安い燃料 / 雄は溢れる)
    captiveGainPerRaid: b.BIG_RAID_CAPTIVE_GAIN,
    // 投獄中の雄捕虜が加入する確率。即加入だが管理コスト (時間) として
    // 毎 tick 低確率で「気が向けば加わる」。襲撃が近いなら手動で前線投入も可。
    maleCaptiveJoinChancePerTick: 0.02,
    // cycle: faith_per_day = shamans * FAITH_PER_SHAMAN * (RAID_INTERVAL/3)。
    // World は tick 次へ。RAID_INTERVAL/3 = 10 倍率も含めて 1 tick 率にする。
    faithPerTickPerShaman:
      (b.FAITH_PER_SHAMAN * (b.RAID_INTERVAL / 3)) / ticksPerDay,
    shamanRatio: b.SHAMAN_RATIO,
    faithCap: b.BASE_CAP,
  };
}
