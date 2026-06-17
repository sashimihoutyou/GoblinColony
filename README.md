# GoblinColony — ゴブリン・コロニーシム

ゴブリン・コロニーのターン/リアルタイム混在シミュレーションゲーム。
Godot 4.6 / GDScript で実装。

## 構成

```
Game/                           Godot 4.6 プロジェクト
  data/
    adult.json                  R-18 地の文の合成素材 (ランダム表記)
    dialogue.json               会話セリフ・名前音節
    messages.json               イベントフィード文面・ラベル
  scenes/
    Main.tscn                   メインシーン
  scripts/
    sim/                        シミュレーション層 (純粋力学)
      world.gd  goblin.gd  params.gd  state_machine.gd
      rng.gd  pathfinding.gd  tile_map.gd  map_template.gd
      field_resource.gd  mite.gd  enemy.gd
    render/                     演出層 (描画・テキスト・名前)
      renderer.gd  text_db.gd  gob_names.gd
    play/                       操作層
      controller.gd  auto_controller.gd
    main.gd                     エントリポイント
    test_*.gd                   ヘッドレステスト群 (20+ スイート)
tools/
  godot/                        Godot 4.6 バイナリ同梱 (setup.sh で展開)
```

**シム (scripts/sim/) と演出 (scripts/render/) の分離**が基本規律。
補間位置・パーティクル・名前は描画層ローカルでシム状態に書き込まない (KI-09)。

## 検証コマンド

`godot` が無い環境では `tools/godot/setup.sh` で展開し、
`tools/godot/Godot_v4.6-stable_linux.x86_64` を `godot` の代わりに実行する。

```bash
godot --headless --path Game --import                                    # 初回のみ
godot --headless --path Game --script res://scripts/test_smoke.gd        # SMOKE_OK
godot --headless --path Game --script res://scripts/test_scene_smoke.gd  # SCENE_SMOKE_OK
godot --headless --path Game --script res://scripts/test_miracles.gd     # MIRACLES_OK
godot --headless --path Game --script res://scripts/test_dialogue.gd     # DIALOGUE_OK
godot --headless --path Game --script res://scripts/test_seeds.gd        # 多シード勝率 (手動)
```

## 設計資料

1. `backlog.md` — 残タスクの一次情報
2. `known_issues.md` / `known_issues_world.md` — 設計教訓 (KI-01〜29)
3. `goblin_colony_gdd_v10.md` — GDD 全文 (§1〜§15)
4. `goblin_world_bible_v2.md` — 世界観 / ロア
5. `Game/README.md` — Godot 版の詳細ドキュメント
