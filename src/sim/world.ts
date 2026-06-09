/**
 * World 層の本体。群れ全体を 1 tick 進める純粋 step。
 *
 * 1 tick の処理順 (§2.5/§8/§9):
 *   1. 各個体のステート遷移 (state_machine.stepGoblin)
 *   2. 事故死 (HP 非経由の離散イベント。ユニーク無効 §2.5)
 *   3. 自然増 (睡眠個体の妊娠隠し判定 → 出産フラグ → 子誕生 → 子成長 §2.5)
 *   4. 戦闘解決 (交戦中のみ。§12 一括式で損耗を算出し戦闘個体へ配分 §8)
 *   5. 損耗バフ減衰 (§2.5 / KI-04)
 *   6. 日境界処理 (day++ / 巣立ち判定。平時かつ猶予経過時 §2.5)
 *
 * KI-09: 実時間に一切触れない。tick だけで進む。RNG は state に保存。
 * 戦闘中 (phase=combat) は巣立ちしない・セーブしない (§2.5/§14.5.1)。
 */
import { Rng } from "./rng.ts";
import {
  GoblinState,
  Role,
  Sex,
  GoblinOrigin,
  makeGoblin,
  neutralPersonality,
  sexedPersonality,
  compatibility,
  type Goblin,
  type Personality,
} from "./goblin.ts";
import { stepGoblin, type GoblinContext } from "./state_machine.ts";
import { rankFromCumulative } from "./cycle.ts";
import type { WorldState, RaidPhase, DeathCause } from "./world_state.ts";
import {
  CAPTIVE_COMP,
  type WorldParams,
  type CaptiveComposition,
} from "./world_params.ts";

/** 初期 World を生成。 */
export function initWorld(
  p: WorldParams,
  opts: {
    startGoblins: number;
    capPop: number;
    seed: number;
    withChief?: boolean;
    startCaptives?: number;
  }
): WorldState {
  const rng = new Rng(opts.seed);
  const goblins: Goblin[] = [];
  let id = 1;
  if (opts.withChief) {
    // 族長は雄 (ユニークな盾)。性別別性格は付けず中立 (個性は別途)。
    goblins.push(makeGoblin(id++, neutralPersonality, Role.Chief, Sex.Male));
  }
  // 初期群れ: 出生比どおりオス7:メス3 で固定配置する (抽選せず決定的)。
  // 雌が希少な世界観を初期状態にも一貫させつつ、シードによる雌数のブレを無くす。
  // 端数は四捨五入。雌を先頭側に置いてから残りを雄で埋める。
  const nonChief = opts.startGoblins - (opts.withChief ? 1 : 0);
  const targetFemales = Math.round(nonChief * (1 - p.maleBirthRatio));
  let femalesPlaced = 0;
  for (; id <= opts.startGoblins; ) {
    const sex = femalesPlaced < targetFemales ? Sex.Female : Sex.Male;
    if (sex === Sex.Female) femalesPlaced++;
    const pers = sexedPersonality(sex, () => rng.nextFloat() - 0.5);
    goblins.push(makeGoblin(id++, pers, Role.None, sex));
  }
  return {
    tick: 0,
    day: 0,
    ticksPerDay: p.ticksPerDay,
    faith: 0,
    cum: 0,
    totemRank: 0,
    capPop: opts.capPop,
    humanHostility: 0, // §13 敵対度: 開始時は和平 (人間への加害なし)
    rng: rng.snapshot(),
    capMaleGoblin: 0,
    // 初期捕虜は「すでに巣にいる産み手候補」とみなし雌ゴブリン扱い (苗床の種)。
    capFemaleGoblin: opts.startCaptives ?? 0,
    capMaleHuman: 0,
    capFemaleHuman: 0,
    nurseryTimer: 0,
    goblins,
    nextGoblinId: id,
    deathLog: [],
    phase: "peace",
    surge: 0,
    foodBuff: 0,
    overCapTicks: 0,
    // 初回大規模襲撃は和平間隔 (敵対度 0) ぶん先に予約 (自動スケジューラ §11)。
    nextBigRaidTick: Math.max(1, Math.round(raidIntervalDays(0, p) * p.ticksPerDay)),
    enemiesRemaining: 0,
    raidLossThisFight: 0,
    raidStartPop: 0,
    raidStartHp: 0,
    raidIsHuman: false,
    raidMaleFrac: 0.7,
  };
}

/** 生存している (Dead でない) 個体数。 */
export function livePop(w: WorldState): number {
  let n = 0;
  for (const g of w.goblins) if (g.state !== GoblinState.Dead) n++;
  return n;
}

/** 生存個体の総 HP (損耗を HP 損失で測るため / KI-13)。 */
export function totalHp(w: WorldState): number {
  let h = 0;
  for (const g of w.goblins) if (g.state !== GoblinState.Dead) h += g.hp;
  return h;
}

/** 襲撃を開始する (外部トリガ)。phase を combat にし敵数・勢力を設定。 */
export function beginRaid(
  w: WorldState,
  enemies: number,
  comp: CaptiveComposition = CAPTIVE_COMP.goblin
): WorldState {
  const s = cloneWorld(w);
  s.phase = "combat";
  s.enemiesRemaining = enemies;
  s.raidStartPop = livePop(s);
  s.raidStartHp = totalHp(s);
  s.raidLossThisFight = 0;
  s.raidIsHuman = comp.isHuman;
  s.raidMaleFrac = comp.maleFrac;
  return s;
}

