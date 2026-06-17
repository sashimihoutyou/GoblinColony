# CLAUDE.md

このファイルは、Claude Code（claude.ai/code）がこのリポジトリで作業する際の指針です。

## プロジェクト概要

**GoblinColony** はゴブリン・コロニーのターン/リアルタイム混在シミュレーションゲーム。
Godot 4.6 / GDScript で実装。設計思想は **力学先行・描画後回し**。GDD §12 と `known_issues` の
机上検証で固めた力学を正確に実装し、その一致を機械的に保証する。

## ディレクトリ構成（重要）

```
Game/                           Godot 4.6 プロジェクト
  data/
    adult.json                  R-18 地の文の合成素材（ランダム表記）
    dialogue.json               会話セリフ（状態別カテゴリ）+ 名前音節
    messages.json               イベントフィード文面 + ラベル
  scenes/
    Main.tscn                   メインシーン
  scripts/
    sim/                        シミュレーション層（純粋力学）
      world.gd  goblin.gd  params.gd  state_machine.gd
      rng.gd  pathfinding.gd  tile_map.gd  map_template.gd
      field_resource.gd  mite.gd  enemy.gd
    render/                     演出層（描画・テキスト・名前）
      renderer.gd  text_db.gd  gob_names.gd
    play/                       操作層
      controller.gd  auto_controller.gd
    main.gd                     エントリポイント（フィード・会話ログ・R-18 地の文合成）
    test_*.gd                   ヘッドレステスト群（20+ スイート）
tools/
  godot/                        Godot 4.6 バイナリ同梱（setup.sh で展開）
```

| パス | 役割 |
|------|------|
| `Game/scripts/sim/world.gd` | World 層。全個体を 1 tick 進め、移動・戦闘解決・出生・事故死・襲撃を処理。 |
| `Game/scripts/sim/goblin.gd` | 個体ゴブリンの型（§5 ステート / 性格 / 役職 / 進行中フラグ）。 |
| `Game/scripts/sim/params.gd` | **力学定数の単一の真実源**（KI-01）。日次レートを per-tick へ変換。 |
| `Game/scripts/sim/state_machine.gd` | §5 個体ステートマシン。1 体・1 tick の純粋遷移。 |
| `Game/scripts/sim/rng.gd` | 決定的 xorshift128 PRNG。状態を完全に保存・復元（KI-09）。 |
| `Game/scripts/sim/pathfinding.gd` | A* 経路探索（56×40 有機洞窟マップ）。 |
| `Game/scripts/sim/tile_map.gd` | タイルマップデータ（部屋・巣口・床キャッシュ）。 |
| `Game/scripts/render/text_db.gd` | 演出テキストの一元ロード。`compose()` で R-18 地の文を合成。 |
| `Game/scripts/render/renderer.gd` | 描画層。個体の補間移動・パーティクル・UI 更新。 |
| `Game/scripts/main.gd` | エントリポイント。フィード・会話ログ・R-18 地の文合成・操作受付。 |
| `Game/data/adult.json` | R-18 地の文のスロット文法（`TextDB.compose` が合成）。 |
| `Game/data/dialogue.json` | 会話セリフ + 名前音節。`TextDB.pick_chatter` が選択。 |
| `Game/data/messages.json` | イベントフィード文面 + ラベル。`TextDB.msg` が整形。 |

### タイムスケール

1 tick = 0.75 実秒 × `ticks_per_day=240` = 1 日 180 秒（3x で 60 秒。昼 8 割）。
per-tick 定数は `params.gd` が日次レートから変換する（KI-02。per-tick 定数を素で書かない）。

## 守るべき不変条件 / コーディング規約

- **決定的 Rng に統一**。RNG 状態は `world.rng`（xorshift128）に保存する。RNG の**消費順序を変えない**。
- **全状態を tick の関数として閉じる（KI-09）**。セーブ/ロード往復はバイト一致が必須。
  セーブ状態に実時間を含めない（保持するのは `tick` / `day` のみ）。
- **力学定数は `params.gd` が単一の真実源（KI-01）**。World 層は日次レートを tick レートへ
  *変換*するのみで、レートをその場で再定義しない。
- 比率は小数で表現する（0.15 = 15%）。`tick` と `day` のスケールを混同しない（KI-02）。
- **裏で難度を動かすフックは作らない**（KI-10: DDA 不採用。固定のレイドスケジュール）。
- 既存ファイルのコメント密度・命名（`cap`=容量, `cum`=累積, `pop`=人口 等）に合わせる。
- ステートは優先度順の数値 enum（値が小さいほど高優先）。コア層では文字列ステート名を使わない。
- **演出テキストはシム RNG を消費しない**（KI-09）。`_conv_rng`（演出 RNG）のみ使用。

