/**
 * §5 ゴブリン自律行動 AI のステートマシン (個体 1 体・1 tick)。
 *
 * 設計の忠実な反映:
 *  - ステート順位は固定 (GoblinState の enum 値が小さいほど高優先)。
 *  - 緊急系 (死亡・激昂・恐怖・戦闘) は即時割り込み。
 *  - 欲求系 (空腹・睡眠・仕事) は「行動の切れ目」で再評価。
 *  - ヒステリシス: 発火閾値と解除閾値を別にして境界往復を防ぐ。
 *  - 恐怖の解除は「周囲に敵がいない状態が一定 tick 続く」= 安全確認ベース
 *    (時間経過でなく)。激昂との対称性・往復ループ防止 (§5)。
 *  - 族長(ユニーク)は恐怖ステートに遷移しない = 恐怖を持たない盾 (§8)。
 *  - 事故死/戦闘死は別レイヤー。ここでは戦闘死(HP経由)のみ扱い、
 *    事故死は呼び出し側(world)が離散イベントとして降らせる (§2.5/§5)。
 *
 * 純粋関数: goblin を破壊せず新しい goblin を返す。
 */
import { GoblinState, Role, type Goblin } from "./goblin.ts";

/** ステートマシンが参照する環境 (個体の外側の状況)。 */
export interface GoblinContext {
  /** 現在この個体が敵の脅威範囲にいるか (恐怖の発火・解除判定に使う)。 */
  enemyNearby: boolean;
  /** 巣全体が交戦中か (戦闘ステートへ入る条件)。 */
  inRaid: boolean;
  /** この個体が戦線に割り当てられているか。 */
  assignedToCombat: boolean;
  /** 食料が利用可能か (空腹を満たせるか)。 */
  foodAvailable: boolean;
}

/** チューニング定数 (§15 実数調整対象。第一期は妥当な仮値)。 */
export interface StateMachineParams {
  /** 恐怖発火の HP 割合 (これ未満で恐怖)。瀕死閾値より高く置く (§5前提)。 */
  fearHpFrac: number;
  /** 瀕死の HP 割合 (これ未満で寝床へ)。fearHpFrac より低い。 */
  dyingHpFrac: number;
  /** 恐怖解除に必要な「敵がいない」連続 tick 数 (安全確認)。 */
  fearClearTicks: number;
  /** 空腹の発火閾値 / 解除(満腹)閾値 (ヒステリシス)。 */
  hungerOn: number;
  hungerOff: number;
  /** 睡眠の発火閾値 / 解除閾値 (ヒステリシス)。 */
  sleepOn: number;
  sleepOff: number;
  /** 1 tick の欲求上昇量。 */
  hungerRate: number;
  sleepRate: number;
  /** 寝床/食事での 1 tick あたり HP 回復・欲求充足量。 */
  hpRegenPerTick: number;
  hungerRelievePerTick: number;
  sleepRelievePerTick: number;
  /** ユニークが倒れてから死亡するまでの搬送猶予 tick (§8)。 */
  uniqueDownedGraceTicks: number;
}

/**
 * 既定値は基準解像度 (10 tick/日 = world_params.TICKS_PER_DAY_BASE) での
 * per-tick 値。別の tick 解像度で動かすときは world_params の
 * scaleStateMachineParams で変換する (KI-02: tick/day を混同しない)。
 *
 * 欲求ペーシングは §15 調整で「観賞に耐える日次リズム」へ寄せた:
 *  - 空腹: 約 0.3〜0.4 日周期で発火 (1 日 2〜3 回食事)、食事は約 0.05 日。
 *  - 睡眠: 約 0.8 日周期で発火 (1 日 1 回眠る)、睡眠は約 0.2 日。
 * 旧値 (空腹 7 日 / 睡眠 10 日周期) は安定帯検証時の仮値で、個体が
 * ほぼ Work/Wander に張り付き観察に何も映らなかった。
 */
export const defaultStateMachineParams: StateMachineParams = {
  fearHpFrac: 0.45,
  dyingHpFrac: 0.25,
  fearClearTicks: 8, // 0.8 日ぶんの安全確認
  hungerOn: 0.7,
  hungerOff: 0.2,
  sleepOn: 0.8,
  sleepOff: 0.15,
  hungerRate: 0.175, // 0.7 まで 0.4 日 (≒1 日 2〜3 回の食事)
  sleepRate: 0.1, // 0.8 まで 0.8 日 (≒1 日 1 回の睡眠)
  hpRegenPerTick: 0.15,
  hungerRelievePerTick: 1.0, // 食事 ≒0.05 日で完了
  sleepRelievePerTick: 0.325, // 睡眠 ≒0.2 日で完了
  uniqueDownedGraceTicks: 30, // 3 日の搬送猶予
};

/**
 * 個体を 1 tick 進める。欲求の更新 → 緊急割り込み判定 → 現ステートの作用。
 */