/** 1 tick 進める純粋 step。 */
export function stepWorld(prev: WorldState, p: WorldParams): WorldState {
  const w = cloneWorld(prev);
  const rng = new Rng(0);
  rng.restore(w.rng);

  w.tick += 1;

  // --- 1. 個体ステート遷移 ---
  const inRaid = w.phase === "combat";
  const enemyNearby = inRaid && w.enemiesRemaining > 0;
  for (let i = 0; i < w.goblins.length; i++) {
    const g = w.goblins[i];
    if (g.state === GoblinState.Dead) continue;
    const ctx: GoblinContext = {
      enemyNearby,
      inRaid,
      // 戦線に立つのは雄の成体のみ (世界観: 雌は逃げ腰・希少な産み手として温存)。
      // 雌は恐怖閾値が高く自動的に待避するが、ここで明示的に戦線から外し、
      // 雄主力 + 雌は巣の維持 という非対称を構造化する。瀕死/恐怖/子は
      // stepGoblin 側でさらに除外される。
      assignedToCombat:
        g.sex === Sex.Male && !isChild(g, p) &&
        g.role !== Role.NurseryHost && g.role !== Role.Concubine,
      foodAvailable: true, // 第一期は食料を潤沢と仮定 (生産部屋は後段)
    };
    const before = w.goblins[i].state;
    w.goblins[i] = stepGoblin(g, ctx, p.sm);
    // stepGoblin が新たに死亡させた個体 (ユニークの猶予超過など) を集約処理。
    if (before !== GoblinState.Dead && w.goblins[i].state === GoblinState.Dead) {
      // 一旦 stepGoblin が Dead にしたのを戻し、killGoblin で正規に処理。
      w.goblins[i] = { ...w.goblins[i], state: before };
      killGoblin(w, i, "unique_downed");
    }
  }

  // --- 2. 事故死 (HP 非経由・離散・ユニーク無効 §2.5) ---
  // 戦闘中は事故死を止める (戦闘死と二重に降らせない/演出の混乱回避)。
  if (!inRaid) {
    for (let i = 0; i < w.goblins.length; i++) {
      const g = w.goblins[i];
      if (g.state === GoblinState.Dead || g.isUnique) continue;
      if (isChild(g, p)) continue; // 子は事故死対象外 (理不尽回避の簡略化)
      // 雌は逃げ上手で危険を避けるため事故死しにくい (世界観整合 + 希少な
      // 産み手の保護)。雌が容易に絶滅すると増殖が止まり死のスパイラルになる
      // ため、律速資源を構造的に守る (KI-16)。
      const rate = g.sex === Sex.Female ? p.deathPerTick * p.femaleDeathFactor : p.deathPerTick;
      if (rng.nextFloat() < rate) {
        killGoblin(w, i, "accident");
      }
    }
  }

  // --- 3. 自然増 (§2.5) ---
  stepReproduction(w, rng, p);

  // --- 3.2. 雄同士のケンカ (同じ雌を巡る / KI-19。平時のみ) ---
  if (!inRaid) {
    stepRivalry(w, rng, p);
  }

  // --- 3.3. 捕虜の自然つがい化 (ごく稀 / KI-21。平時のみ) ---
  if (!inRaid) {
    stepCaptiveBonding(w, rng, p);
  }

  // --- 3.5. 信仰蓄積 + 苗床の確定生産 (§3/§2.5) ---
  stepFaithAndNursery(w, p);

  // --- 3.6. 雄ゴブリン捕虜の自動加入 (KI-17) ---
  // 投獄された雄ゴブリン捕虜は、平時に低確率で「気が向いて」群れに加わる。
  // 成体なので即戦力 (子の成長ラグなし)。雄は自前で生まれるため旨味は薄いが、
  // 急な戦力穴埋めや、生贄にするほどでもない端数の捌け口になる。
  if (!inRaid && w.capMaleGoblin >= 1) {
    if (rng.nextFloat() < p.maleCaptiveJoinChancePerTick) {
      w.capMaleGoblin -= 1;
      const pers = sexedPersonality(Sex.Male, () => rng.nextFloat() - 0.5);
      w.goblins.push(makeGoblin(w.nextGoblinId++, pers, Role.None, Sex.Male, {
        bornTick: w.tick, origin: GoblinOrigin.CaptiveJoined,
      }));
    }
  }

  // --- 4. 戦闘解決 (§12 一括式) ---
  if (inRaid) {
    stepCombat(w, p);
  }

  // --- 5. 損耗バフ・食料バフ減衰 (日次率を tick 次へ) ---
  w.surge = Math.max(0, w.surge - p.surgeDecayPerDay / p.ticksPerDay);
  w.foodBuff = Math.max(0, w.foodBuff - p.foodDecayPerDay / p.ticksPerDay);

  // --- 6. 日境界処理 ---
  if (w.tick % w.ticksPerDay === 0) {
    w.day += 1;
    // 巣立ち: 平時かつ上限超過が猶予を超えて続いたら (§2.5)
    if (w.phase !== "combat") {
      if (livePop(w) > w.capPop) {
        w.overCapTicks += w.ticksPerDay;
        if (w.overCapTicks >= p.fledgeGraceTicks) {
          fledge(w, rng);
          w.overCapTicks = 0;
        }
      } else {
        w.overCapTicks = 0;
      }
      // 小規模襲撃 = 二層襲撃の恵み側 (§11/KI-05)。平時に日次 0〜1 回、間接報酬。
      if (p.autoRaidEnabled) {
        stepSmallRaid(w, rng, p);
      }
    }
  }

  // --- 7. 自動襲撃スケジューラ (§11/§13: 敵対度連動の大規模襲撃) ---
  // opt-in。平時に予約 tick へ達したら大規模襲撃を発火し、次回を現在の敵対度で
  // 予約する (敵対度が高いほど短間隔 = 高難度 / KI-08)。発火は beginRaid と同等の
  // 設定を in-place で行う (w は既にクローン済み)。実時間に触れない (KI-09)。
  if (p.autoRaidEnabled && w.phase === "peace" && w.tick >= w.nextBigRaidTick) {
    // 規模: 検証済みマクロと同式 (cycle.ts / KI-01)。ランクは累計信仰から。
    const rank = rankFromCumulative(w.cum, p.rankThresholds);
    const enemies = p.baseEnemies + w.day * p.enemySlope + p.enemyPerRank * rank;
    // 勢力: 怒らせた相手が攻めてくる。人間敵対度が高いほど人間勢力が来やすい。
    const comp = rng.nextFloat() < w.humanHostility ? CAPTIVE_COMP.human : CAPTIVE_COMP.goblin;
    w.phase = "combat";
    w.enemiesRemaining = enemies;
    w.raidStartPop = livePop(w);
    w.raidStartHp = totalHp(w);
    w.raidLossThisFight = 0;
    w.raidIsHuman = comp.isHuman;
    w.raidMaleFrac = comp.maleFrac;
    // 次回を現在の敵対度で予約 (§11/§13 の難度ダイヤル)。
    const gapTicks = Math.max(1, Math.round(raidIntervalDays(w.humanHostility, p) * p.ticksPerDay));
    w.nextBigRaidTick = w.tick + gapTicks;
  }

  w.rng = rng.snapshot();
  return w;
}

/**
 * 信仰蓄積 (§3) と苗床の確定生産 (§2.5)。
 * 信仰: 頭数比例のシャーマンが毎 tick 蓄積、上限でキャップ (青天井防止 §3)。
 * 苗床: 産み手は雌の捕虜 (胎を産み手とする部屋 / §2.5 異種交配)。雄は産めない。
 *       雌ゴブリン捕虜は遅く持続する希少な産み手 (KI-17)。雌人間捕虜も中立
 *       ルート以外なら母体にでき (§13 ゲート)、大柄ゆえ多産だが消耗も速い
 *       = 速いが続かない産み手。仔は母体の種を問わず必ずゴブリン (§2.5)。
 */
