/**
 * ステートマシン (§5/§8) のユニットテスト。
 * GDD が明示する性質が実装に出ているかを決定的に確認する。
 */
import {
  GoblinState,
  Role,
  makeGoblin,
  neutralPersonality,
} from "../src/sim/goblin.ts";
import {
  stepGoblin,
  defaultStateMachineParams as P,
  type GoblinContext,
  type GoblinExt,
} from "../src/sim/state_machine.ts";

let failures = 0;
function check(name: string, cond: boolean) {
  console.log(`${cond ? "OK  " : "FAIL"} ${name}`);
  if (!cond) failures++;
}

const safe: GoblinContext = {
  enemyNearby: false,
  inRaid: false,
  assignedToCombat: false,
  foodAvailable: true,
};
const underThreat: GoblinContext = {
  enemyNearby: true,
  inRaid: true,
  assignedToCombat: true,
  foodAvailable: true,
};

// --- 1. 恐怖は安全確認ベースで解除される (時間でなく敵不在の連続 tick) ---
{
  let g: GoblinExt = makeGoblin(1, neutralPersonality);
  g.hp = 3; // hpFrac 0.3 < fearHpFrac 0.45
  g = stepGoblin(g, underThreat, P); // 敵が近く HP 低 → 恐怖
  check("恐怖に入る", g.state === GoblinState.Fear);

  // 敵がいる限り、何 tick 経っても解除されない
  for (let i = 0; i < 50; i++) g = stepGoblin(g, underThreat, P);
  check("敵がいる間は恐怖が解除されない(時間経過では解けない)", g.state === GoblinState.Fear);

  // 敵が去ると、fearClearTicks 連続で解除に向かう
  const noEnemy: GoblinContext = { ...underThreat, enemyNearby: false };
  for (let i = 0; i < P.fearClearTicks; i++) g = stepGoblin(g, noEnemy, P);
  check("敵不在が続くと恐怖が解除される", g.state !== GoblinState.Fear);
}

// --- 2. 族長(ユニーク)は恐怖を持たない (§8) ---
{
  let g: GoblinExt = makeGoblin(2, neutralPersonality, Role.Chief);
  g.hp = 1; // 瀕死級でも
  for (let i = 0; i < 10; i++) g = stepGoblin(g, underThreat, P);
  check("族長は恐怖ステートに入らない", g.state !== GoblinState.Fear);
  check("族長は戦闘に留まる(盾)", g.state === GoblinState.Combat);
}

// --- 3. ヒステリシスで空腹/満腹の境界往復が起きない ---
{
  let g: GoblinExt = makeGoblin(3, neutralPersonality);
  // 空腹を発火閾値ちょうどまで上げる
  g.hunger = P.hungerOn;
  g = stepGoblin(g, safe, P);
  check("空腹ラッチが立つ", g.hungerLatched);
  // 食べて hungerOff を少し下回る程度に減らす — まだ Off 閾値以下になるまでは
  // ラッチが立ち続け、ガタつかない
  g.hunger = P.hungerOff + 0.05;
  g = stepGoblin(g, safe, P);
  check("Off閾値に達するまでラッチ維持(往復しない)", g.hungerLatched);
  g.hunger = P.hungerOff - 0.01;
  g = stepGoblin(g, safe, P);
  check("Off閾値を下回ってラッチ解除", !g.hungerLatched);
}

// --- 4. ユニークの瀕死保護: HP0 で即死せず搬送猶予、超過で死亡 (§8) ---
{
  let g: GoblinExt = makeGoblin(4, neutralPersonality, Role.Chief);
  g.hp = 0;
  g = stepGoblin(g, safe, P);
  check("ユニークは HP0 で即死しない", g.state !== GoblinState.Dead);
  check("倒れ tick が進む", (g.downedTicks ?? 0) === 1);
  for (let i = 0; i < P.uniqueDownedGraceTicks + 1; i++) g = stepGoblin(g, safe, P);
  check("猶予超過で死亡", g.state === GoblinState.Dead);
}

// --- 5. 非ユニークは HP0 で即死 ---
{
  let g: GoblinExt = makeGoblin(5, neutralPersonality);
  g.hp = 0;
  g = stepGoblin(g, safe, P);
  check("非ユニークは HP0 で即死", g.state === GoblinState.Dead);
}

// --- 6. 決定性: 同じ入力列で同じ最終状態 ---
{
  const run = (): GoblinExt => {
    let g: GoblinExt = makeGoblin(6, neutralPersonality, Role.Shaman);
    const seq: GoblinContext[] = [safe, underThreat, underThreat, safe, safe];
    for (let i = 0; i < 100; i++) g = stepGoblin(g, seq[i % seq.length], P);
    return g;
  };
  const a = JSON.stringify(run());
  const b = JSON.stringify(run());
  check("ステートマシンは決定的", a === b);
}

console.log(failures === 0 ? "STATEMACHINE_OK" : `STATEMACHINE_FAIL(${failures})`);
if (failures > 0) process.exit(1);
