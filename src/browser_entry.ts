/**
 * ブラウザ可視化用のエントリポイント。
 *
 * 検証済みコア (cycle/world/state_machine/tick_driver) を一切再実装せず
 * そのまま re-export し、window に載せるだけの薄いラッパ。
 * これにより可視化は力学を二重管理せず (KI-01)、テストが保証した挙動を
 * そのままブラウザで動かせる。esbuild で IIFE バンドルして HTML に埋め込む。
 */
import { makeWorldParams, TICKS_PER_DAY_BASE } from "./sim/world_params.ts";
import {
  initWorld,
  stepWorld,
  beginRaid,
  emergencyReinforce,
  takeConcubine,
  approveBond,
  tearApartBond,
  releaseHumanCaptive,
  raidIntervalDays,
  livePop,
  totalHp,
} from "./sim/world.ts";
import { GoblinState, Role, Sex, GoblinOrigin } from "./sim/goblin.ts";
import { TickDriver } from "./sim/tick_driver.ts";

// 可視化が使う API を 1 つのオブジェクトにまとめて公開。
const GoblinSim = {
  makeWorldParams,
  TICKS_PER_DAY_BASE,
  initWorld,
  stepWorld,
  beginRaid,
  emergencyReinforce,
  takeConcubine,
  approveBond,
  tearApartBond,
  releaseHumanCaptive,
  raidIntervalDays,
  livePop,
  totalHp,
  TickDriver,
  GoblinState,
  Role,
  Sex,
  GoblinOrigin,
  // enum の逆引き (state 番号 → 名前) を可視化のラベルに使う。
  stateName: (s: number): string => GoblinState[s] ?? String(s),
  roleName: (r: number): string => Role[r] ?? String(r),
  originName: (o: number): string => GoblinOrigin[o] ?? String(o),
};

// グローバル公開 (IIFE バンドルの global name と合わせる)。
(globalThis as unknown as { GoblinSim: typeof GoblinSim }).GoblinSim = GoblinSim;

export default GoblinSim;