function stepFaithAndNursery(w: WorldState, p: WorldParams): void {
  // 信仰: 生存頭数からシャーマン数を頭数比例で出す (KI-03)。
  const pop = livePop(w);
  const shamans = Math.max(0, Math.floor(pop * p.shamanRatio));
  const gain = shamans * p.faithPerTickPerShaman;
  w.cum += gain; // 累計は減らない (ランク用 §3)
  w.faith = Math.min(p.faithCap, w.faith + gain); // faithCap で頭打ち (§3)

  // 苗床の母体: 雌ゴブリン捕虜 (基準) と、解禁時のみ雌人間捕虜 (多産)。
  const goblinHosts = Math.max(0, w.capFemaleGoblin);
  const humanHosts = p.humanNurseryAllowed ? Math.max(0, w.capFemaleHuman) : 0;
  if (goblinHosts <= 0 && humanHosts <= 0) {
    w.nurseryTimer = 0;
    return;
  }

  w.nurseryTimer += 1;
  if (w.nurseryTimer < p.nurseryPeriodTicks) return;
  w.nurseryTimer = 0;

  // ゴブリン母体ぶん (基準レート)。確定生産で子を追加 (成長ラグ付き §2.5)。
  const goblinBorn = Math.floor(goblinHosts * p.nurseryYieldPerCaptive);
  birthNurseryChildren(w, p, goblinBorn, 0);
  // 苗床は産み手を緩やかに消耗する (§2.5 即物性)。
  w.capFemaleGoblin = Math.max(0, w.capFemaleGoblin - goblinBorn * p.nurseryCaptiveConsume);

  // 人間母体ぶん (大柄ゆえ多産 = 倍率を乗せる)。多産のぶん消耗も速く、人間雌
  // 捕虜は「速いが続かない」高価値な産み手になる (KI-17 の死蔵を解消)。
  const humanBorn = Math.floor(humanHosts * p.nurseryYieldPerCaptive * p.humanNurseryYieldFactor);
  birthNurseryChildren(w, p, humanBorn, goblinBorn); // k オフセットで性別パターンを分離
  w.capFemaleHuman = Math.max(0, w.capFemaleHuman - humanBorn * p.nurseryCaptiveConsume);
  // 人間の胎を仔産み機にする残虐が人間勢力の憎悪を募らせる (§13)。
  if (humanBorn > 0) {
    w.humanHostility = clamp01(w.humanHostility + humanBorn * p.hostilityPerHumanNurseryBirth);
  }
}

/**
 * 苗床の確定生産で子ゴブリンを count 体追加する (母体の種を問わず仔はゴブリン)。
 * 性別は tick と (k+kOffset) から決定的に決め maleBirthRatio に寄せる
 * (stepFaithAndNursery は rng を持たないため / スナップショット不変)。kOffset で
 * ゴブリン母体ぶんと人間母体ぶんの性別パターンが衝突しないよう分離する。
 */
function birthNurseryChildren(w: WorldState, p: WorldParams, count: number, kOffset: number): void {
  for (let k = 0; k < count; k++) {
    const hash = ((w.tick * 2654435761) ^ ((k + kOffset) * 40503)) >>> 0;
    const sex = (hash % 100) / 100 < p.maleBirthRatio ? Sex.Male : Sex.Female;
    const pers = sexedPersonality(sex, () => 0); // 苗床産は個体差なし(簡略)
    const child = makeGoblin(w.nextGoblinId++, pers, Role.None, sex, {
      bornTick: w.tick, origin: GoblinOrigin.Nursery,
    });
    markChild(child, w.tick);
    w.goblins.push(child);
  }
}

/**
 * 繁殖 (乱婚制の求愛システム / KI-18)。各 tick 平時に処理する。
 * フロー: 子の成長 → 妊娠進行/出産 → 性行為の進行 → 新規求愛。
 *
 * - 雌は固定の相手 (つがい) がいればその雄と、いなければお気に入り or 任意の
 *   雄に声をかける。雄は固定相手がいればその雌と、いなければ任意の雌に声をかける。
 * - 求愛成功率は相性 (compatibility) × お気に入り補正。成功で寝床へ → 数 tick の
 *   性行為 → 確定妊娠。
 * - 妊娠は雌のみ、確定で 2 日後に出産。妊娠中は追加不可、出産直後から再び可能。
 * - 相性が良ければお気に入り化 → 相互で受け入れたらつがい成立 (両者ステータスアップ)。
 *
 * 決定性 (KI-09): 個体ループ順序は配列順で固定。相手選択は共有 rng のみを
 * 一定順序で消費する。
 */
function stepReproduction(w: WorldState, rng: Rng, p: WorldParams): void {
  // id → index の対応 (相手参照に使う)。
  const idx = new Map<number, number>();
  w.goblins.forEach((g, i) => idx.set(g.id, i));
  const byId = (id: number | null): Goblin | null =>
    id === null ? null : w.goblins[idx.get(id) ?? -1] ?? null;
  const isAdult = (g: Goblin) =>
    g.state !== GoblinState.Dead && !isChild(g, p);
  const isAvailable = (g: Goblin) =>
    isAdult(g) &&
    !g.pregnant && // 妊娠中は追加の性行為に関与しない (追加妊娠不可 KI-18)
    g.matingTicks < 0 &&
    g.state !== GoblinState.Combat &&
    g.state !== GoblinState.Fear &&
    g.state !== GoblinState.Dying &&
    g.hp / g.maxHp >= p.sm.dyingHpFrac;

  // --- 1. 子の成長・出産・性行為の進行 (各個体) ---
  for (let i = 0; i < w.goblins.length; i++) {
    const g = w.goblins[i];
    if (g.state === GoblinState.Dead) continue;

    // 子の成長
    if (isChild(g, p)) {
      const born = childBornTick(g);
      if (born !== null && w.tick - born >= p.childGrowTicks) {
        w.goblins[i] = clearChild(g);
      }
      continue;
    }

    // 妊娠の進行 → 出産 (雌のみ・確定 2 日後)
    if (g.pregnant) {
      // 飢え/瀕死で流産 (食料従属 §2.5)
      if (g.hunger >= 0.95 || g.hp / g.maxHp < p.sm.dyingHpFrac) {
        w.goblins[i] = { ...g, pregnant: false, pregnantTicks: 0 };
        continue;
      }
      const pt = g.pregnantTicks + 1;
      if (pt >= p.pregnancyTicks) {
        // 出産: 一腹の数を引いて (1〜6・中央値2) その数だけ子を産む。各子は
        // 性別決定 → 性別別性格。つがいの雌なら親の charmSeed を一部継承
        // (将来の血統表現の布石だが第一期は性別のみ)。
        const litter = drawLitterSize(rng, p);
        for (let k = 0; k < litter; k++) {
          const sex = rng.nextFloat() < p.maleBirthRatio ? Sex.Male : Sex.Female;
          const pers = sexedPersonality(sex, () => rng.nextFloat() - 0.5);
          const child = makeGoblin(w.nextGoblinId++, pers, Role.None, sex, {
            bornTick: w.tick,
            motherId: g.id,
            fatherId: g.mateId, // つがいの父 (乱婚で不定なら null)
            origin: GoblinOrigin.Born,
          });
          markChild(child, w.tick);
          w.goblins.push(child);
        }
        w.goblins[i] = { ...g, pregnant: false, pregnantTicks: 0 };
      } else {
        w.goblins[i] = { ...g, pregnantTicks: pt };
      }
      continue;
    }

    // 性行為の進行 (寝床で matingTicks を進め、完了で雌が妊娠)
    if (g.matingTicks >= 0) {
      const mt = g.matingTicks + 1;
      if (mt >= p.matingDurationTicks) {
        const partner = byId(g.matingWithId);
        // 関与解除は両者で行うが、妊娠と bond 判定は雌側のみが担当し、
        // 二重処理・片側だけ mateId がつく不整合を防ぐ。
        if (g.sex === Sex.Female) {
          w.goblins[i] = { ...g, pregnant: partner !== null, pregnantTicks: 0, matingTicks: -1, matingWithId: null };
          if (partner) maybeBond(w, idx, g.id, partner.id, rng, p);
        } else {
          // 雄側は関与解除のみ (bond は相手の雌側 tick で処理済み/されうる)。
          w.goblins[i] = { ...g, matingTicks: -1, matingWithId: null };
        }
      } else {
        w.goblins[i] = { ...g, matingTicks: mt };
      }
      continue;
    }
  }

  // --- 2. 新規求愛 (平時のみ・雌が起点。雌律速を行動として表現) ---
  // 雌が起点なのは「雌の数が律速」を行動レベルで保証するため。雄が手当り次第
  // でも、妊娠できる雌の数が上限を決める。
  for (let i = 0; i < w.goblins.length; i++) {
    const female = w.goblins[i];
    if (female.sex !== Sex.Female || !isAvailable(female)) continue;

    // 相手の雄を選ぶ: つがい > お気に入り > 任意の利用可能な雄。
    let target: Goblin | null = null;
    const mate = byId(female.mateId);
    if (mate && mate.sex === Sex.Male && isAvailable(mate)) {
      target = mate;
    } else {
      const fav = byId(female.favoriteId);
      if (fav && fav.sex === Sex.Male && isAvailable(fav) && rng.nextFloat() < 0.7) {
        target = fav;
      } else {
        // 任意の利用可能な雄を rng で 1 体選ぶ (近くにいた雄の抽象)。
        const males: number[] = [];
        for (let j = 0; j < w.goblins.length; j++) {
          const m = w.goblins[j];
          if (m.sex === Sex.Male && isAvailable(m)) males.push(j);
        }
        if (males.length > 0) {
          target = w.goblins[males[Math.floor(rng.nextFloat() * males.length)]];
        }
      }
    }
    if (!target) continue;

    // 求愛成功率 = 基礎 × (相性 + お気に入り補正) × surge。
    const compat = compatibility(female, target);
    const favBonus =
      female.favoriteId === target.id || target.favoriteId === female.id ? p.favoriteCourtBonus : 0;
    const isMated = female.mateId === target.id;
    // 損耗バフ (surge) と食料バフ (foodBuff) が求愛成功率を底上げ (§2.5/KI-05)。
    // マクロの breedMult = 1 + surge + foodBuff に対応 (World は重みを 0.5 に割る)。
    const chance =
      (p.courtBaseChance * (0.5 + compat) + favBonus + (isMated ? p.matedCourtBonus : 0)) *
      (1 + w.surge * 0.5 + w.foodBuff * 0.5);
    if (rng.nextFloat() < chance) {
      // 成立: 両者を寝床での性行為へ (matingTicks=0, 相手 id をセット)。
      const ti = idx.get(target.id)!;
      w.goblins[i] = { ...w.goblins[i], matingTicks: 0, matingWithId: target.id, state: GoblinState.Sleep };
      w.goblins[ti] = { ...w.goblins[ti], matingTicks: 0, matingWithId: female.id, state: GoblinState.Sleep };
    }
  }
}