## ビルド / テストコマンド

`godot` が無い環境（Claude Code リモート実行等）では同梱バイナリを使う:
`tools/godot/setup.sh` で展開し、`tools/godot/Godot_v4.6-stable_linux.x86_64` を
`godot` の代わりに実行する（Linux x86_64 / 4.6-stable。zip 同梱・展開物は gitignore）。

```
godot --headless --path Game --import                                    # 初回のみ (グローバルクラスキャッシュ生成)
godot --headless --path Game --script res://scripts/test_smoke.gd        # SMOKE_OK (マップ検証含む)
godot --headless --path Game --script res://scripts/test_scene_smoke.gd  # SCENE_SMOKE_OK
godot --headless --path Game --script res://scripts/test_miracles.gd     # MIRACLES_OK (§3/§4 奇跡+ランク)
godot --headless --path Game --script res://scripts/test_dialogue.gd     # DIALOGUE_OK (演出テキスト + TextDB)
godot --headless --path Game --script res://scripts/test_seeds.gd        # 多シード勝率 (手動・数分)
```

**演出テキストは `Game/data/*.json` に集約**。コードを触らず JSON を編集するだけで増減できる。
編集後は `test_dialogue.gd` で検証。詳細は `Game/README.md`「セリフ・テキストの編集」。

### ⚠ 既知の落とし穴（着手前に必読）

- **Godot 第二期の実装状況は `backlog.md`、設計教訓は `known_issues_world.md` KI-27〜29 が一次情報。**
  実行時のタイル改変は床キャッシュ再構築が必須（KI-27）／autosave はテキスト精度の限界ゆえ
  「ロード後決定」を保証する設計（KI-28）／防衛・各新力学の実数は D1 で一括調整（KI-29）。
- **サブエージェント（`isolation:worktree`）はローカル HEAD でなく古いリモート ref から分岐しうる。**
  マージ前に `git merge-base HEAD <worktree-branch>` で分岐ベースを検証し、ズレていれば差分を
  現 HEAD へ手で再適用する。完了報告を鵜呑みにせずメイン側で全スイート再検証する（AGENTS.md 詳述）。
- **reproduction/襲撃系は稼働済み（KI-22〜25）。** 求愛→つがい→出産、人間母体の苗床、敵対度メーター、
  自動襲撃スケジューラ、二層襲撃の小規模側まで実装・検証済み。実数バランスは §15 調整対象で、
  力学の確定前提を崩さないよう安易にいじらないこと。

## 設計資料への入口（最初に読むべき順）

1. `README.md` — プロジェクト概要。
2. `backlog.md` — **残タスクの一次情報**（三面照合監査 `feature_gap_audit.md` が母体）。
3. `known_issues.md` — KI-01〜KI-21 の設計教訓（過去の検証で潰したバグと解決策）。
4. `known_issues_world.md` — World 層 / Godot 第二期の設計教訓（KI-12〜29）。
5. `goblin_colony_gdd_v10.md` — GDD 全文（§1〜§15 のメカニクス・バランスループ）。
6. `goblin_world_bible_v2.md` — 世界観 / ロア。

## 次の一手（残タスク）

**残タスクの一次情報は `backlog.md`**（三面照合監査 `feature_gap_audit.md` が母体）。
Godot 本体の主要力学は実装・検証済み（ヘッドレス 15 スイートが緑）。残るのは:

1. **B7** P2 UI 群 — 4 分割ダイヤルの資源/建築/撤去・任命 UI・ミニカード列・通知の階層化。
2. **B11/B12** 個体成長（戦闘微経験値）・オンボーディング（初期盤面 spec 突き合わせ・助走窓・
   文脈駆動チュートリアル）。
3. **C2** AutoController 牧場補充の矛盾修正 / **C3** §15 調整インフラ（パラメータ上書き・テレメトリ・
   夜間バッチ自動化）/ **C4** 性能計測。
4. **D1** §15 実数調整（KI-29: 防衛ラインの隘路迎撃で勝率が 6/6 へ易化したのを「辛勝レンジ」へ戻す。
   C3 が前提）→ **D2** 勝敗演出 + 最終 QA。

依存関係・完了済み・各タスクの詳細は `backlog.md` を参照。