export function stepGoblin(
  prev: Goblin,
  ctx: GoblinContext,
  p: StateMachineParams
): Goblin {
  const g: Goblin = { ...prev };

  // --- 死亡は終端 ---
  if (g.state === GoblinState.Dead) return g;

  // --- ユニークの瀕死保護 (§8): HP0 でも即死せず倒れる→搬送猶予 ---
  if (g.hp <= 0) {
    if (g.isUnique) {
      g.downedTicks = (g.downedTicks ?? 0) + 1;
      if (g.downedTicks > p.uniqueDownedGraceTicks) {
        g.state = GoblinState.Dead;
      }
      // 倒れている間はステート作用なし (非ターゲット化は world 側で扱う)。
      return g;
    } else {
      g.state = GoblinState.Dead;
      return g;
    }
  } else if (g.downedTicks !== null) {
    // 搬送・回復で HP が戻ったら起き上がる。
    g.downedTicks = null;
  }

  // --- 欲求の自然上昇 (激昂中は変化しない / §5) ---
  if (g.state !== GoblinState.Enraged) {
    g.hunger = Math.min(1, g.hunger + p.hungerRate);
    g.sleepiness = Math.min(1, g.sleepiness + p.sleepRate);
  }

  // --- ヒステリシス更新 (発火/解除の向きをラッチ) ---
  if (!g.hungerLatched && g.hunger >= p.hungerOn) g.hungerLatched = true;
  else if (g.hungerLatched && g.hunger <= p.hungerOff) g.hungerLatched = false;
  if (!g.sleepLatched && g.sleepiness >= p.sleepOn) g.sleepLatched = true;
  else if (g.sleepLatched && g.sleepiness <= p.sleepOff) g.sleepLatched = false;

  const hpFrac = g.hp / g.maxHp;

  // === 緊急系の即時割り込み (高優先から) ===

  // 激昂は外部 (奇跡) が設定し、ここでは維持/解除のみ。
  if (g.state === GoblinState.Enraged) {
    if (!ctx.inRaid && !ctx.enemyNearby) g.state = GoblinState.Wander;
    return g; // 激昂中は他へ遷移しない
  }

  // 恐怖: ユニーク(族長)は恐怖を持たない (§8)。
  if (!g.isUnique) {
    if (g.state === GoblinState.Fear) {
      // 安全確認ベースの解除: 敵がいない連続 tick を数える。
      if (ctx.enemyNearby) {
        g.fearSafeTicks = 0;
      } else {
        g.fearSafeTicks = g.fearSafeTicks + 1;
        if (g.fearSafeTicks >= p.fearClearTicks) {
          g.fearSafeTicks = 0;
          // 解除後、瀕死なら寝床へ、でなければ放浪へ。
          g.state = hpFrac < p.dyingHpFrac ? GoblinState.Dying : GoblinState.Wander;
        }
      }
      return g;
    }
    // HP が恐怖閾値を下回り、かつ敵が近いと恐怖発火 (戦闘より優先)。
    const fearThreshold = clamp01(p.fearHpFrac + g.personality.fearHpBias);
    if (ctx.enemyNearby && hpFrac < fearThreshold) {
      g.state = GoblinState.Fear;
      g.fearSafeTicks = 0;
      return g;
    }
  }

  // 戦闘: 交戦中で戦線に割り当てられていれば戦う。
  if (ctx.inRaid && ctx.assignedToCombat && ctx.enemyNearby) {
    g.state = GoblinState.Combat;
    // ダメージ処理は world の一括戦闘解決が行う (個体ループでは状態だけ)。
    return g;
  }

  // === 欲求系 (行動の切れ目で再評価。緊急系がなければここへ) ===

  // 瀕死: HP が低ければ寝床へ。
  if (hpFrac < p.dyingHpFrac) {
    g.state = GoblinState.Dying;
    g.hp = Math.min(g.maxHp, g.hp + p.hpRegenPerTick);
    return g;
  }

  // 空腹 (ラッチが立っていて食料があれば食べる)。
  if (g.hungerLatched) {
    g.state = GoblinState.Hungry;
    if (ctx.foodAvailable) {
      g.hunger = Math.max(0, g.hunger - p.hungerRelievePerTick);
    }
    return g;
  }

  // 睡眠。
  if (g.sleepLatched) {
    g.state = GoblinState.Sleep;
    g.sleepiness = Math.max(0, g.sleepiness - p.sleepRelievePerTick);
    g.hp = Math.min(g.maxHp, g.hp + p.hpRegenPerTick); // 寝ると回復
    return g;
  }

  // 仕事 (役職持ちは仕事優先。無役は放浪に流れる)。
  if (g.role !== Role.None) {
    g.state = GoblinState.Work;
    return g;
  }

  // 放浪 (受け皿)。
  g.state = GoblinState.Wander;
  return g;
}

function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}