/**
 * 性行為後、相性に応じてお気に入り化・つがい成立を判定 (KI-18)。
 * お気に入りは片側で成立 (片思い可)。つがいは双方が相手をお気に入りに
 * している場合のみ成立し、両者にステータスアップを与える。
 */
function maybeBond(
  w: WorldState,
  idx: Map<number, number>,
  aId: number,
  bId: number,
  rng: Rng,
  p: WorldParams
): void {
  const ai = idx.get(aId), bi = idx.get(bId);
  if (ai === undefined || bi === undefined) return;
  let a = w.goblins[ai], b = w.goblins[bi];
  const compat = compatibility(a, b);

  // 相性が高いほどお気に入りに登録しやすい。悲嘆した個体は登録しない
  // (二度と新たな絆を作らない / KI-19)。
  if (!a.bereaved && a.favoriteId === null && rng.nextFloat() < compat * p.favoriteChance) {
    a = { ...a, favoriteId: bId };
  }
  if (!b.bereaved && b.favoriteId === null && rng.nextFloat() < compat * p.favoriteChance) {
    b = { ...b, favoriteId: aId };
  }

  // つがい成立: 双方が相手をお気に入りにしており、まだつがいでなく、
  // どちらも悲嘆していないとき。
  if (
    !a.bereaved && !b.bereaved &&
    a.favoriteId === bId && b.favoriteId === aId &&
    a.mateId === null && b.mateId === null
  ) {
    a = { ...a, mateId: bId };
    b = { ...b, mateId: aId };
    // ステータスアップ: 雄=生存力 (HP・恐怖耐性)、雌=内政効率 (出産/仕事)。
    a = applyBondBuff(a, p);
    b = applyBondBuff(b, p);
  }
  w.goblins[ai] = a;
  w.goblins[bi] = b;
}

/**
 * 奴隷妻化 (捕虜つがい / KI-19)。プレイヤーが許可したとき、suitorId の個体が
 * 異性の捕虜を娶る。捕虜プールから 1 体取り出して側室 (Role.Concubine) として
 * 加え、娶った側につがいバフを与える。
 *
 * 苗床との差別化: 苗床は捕虜を消費して子を産むだけ (個体は無関係)。奴隷妻は
 * 特定個体が望み、その個体が満たされてバフを得る (生存力↑)。側室は戦線・労働に
 * 出ないが子は産む (実質、苗床+娶った個体の強化)。人間でも可 (§13 家畜化的)。
 */
export function takeConcubine(
  prev: WorldState,
  p: WorldParams,
  suitorId: number,
  captiveSex: Sex,
  captiveIsHuman: boolean
): { state: WorldState; ok: boolean } {
  const w = cloneWorld(prev);
  const si = w.goblins.findIndex((g) => g.id === suitorId && g.state !== GoblinState.Dead);
  if (si < 0) return { state: prev, ok: false };
  const suitor = w.goblins[si];
  if (captiveSex === suitor.sex) return { state: prev, ok: false }; // 異性のみ

  const dec = (): boolean => {
    if (captiveIsHuman && captiveSex === Sex.Male && w.capMaleHuman >= 1) { w.capMaleHuman -= 1; return true; }
    if (captiveIsHuman && captiveSex === Sex.Female && w.capFemaleHuman >= 1) { w.capFemaleHuman -= 1; return true; }
    if (!captiveIsHuman && captiveSex === Sex.Male && w.capMaleGoblin >= 1) { w.capMaleGoblin -= 1; return true; }
    if (!captiveIsHuman && captiveSex === Sex.Female && w.capFemaleGoblin >= 1) { w.capFemaleGoblin -= 1; return true; }
    return false;
  };
  if (!dec()) return { state: prev, ok: false };

  const concubine = makeGoblin(w.nextGoblinId++, neutralPersonality, Role.Concubine, captiveSex, {
    bornTick: w.tick, origin: GoblinOrigin.Concubine,
  });
  concubine.mateId = suitor.id;
  let s: Goblin = { ...suitor, mateId: concubine.id };
  s = applyBondBuff(s, p);
  w.goblins[si] = s;
  w.goblins.push(concubine);
  return { state: w, ok: true };
}

/** つがいのステータスアップ。雄=生存力、雌=内政効率 (KI-18)。 */
function applyBondBuff(g: Goblin, p: WorldParams): Goblin {
  if (g.sex === Sex.Male) {
    // 雄: 最大 HP 増 + 恐怖閾値を下げる (より粘る = 生存力)。
    return {
      ...g,
      maxHp: g.maxHp + p.bondMaleHpBonus,
      hp: g.hp + p.bondMaleHpBonus,
      personality: { ...g.personality, fearHpBias: g.personality.fearHpBias - p.bondMaleFearReduce },
    };
  }
  // 雌: 内政効率 = 仕事重み + 採餌重み を上げる (巣の維持に貢献)。
  return {
    ...g,
    personality: {
      ...g.personality,
      workBias: g.personality.workBias + p.bondFemaleWorkBonus,
      forageBias: g.personality.forageBias + p.bondFemaleWorkBonus,
    },
  };
}

/**
 * 雄同士のケンカ (同じ雌をお気に入りにした雄同士 / KI-19)。
 * 平時のみ。HP × つがい補正で勝敗が決まり (強い雄が勝ちやすい)、敗者は
 * 負傷 (HP 減) し、争っていた雌のお気に入りを失う。発火は確率で抑える
 * (毎 tick 全員が殴り合うと雄が傷だらけになり襲撃前に弱る)。
 * 決定性: 個体ループ順固定、rng は一定順序で消費。
 */
function stepRivalry(w: WorldState, rng: Rng, p: WorldParams): void {
  // お気に入りの雌 id ごとに、それを慕う雄を集める。
  const suitorsByFemale = new Map<number, number[]>(); // femaleId → 雄の index 群
  for (let i = 0; i < w.goblins.length; i++) {
    const g = w.goblins[i];
    if (g.state === GoblinState.Dead || isChild(g, p)) continue;
    if (g.sex !== Sex.Male || g.favoriteId === null) continue;
    if (g.matingTicks >= 0) continue; // 性行為中は争わない
    const arr = suitorsByFemale.get(g.favoriteId) ?? [];
    arr.push(i);
    suitorsByFemale.set(g.favoriteId, arr);
  }

  for (const [, suitors] of suitorsByFemale) {
    if (suitors.length < 2) continue; // 競合がなければケンカなし
    if (rng.nextFloat() >= p.rivalryChance) continue;
    const i1 = suitors[Math.floor(rng.nextFloat() * suitors.length)];
    const i2 = suitors[Math.floor(rng.nextFloat() * suitors.length)];
    if (i1 === i2) continue;
    const a = w.goblins[i1], b = w.goblins[i2];
    if (a.state === GoblinState.Dead || b.state === GoblinState.Dead) continue;

    // 強さ = HP + つがい補正 (既につがいを持つ雄は強い) + 少しの運。
    const strength = (g: Goblin) =>
      g.hp + (g.mateId !== null ? p.rivalryMateBonus : 0) + rng.nextFloat() * 2;
    const sa = strength(a), sb = strength(b);
    const loserIdx = sa >= sb ? i2 : i1;
    const loser = w.goblins[loserIdx];
    // 敗者は負傷 (HP 減) し、争っていた雌のお気に入りを失う。即死はしない。
    w.goblins[loserIdx] = {
      ...loser,
      hp: Math.max(1, loser.hp - p.rivalryInjury),
      favoriteId: null,
    };
  }
}

/**
 * 捕虜とゴブリンの自然つがい化 (KI-21)。各 tick 平時にごくごく稀に発生。
 * どうやってか捕虜と巣のゴブリンの間に絆が芽生え、プレイヤーの承認を待つ
 * 状態 (pendingBond) になる。承認で巣に貢献開始、引き離しで処刑/追放。
 *
 * 発生対象は2系統:
 *  (a) 未娶の捕虜カテゴリ → 個体化して pendingBond の側室として加える。
 *  (b) 既に側室 (Role.Concubine) の捕虜 → そのまま pendingBond に昇格。
 * 決定性: rng を一定順序で消費。発生率 captiveBondChance は極小。
 */
function stepCaptiveBonding(w: WorldState, rng: Rng, p: WorldParams): void {
  // 既に承認待ちが居るなら新規発生を抑える (通知の氾濫を防ぐ)。
  if (w.goblins.some((g) => g.pendingBond && g.state !== GoblinState.Dead)) return;
  if (rng.nextFloat() >= p.captiveBondChance) return;

  // 相手になる巣のゴブリン (成体・生存・側室でない・pendingでない) を集める。
  const eligible: number[] = [];
  for (let i = 0; i < w.goblins.length; i++) {
    const g = w.goblins[i];
    if (g.state === GoblinState.Dead || isChild(g, p)) continue;
    if (g.role === Role.Concubine || g.pendingBond) continue;
    if (g.mateId !== null) continue; // 既につがい持ちは対象外
    eligible.push(i);
  }
  if (eligible.length === 0) return;

  // (b) 既存の側室から自然つがい化するルート (50%)。
  const concubines = w.goblins
    .map((g, i) => ({ g, i }))
    .filter(({ g }) => g.role === Role.Concubine && g.state !== GoblinState.Dead && !g.pendingBond);
  if (concubines.length > 0 && rng.nextFloat() < 0.5) {
    const pick = concubines[Math.floor(rng.nextFloat() * concubines.length)];
    // 側室は既に娶り主 (mateId) がいる。その絆が「正当なもの」に変わる。
    w.goblins[pick.i] = { ...w.goblins[pick.i], pendingBond: true };
    return;
  }

  // (a) 未娶の捕虜を個体化して pendingBond の側室として加える。
  const suitorIdx = eligible[Math.floor(rng.nextFloat() * eligible.length)];
  const suitor = w.goblins[suitorIdx];
  const wantSex = suitor.sex === Sex.Male ? Sex.Female : Sex.Male; // 異性
  // 捕虜カテゴリから 1 消費 (ゴブリン優先、なければ人間)。
  const consume = (): boolean => {
    if (wantSex === Sex.Female && w.capFemaleGoblin >= 1) { w.capFemaleGoblin -= 1; return true; }
    if (wantSex === Sex.Male && w.capMaleGoblin >= 1) { w.capMaleGoblin -= 1; return true; }
    if (wantSex === Sex.Female && w.capFemaleHuman >= 1) { w.capFemaleHuman -= 1; return true; }
    if (wantSex === Sex.Male && w.capMaleHuman >= 1) { w.capMaleHuman -= 1; return true; }
    return false;
  };
  if (!consume()) return; // 該当する捕虜が居ない

  const lover = makeGoblin(w.nextGoblinId++, neutralPersonality, Role.Concubine, wantSex, {
    bornTick: w.tick, origin: GoblinOrigin.Concubine,
  });
  lover.mateId = suitor.id;
  lover.pendingBond = true; // 承認待ち
  w.goblins[suitorIdx] = { ...suitor, mateId: lover.id, pendingBond: true };
  w.goblins.push(lover);
}

/**
 * 自然つがい化した捕虜を承認する (KI-21)。pendingBond を解除し、捕虜側を
 * 巣に貢献する一員 (Role.None) に昇格させる。娶り主につがいバフを与える
 * (まだなければ)。承認された捕虜は戦い・働き・子を産む。
 */
export function approveBond(prev: WorldState, p: WorldParams, captiveId: number): WorldState {
  const w = cloneWorld(prev);
  const ci = w.goblins.findIndex((g) => g.id === captiveId && g.pendingBond);
  if (ci < 0) return prev;
  const captive = w.goblins[ci];
  // 捕虜を貢献する一員に昇格 (側室 → 無役)。性別別性格を与える。
  const pers = sexedPersonality(captive.sex, () => 0);
  let promoted: Goblin = { ...captive, role: Role.None, pendingBond: false, personality: pers };
  promoted = applyBondBuff(promoted, p); // つがいバフ
  w.goblins[ci] = promoted;
  // 娶り主側も pendingBond 解除 (まだバフ未適用ならここでは触らない: 既に
  // takeConcubine 経由ならバフ済み。自然発生(a)なら未バフなので付ける)。
  const mi = w.goblins.findIndex((g) => g.id === captive.mateId);
  if (mi >= 0) {
    let mate = { ...w.goblins[mi], pendingBond: false };
    w.goblins[mi] = mate;
  }
  return w;
}

/**
 * 自然つがいを引き離す (KI-21)。両方を処刑 (execution) または追放 (banishment)
 * しないと引き離せない (片方だけ消すと残った方が悲嘆する仕様)。
 * captiveId とその娶り主の両方を指定 cause で殺す。
 */
export function tearApartBond(
  prev: WorldState,
  captiveId: number,
  cause: "execution" | "banishment"
): WorldState {
  const w = cloneWorld(prev);
  const ci = w.goblins.findIndex((g) => g.id === captiveId && g.pendingBond);
  if (ci < 0) return prev;
  const mateId = w.goblins[ci].mateId;
  // 先に相手の mateId 参照を切っておく (killGoblin の widow が悲嘆を起こさない
  // よう、両者同時処理として扱う)。両方消すので悲嘆は発生しない。
  const mi = mateId !== null ? w.goblins.findIndex((g) => g.id === mateId) : -1;
  // 捕虜を処理。
  killGoblin(w, ci, cause);
  // 娶り主も処理 (両方消す)。
  if (mi >= 0 && w.goblins[mi].state !== GoblinState.Dead) {
    killGoblin(w, mi, cause);
  }
  return w;
}

/**
 * 個体を死亡させる単一の経路 (KI-20/KI-01)。death log を記録し、
 * state を Dead にし、つがい喪失処理 (widowPartnerOf) まで一手に行う。
 * 全死亡経路 (事故死・戦闘死・巣立ち・ユニーク猶予超過・処刑・追放) は
 * これを通すことで、ログ漏れ・widow 漏れ (前回の片側 mateId バグ) を構造的に防ぐ。
 * idx は w.goblins 内の位置。cause は死因。
 */
function killGoblin(w: WorldState, idx: number, cause: DeathCause): void {
  const g = w.goblins[idx];
  if (g.state === GoblinState.Dead) return; // 二重死亡を防ぐ
  // ログ記録 (死亡時の属性スナップショット)。
  w.deathLog.push({
    tick: w.tick,
    day: w.day,
    id: g.id,
    sex: g.sex,
    role: g.role,
    origin: g.origin,
    bornTick: g.bornTick,
    ageDays: Math.round(((w.tick - g.bornTick) / w.ticksPerDay) * 10) / 10,
    hp: Math.round(g.hp * 10) / 10,
    maxHp: g.maxHp,
    state: g.state,
    mateId: g.mateId,
    favoriteId: g.favoriteId,
    motherId: g.motherId,
    fatherId: g.fatherId,
    bereaved: g.bereaved,
    cause,
  });
  // 死亡をセット。
  w.goblins[idx] = { ...g, state: GoblinState.Dead };
  // つがい喪失処理 (相手の mateId/favoriteId を解除、雄なら悲嘆)。
  widowPartnerOf(w, g.id);
}

/**
 * 個体 deadId が群れから失われた (死亡/巣立ち) とき、その個体のつがい相手を
 * 喪失処理する (KI-19)。残された側の mateId/favoriteId を解除し、
 * 雄なら悲嘆 (bereaved=true → 二度と繁殖しない)、雌は何もせず次を探せる。
 * 死亡を扱う全箇所から呼び、喪失の力学を一箇所に保つ (KI-01)。
 */
function widowPartnerOf(w: WorldState, deadId: number): void {
  for (let i = 0; i < w.goblins.length; i++) {
    const g = w.goblins[i];
    if (g.state === GoblinState.Dead) continue;
    if (g.mateId === deadId) {
      if (g.sex === Sex.Male) {
        // 雄: 悲しみで二度と繁殖しない (お気に入りも解除)。
        w.goblins[i] = { ...g, mateId: null, favoriteId: null, bereaved: true };
      } else {
        // 雌: つがい解除のみ。あっさり次を探せる。
        w.goblins[i] = { ...g, mateId: null, favoriteId: null };
      }
    } else if (g.favoriteId === deadId) {
      // つがいでないお気に入りが消えた場合も解除 (片思いの相手が死ぬ)。
      w.goblins[i] = { ...g, favoriteId: null };
    }
  }
}

/**
 * 戦闘解決 (§12 一括式 = simulateRaid と同じ係数)。
 * 戦闘ステートの頭数を集計してマクロ式で損耗を出し、個体へ配分する
 * (検証済みのマクロ力学を壊さない接続 / KI 横断: 力学を共有せよ)。
 */
function stepCombat(w: WorldState, p: WorldParams): void {
  const fighters = w.goblins.filter((g) => g.state === GoblinState.Combat);
  const g = fighters.length;
  const e = w.enemiesRemaining;
  if (g <= 0 || e <= 0) {
    // 決着: 残敵 0 なら撃退、味方 0 なら全滅。phase を戻す。
    endCombat(w, p);
    return;
  }
  // 1 tick の相互削り合い (cycle.ts の本体ループ 1 反復ぶん)。
  // 敵を削る量は頭数ベース (cycle と同じ g * goblinPower)。
  const enemyDamage = g * p.goblinPower;
  w.enemiesRemaining = Math.max(0, e - enemyDamage);

  // 味方被ダメ: cycle.ts は頭数を直接削る (g -= e*ep, 1頭=HP1相当の即死)。
  // World は個体 HP 制 (maxHp) のため、同じ係数では HP バッファぶん過剰に
  // 耐久してしまい、検証済みの損耗率・全滅閾値から乖離する (KI-01)。
  // 被ダメを maxHp 倍して個体 HP 空間へ投影し、1 頭 = maxHp の対応をとる。
  // これで「敵 N に対し頭数 M で全滅/辛勝する」境界が cycle と揃う。
  const hpScale = w.goblins.length > 0 ? w.goblins[0].maxHp : 1;
  const goblinDamage = e * p.enemyPower * hpScale;

  // 味方ダメージを個体へ配分。族長が盾としてターゲット誘引 (§8)。
  distributeDamage(w, fighters, goblinDamage, p);

  if (w.enemiesRemaining <= 0 || combatPop(w) <= 0) {
    endCombat(w, p);
  }
}

/** 味方被ダメを戦闘個体へ配分 (族長が周囲頭数ぶん多く引き受ける §8)。 */
function distributeDamage(
  w: WorldState,
  fighters: Goblin[],
  totalDamage: number,
  p: WorldParams
): void {
  if (fighters.length === 0) return;

  const idById = new Map<number, number>();
  w.goblins.forEach((g, idx) => idById.set(g.id, idx));

  const applyDmg = (f: Goblin, dmg: number) => {
    const idx = idById.get(f.id)!;
    const cur = w.goblins[idx];
    const hp = cur.hp - dmg;
    if (hp <= 0) {
      if (cur.isUnique) {
        // ユニークは即死せず倒れる (§8 瀕死保護)。stepGoblin が猶予を数える。
        w.goblins[idx] = { ...cur, hp: 0 };
      } else {
        w.goblins[idx] = { ...cur, hp: 0 };
        w.raidLossThisFight += 1;
        killGoblin(w, idx, "combat"); // 戦死を一元処理 (ログ+widow)
      }
    } else {
      w.goblins[idx] = { ...cur, hp };
    }
  };

  // ターゲット誘引 (§8): 族長は他個体より狙われやすい = 被ダメ配分の重みが高い。
  // ただし固定割合で吸収すると過剰防御になり検証済み損耗率から乖離するため
  // (KI-12)、重み付け配分にする。族長の重み chiefWeight、他は 1。
  const chief = fighters.find((f) => f.role === Role.Chief);
  const chiefWeight = chief ? 3 : 0; // 族長は 3 体分狙われやすい (要調整 §8)
  const others = fighters.filter((f) => f.role !== Role.Chief);
  const totalWeight = chiefWeight + others.length;
  if (totalWeight <= 0) return;
  const unit = totalDamage / totalWeight;

  if (chief) {
    // 盾ボーナス: 周囲頭数ぶん被ダメを軽減 (逓減上限つき §8)。
    const allies = Math.max(0, fighters.length - 1);
    const bonus = Math.min(p.chiefHpBonusMax, allies * p.chiefHpPerAlly);
    const chiefDmg = Math.max(0, unit * chiefWeight - bonus);
    applyDmg(chief, chiefDmg);
  }
  for (const f of others) applyDmg(f, unit);
}

/** 戦闘ステートの生存頭数。 */
function combatPop(w: WorldState): number {
  let n = 0;
  for (const g of w.goblins)
    if (g.state === GoblinState.Combat && g.hp > 0) n++;
  return n;
}

/** 戦闘終了処理: 損耗バフ発火 (§2.5) と phase 復帰。 */
function endCombat(w: WorldState, p: WorldParams): void {
  // 損耗を「総 HP の損失割合」で測る (KI-13)。World は §5 離脱で死者が
  // 出にくいため、頭数減ベースだと surge がほぼ発火しない。HP 損失で見れば
  // 「死なずとも大きく削られた = 群れが疲弊した」状況を救済できる。
  const preHp = w.raidStartHp;
  if (preHp > 0) {
    const lossFrac = (preHp - totalHp(w)) / preHp;
    if (lossFrac >= p.surgeTrigger) {
      w.surge = Math.min(p.surgeMax, w.surge + lossFrac * p.surgeGain);
    }
  }
  w.phase = "peace";
  w.enemiesRemaining = 0;
  // 撃退成功 (生存者あり) なら捕虜を獲得 (§2.5 襲撃撃退で捕虜)。
  // 現襲撃の勢力構成 (raidIsHuman/raidMaleFrac) に従って性別×種族に振り分ける。
  // 全滅時は獲得なし。
  if (livePop(w) > 0) {
    const total = p.captiveGainPerRaid;
    const males = total * w.raidMaleFrac;
    const females = total - males;
    if (w.raidIsHuman) {
      w.capMaleHuman += males;
      w.capFemaleHuman += females;
    } else {
      w.capMaleGoblin += males;
      w.capFemaleGoblin += females;
    }
  }
  // 戦闘ステートの生存者を平時へ戻す。
  for (let i = 0; i < w.goblins.length; i++) {
    if (w.goblins[i].state === GoblinState.Combat) {
      w.goblins[i] = { ...w.goblins[i], state: GoblinState.Wander };
    }
  }
}

/**
 * 緊急補充 (性別×種族対応 / KI-17)。3 段階で頭数を補う:
 *  1. 雄ゴブリン捕虜の即加入: 成体なので成長ラグなし、信仰も不要の前衛。
 *     雄捕虜の固有価値 (自前の雄は遅いが、捕虜雄は即戦力)。
 *  2. 信仰での召喚: 雄の戦士を即時生成 (§4)。
 *  3. 生贄で信仰を作る: 雄ゴブリン捕虜を優先 (安い燃料)、次に人間、
 *     雌ゴブリンは最後の手段 (希少な産み手なので温存)。
 * 目標頭数 targetPop まで、上限を超えない範囲で。
 */
export function emergencyReinforce(
  prev: WorldState,
  p: WorldParams,
  targetPop: number
): WorldState {
  const w = cloneWorld(prev);
  const cap = w.capPop;

  // --- 1. 雄ゴブリン捕虜を即加入 (信仰不要の前衛) ---
  while (livePop(w) < targetPop && livePop(w) < cap && w.capMaleGoblin >= 1) {
    w.capMaleGoblin -= 1;
    const pers = sexedPersonality(Sex.Male, () => 0);
    w.goblins.push(makeGoblin(w.nextGoblinId++, pers, Role.None, Sex.Male, {
      bornTick: w.tick, origin: GoblinOrigin.CaptiveJoined,
    }));
  }

  // --- 2 & 3. 召喚 (信仰)、足りなければ生贄で信仰を作る ---
  let safety = 0;
  while (livePop(w) < targetPop && livePop(w) < cap && safety < 500) {
    safety++;
    if (w.faith < p.summonCost) {
      // 生贄の優先: 雄ゴブリン (安い) → 人間 → 雌ゴブリン (最後)。
      if (w.capMaleGoblin >= 1) {
        w.faith += p.sacrificeFaith * p.maleSacrificeFactor;
        w.cum += p.sacrificeFaith * p.maleSacrificeFactor;
        w.capMaleGoblin -= 1;
      } else if (w.capMaleHuman >= 1) {
        w.faith += p.sacrificeFaith;
        w.cum += p.sacrificeFaith;
        w.capMaleHuman -= 1;
        w.humanHostility = clamp01(w.humanHostility + p.hostilityPerHumanSacrifice); // §13
      } else if (w.capFemaleHuman >= 1) {
        w.faith += p.sacrificeFaith;
        w.cum += p.sacrificeFaith;
        w.capFemaleHuman -= 1;
        w.humanHostility = clamp01(w.humanHostility + p.hostilityPerHumanSacrifice); // §13
      } else if (w.capFemaleGoblin >= 1) {
        // 希少な産み手を泣く泣く生贄に (最後の手段)。
        w.faith += p.sacrificeFaith;
        w.cum += p.sacrificeFaith;
        w.capFemaleGoblin -= 1;
      } else {
        break; // 信仰も捕虜も尽きた
      }
    }
    if (w.faith >= p.summonCost) {
      const n = Math.floor(p.summonPop);
      for (let k = 0; k < n; k++) {
        if (livePop(w) >= cap) break;
        const pers = sexedPersonality(Sex.Male, () => 0);
        w.goblins.push(makeGoblin(w.nextGoblinId++, pers, Role.None, Sex.Male, {
          bornTick: w.tick, origin: GoblinOrigin.Summoned,
        }));
      }
      w.faith -= p.summonCost;
    }
  }
  return w;
}

/** 巣立ち: 上限超過分を無役からランダム選定して除外 (§2.5)。 */
function fledge(w: WorldState, rng: Rng): void {
  const over = Math.floor(livePop(w) - w.capPop);
  if (over <= 0) return;
  // 候補: 無役・非ユニーク・非子・生存。なければ族長以外。
  const candidates = w.goblins
    .map((g, idx) => ({ g, idx }))
    .filter(
      ({ g }) =>
        g.state !== GoblinState.Dead &&
        !g.isUnique &&
        g.role === Role.None
    );
  const pool =
    candidates.length > 0
      ? candidates
      : w.goblins
          .map((g, idx) => ({ g, idx }))
          .filter(({ g }) => g.state !== GoblinState.Dead && g.role !== Role.Chief);

  let removed = 0;
  const arr = [...pool];
  while (removed < over && arr.length > 0) {
    const pick = Math.floor(rng.nextFloat() * arr.length);
    const { idx } = arr.splice(pick, 1)[0];
    killGoblin(w, idx, "fledge"); // 巣立ち (巣からの除外) を一元処理
    removed++;
  }
}

/**
 * 一腹の数を引く (1..litterCdf.length)。litterCdf は累積分布で末尾が 1.0。
 * 既定 (world_params) は中央値 2・期待値 ≈ 2.46 の裾の長い分布。
 * rng を 1 回だけ消費する (決定性・スナップショット安全 / KI-09)。
 */
function drawLitterSize(rng: Rng, p: WorldParams): number {
  const r = rng.nextFloat();
  const cdf = p.litterCdf;
  for (let i = 0; i < cdf.length; i++) {
    if (r < cdf[i]) return i + 1;
  }
  return cdf.length;
}

/** 0..1 にクランプ (敵対度メーター用 / §13)。 */
function clamp01(x: number): number {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}

/**
 * 人間捕虜を 1 体解放する (§13 解放/追放の出口)。所属勢力の敵対度をわずかに
 * 下げる (GDD §13: 低下量は控えめ = 「捕獲→解放」で敵対度をリセットさせない)。
 * 解放は中立ルートでも許される唯一の人間捕虜の出口 (生贄/苗床/売却/朝貢は不可)。
 */
export function releaseHumanCaptive(prev: WorldState, p: WorldParams, sex: Sex): WorldState {
  const w = cloneWorld(prev);
  if (sex === Sex.Male && w.capMaleHuman >= 1) w.capMaleHuman -= 1;
  else if (sex === Sex.Female && w.capFemaleHuman >= 1) w.capFemaleHuman -= 1;
  else return prev; // 解放できる人間捕虜がいない
  w.humanHostility = clamp01(w.humanHostility - p.hostilityReleaseDrop);
  return w;
}

/**
 * 敵対度 → 大規模襲撃の間隔 (日) を線形写像する (§11/KI-08 の検証帯)。
 * 和平 (0) で raidIntervalDaysAtPeace、MAX (1) で raidIntervalDaysAtMax (最短)。
 * 襲撃トリガ層がこの間隔を読んで大規模襲撃を仕掛ける = 敵対度ループの消費側。
 * 純粋関数: state を持たず、敵対度メーターだけから難度ダイヤルを引く。
 */
export function raidIntervalDays(hostility: number, p: WorldParams): number {
  const h = clamp01(hostility);
  return p.raidIntervalDaysAtPeace + (p.raidIntervalDaysAtMax - p.raidIntervalDaysAtPeace) * h;
}

/**
 * 小規模襲撃 (二層襲撃の恵み側 / §11/KI-05)。平時に日次 0〜1 回。検証済みマクロ
 * (cycle.ts) と同一ロジック: 微小損耗 (余裕で勝つ) の後、食料/捕虜の間接報酬を引く。
 * 報酬は必ず間接経路 (食料バフ→増殖 / 捕虜→苗床) を通しインフレを避ける (KI-05)。
 * 報酬は隣接ゴブリン勢力からの小競り合いとし、人間勢力の敵対度は動かさない。
 * RNG 消費順は cycle.ts と揃える (発生判定 → 報酬分岐)。
 */
function stepSmallRaid(w: WorldState, rng: Rng, p: WorldParams): void {
  if (rng.nextFloat() >= p.smallRaidProb) return;

  // 微小損耗: 頭数比ぶんを離散化 (第一期スケールでは多くの日で 0 = 余裕で勝つ)。
  const losses = Math.floor(livePop(w) * p.smallLossFrac);
  for (let n = 0; n < losses; n++) {
    const idx = w.goblins.findIndex(
      (g) => g.state !== GoblinState.Dead && !g.isUnique && !isChild(g, p)
    );
    if (idx < 0) break;
    killGoblin(w, idx, "combat");
  }

  // 報酬分岐 (食料のみ / 捕虜のみ / 両取り)。間接経路のみ (KI-05)。
  const roll = rng.nextFloat();
  const rs = p.smallRewardScale;
  const gainFood = () => {
    w.foodBuff = Math.min(p.foodBuffMax, w.foodBuff + p.foodGain * rs);
  };
  const gainCaptives = () => {
    // 隣接ゴブリン勢力から。出生比どおり雄寄りで雌雄に振り分け (CAPTIVE_COMP.goblin)。
    const total = p.captiveGainSmall * rs;
    const males = total * CAPTIVE_COMP.goblin.maleFrac;
    w.capMaleGoblin += males;
    w.capFemaleGoblin += total - males;
  };
  if (roll < p.smallFoodOnly) {
    gainFood();
  } else if (roll < p.smallFoodOnly + p.smallCaptiveOnly) {
    gainCaptives();
  } else {
    gainFood();
    gainCaptives();
  }
}

// --- 子フラグの管理 (Goblin 本体の childBornTick を使う / KI-14 で一元化) ---
function markChild(g: Goblin, tick: number): void {
  g.childBornTick = tick;
}
function childBornTick(g: Goblin): number | null {
  return g.childBornTick;
}
function isChild(g: Goblin, _p: WorldParams): boolean {
  return g.childBornTick !== null;
}
function clearChild(g: Goblin): Goblin {
  return { ...g, childBornTick: null };
}

/** World の完全な値コピー (純粋性・セーブ相当)。 */
export function cloneWorld(w: WorldState): WorldState {
  return JSON.parse(JSON.stringify(w)) as WorldState;
}
