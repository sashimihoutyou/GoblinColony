# R-18 地の文フェーズ拡張 — 改善案まとめ（Claude Code 向け）

## 背景

現行の R-18 地の文システム（`adult.json` + `TextDB.compose`）は「挿入中」の
一枚岩で、前戯も射精もクライマックスも同じプールから引かれる。
`dialogue.json` 側には `mating_climax_m/f` が既にあり、通常→クライマックスの
切り替え処理は存在するはず。この仕組みを地の文側にも拡張し、
フェーズ進行で描写が変化する設計にする。

参照: `goblin_colony_adult_style_guide.md`（文体原則）

---

## 1. フェーズ設計

### 1.1 フェーズ定義

```
enum MatingPhase {
  FOREPLAY,   // 前戯（手コキ・フェラ・パイズリ・素股・愛撫）
  INSERTION,  // 挿入（現行の mating_explicit_* がここに相当）
  CLIMAX,     // クライマックス（射精・絶頂・孕み）
}
```

3フェーズ。`FOREPLAY → INSERTION → CLIMAX` の順に遷移する。
逆行しない（§0 前向きのみ）。

**苗床（nursery）は別系統**。苗床は「日常的に犯され続けている」状態であり、
つがいの交尾フェーズとは独立。苗床にはフェーズ遷移を持たせず、
既存の `nursery_explicit` / `nursery_explicit_human` をスロット語彙の
品質向上のみで対応する。

### 1.2 フェーズ遷移のトリガー

交尾イベントの tick 経過で自動遷移する設計を推奨。

```
mating_start (court 成立)
  → FOREPLAY（最初の数 tick）
  → INSERTION（中盤）
  → CLIMAX（終了直前〜mating_end）
```

遷移比率の目安: FOREPLAY 20% / INSERTION 60% / CLIMAX 20%。
ただし数値は §15（実機調整）送り。

### 1.3 セリフ（dialogue.json）との対応

| フェーズ | 地の文（adult.json） | セリフ（dialogue.json） |
|---------|---------------------|----------------------|
| FOREPLAY | `foreplay_*` (新設) | `mating_m` / `mating_f` の前半（既存で流用可） |
| INSERTION | `mating_explicit_*` (既存・改修) | `mating_m` / `mating_f` の後半（既存で流用可） |
| CLIMAX | `climax_explicit_*` (新設) | `mating_climax_m` / `mating_climax_f` (既存) |

セリフ側は既に通常/クライマックスの分離があるため、
地の文側のフェーズ切り替えを追加するだけで連動する。

---

## 2. adult.json の文法キー拡張

### 2.1 新設キー一覧

```
// ── 前戯（FOREPLAY）──
"foreplay_m"              // ゴブリン雄が行う前戯（手コキ・愛撫等）
"foreplay_f"              // ゴブリン雌が受ける/行う前戯
"foreplay_hm"             // 人間雄の前戯
"foreplay_hf"             // 人間雌の前戯
"foreplay_oral_m"         // フェラ（雄視点＝される側）
"foreplay_oral_f"         // フェラ（雌視点＝する側）/ クンニ（雌視点＝される側）
"foreplay_paizuri"        // パイズリ（胸で挟む側の視点）
"foreplay_sumata"         // 素股
"foreplay_pair"           // つがい前戯（{name}=雌・{other}=雄）

// ── クライマックス（CLIMAX）──
"climax_explicit_m"       // 雄のクライマックス地の文
"climax_explicit_f"       // 雌のクライマックス地の文
"climax_explicit_hm"      // 人間雄のクライマックス
"climax_explicit_hf"      // 人間雌のクライマックス
"climax_explicit_pair"    // つがいクライマックス

// ── 苗床（既存・語彙改修のみ）──
"nursery_explicit"        // (既存) ゴブリン母体
"nursery_explicit_human"  // (既存) 人間母体

// ── 既存（INSERTION、語彙改修）──
"mating_explicit_m"       // (既存) 挿入中・雄視点
"mating_explicit_f"       // (既存) 挿入中・雌視点
"mating_explicit_hm"      // (既存) 挿入中・人間雄
"mating_explicit_hf"      // (既存) 挿入中・人間雌
"mating_explicit_pair"    // (既存) 挿入中・つがい
```

### 2.2 前戯のサブ行為選択

前戯フェーズでは、呼び出し時に行為タイプを選択して文法キーを切り替える。

```gdscript
# 前戯の行為タイプ（ランダムまたは状況依存で選択）
enum ForeplayAct {
  GENERAL,    # 愛撫・手コキ等の汎用 → foreplay_m/f
  ORAL,       # フェラ・クンニ → foreplay_oral_m/f
  PAIZURI,    # パイズリ → foreplay_paizuri（胸サイズ条件あり）
  SUMATA,     # 素股 → foreplay_sumata
}
```

**パイズリの発生条件**: 人間雌、または胸スロット `{bust}` が
「大きい」系の値を持つ個体のみ（ゴブリン雌は基本的に小柄なため
パイズリが成立しにくい。人間雌×ゴブリン雄、または人間雌×人間雄で発生）。
ゴブリン雌の場合は素股や手コキにフォールバックする。

**行為タイプの選択ロジック（提案）**:
```
if 苗床:
  フェーズ遷移なし（既存の nursery_explicit を使用）
elif つがい交尾:
  foreplay_act = _conv_rng から GENERAL/ORAL/SUMATA をランダム選択
  if 雌が人間 && 胸が大きい:
    PAIZURI も候補に追加
  compose(foreplay_{act}_{gender}, _conv_rng, fields)
```

### 2.3 苗床の輪姦描写の統合

現在 `dialogue.json` の `nursery` カテゴリに輪姦的なセリフが直書きされている
（「前も後ろも口も」「三方から」「{n}雄に群がられ」等）。
これらは以下のように整理する:

- **地の文（即物的描写）** → `adult.json` の `nursery_explicit` / `nursery_explicit_human` に統合
- **セリフ（ゴブリンの幼児的な台詞）** → `dialogue.json` の `nursery` に残す
- **重複する地の文的記述を dialogue.json から除去**

`nursery_explicit` に輪姦用スロットを追加:
```json
"hole": ["前も後ろも口も", "三つの穴を同時に", ...],  // 既存
"num": ["二匹の", "三匹の", ...],                       // 既存
"gangbang": [                                            // 新設: 複数同時の体勢描写
  "群がる雄たちに順番も構わず貫かれ",
  "空いた穴を奪い合う雄たちに揉みくちゃにされ",
  "三方から同時に突かれ、もはやどの雄のものか分からず",
  ...
]
```

---

## 3. スロット語彙の改修方針

### 3.1 全カテゴリ共通

文体原則（`goblin_colony_adult_style_guide.md`）§1〜§2 を適用:
- 行為と反応を一文に編む
- 感覚語を最低1つ含める
- 「〜た。」連鎖を避ける coda バリエーション
- 擬音を文中に編み込む

### 3.2 フェーズ別スロット語彙の差分

#### FOREPLAY のスロット例

```json
"foreplay_m": {
  "templates": [
    "寝床で {name} が{mate}の{target}を{touch}、{reaction}。",
    "{name} が{mate}を{posture}、{touch}{intens}——{reaction}。",
    "{name} の{hand}が{mate}の{target}を{touch}、{coda}"
  ],
  "touch": [
    "ごつごつした指でまさぐり",
    "爪を立てないよう慎重に撫で",
    "小さな手で握り込み",
    "舌先でちろちろと舐め",
    "鼻先をすりつけながら嗅ぎ回り"
  ],
  "target": [
    "太腿の内側",
    "蜜壺の縁",
    "乳の先",
    "うなじ",
    "尻の割れ目"
  ],
  "hand": [
    "ごつごつした小さな手",
    "短い指",
    "爪の硬い手のひら"
  ],
  "reaction": [
    "{mate}の肌がぴくりと震えた",
    "{mate}の吐息が少し荒くなる",
    "蜜がじわりと滲み始めている",
    "{mate}が小さく身じろぎした"
  ],
  ...
}
```

#### FOREPLAY_ORAL（フェラ・雌視点＝する側）の例

```json
"foreplay_oral_f": {
  "templates": [
    "{name} が{mate_cock}を{oral_act}、{reaction}。{coda}",
    "寝床で {name} が{mate_cock}に{oral_act}——{coda}",
    "{name} の小さな口が{mate_cock}を{oral_act}{intens}、{coda}"
  ],
  "oral_act": [
    "頬張るように咥え込み",
    "舌先でちろちろと舐め上げ",
    "喉の奥まで押し込まれ",
    "先端を唇で転がし",
    "両手で包みながらしゃぶり"
  ],
  "reaction": [
    "咥えきれない分が唇の端から溢れる",
    "喉がごくりと鳴った",
    "{mate_cock}の熱が口いっぱいに広がる"
  ],
  "coda": [
    "口の中で脈打つ{mate_cock}に、目を潤ませている。",
    "唾液が顎を伝い、藁にぽたぽたと落ちる。",
    "小さな口を限界まで広げて、夢中でしゃぶり続けている。",
    "喉の奥で精を受け止め、ごく、ごく、と飲み込んだ。",
    "咥えきれず口から零れた分が、胸まで糸を引いている。"
  ]
}
```

#### FOREPLAY_PAIZURI の例

```json
"foreplay_paizuri": {
  "templates": [
    "{name} が{bust}で{mate_cock}を{paizuri_act}、{coda}",
    "{mate_cock}が{name}の{bust}に{paizuri_recv}、{coda}",
    "{name} の{bust}が{mate_cock}を包み込み、{paizuri_act}{intens}。{coda}"
  ],
  "paizuri_act": [
    "押し潰すように挟み込み",
    "谷間でぬるぬると扱き",
    "柔肉で包んで上下に揺すり",
    "寄せた胸の隙間から先端を覗かせ"
  ],
  "paizuri_recv": [
    "埋もれて蒸れた熱を放ち",
    "挟まれた圧に脈打ち",
    "谷間を滑るたび先走りを零し"
  ],
  "coda": [
    "谷間から溢れた先走りが、{name}の首筋を伝っていく。",
    "{mate_cock}の熱が{bust}越しに伝わり、乳首がじんわりと立つ。",
    "挟みきれない分が谷間から突き出て、ぴくぴくと震えている。",
    "{bust}の圧に耐えかねた{mate_cock}が、谷間に精を吐き出した。"
  ]
}
```

#### CLIMAX の例

```json
"climax_explicit_m": {
  "templates": [
    "{name} が{mate}の最奥で{climax_act}、{climax_coda}",
    "{name} の{cock}が{climax_pulse}、{climax_coda}",
    "寝床に{name}の獣じみた咆哮が響き——{climax_coda}"
  ],
  "climax_act": [
    "腰を押しつけたまま痙攣し",
    "最後のひと突きで奥まで貫き",
    "のしかかったまま動きを止め"
  ],
  "climax_pulse": [
    "どくどくと脈打ち、止まらない量の種を放つ",
    "びくびくと震え、精が溢れるほど注がれていく",
    "最奥で爆ぜ、子宮口に密着したまま放ち続ける"
  ],
  "climax_coda": [
    "溢れた種が繋がりの隙間から泥に垂れ、藁を濡らしていく。",
    "{mate}の腹がわずかに膨らみ、注がれた量を物語っている。",
    "汗だくの体が折り重なり、荒い息だけが寝床に満ちる。",
    "最後の一滴まで搾り出され、{name}は獣のように崩れ落ちた。",
    "{mate}の体が大きく痙攣し——二匹は繋がったまま、動かなくなった。"
  ]
}
```

---

## 4. 実装タスク一覧

### 4.1 データ（adult.json）

- [ ] 前戯系キー新設: `foreplay_m`, `foreplay_f`, `foreplay_hm`, `foreplay_hf`,
      `foreplay_oral_m`, `foreplay_oral_f`, `foreplay_paizuri`, `foreplay_sumata`,
      `foreplay_pair`
- [ ] クライマックス系キー新設: `climax_explicit_m`, `climax_explicit_f`,
      `climax_explicit_hm`, `climax_explicit_hf`, `climax_explicit_pair`
- [ ] 既存 `mating_explicit_*` のスロット語彙を文体原則に沿って改修
- [ ] 既存 `nursery_explicit` / `_human` のスロット語彙改修 + `gangbang` スロット追加
- [ ] `dialogue.json` の `nursery` から地の文的記述を除去し、adult.json に統合

### 4.2 コード（合成エンジン・フェーズ遷移）

- [ ] `MatingPhase` enum 追加（FOREPLAY / INSERTION / CLIMAX）
- [ ] 交尾イベントの tick 管理に MatingPhase 遷移ロジック追加
- [ ] `_conversation_line` の mating 分岐で MatingPhase に応じた文法キー選択
- [ ] `_push_feed_event` の "mating" で MatingPhase に応じた文法キー選択
- [ ] 前戯のサブ行為選択ロジック（ForeplayAct enum + ランダム選択）
- [ ] パイズリの発生条件チェック（人間雌 or 胸サイズ条件）

### 4.3 テスト

- [ ] `test_dialogue.gd` に全新設キーの compose 検証追加
- [ ] フェーズ遷移の tick 境界テスト
- [ ] R-18 OFF 時のフォールバック確認（新設キー全てが通常文面に戻ること）
- [ ] `adult.json` 削除時の完全フォールバック確認
- [ ] スロット語彙に `{}` が含まれていないことの静的チェック

### 4.4 設計制約（不変条件）

- **演出 RNG のみ使用**（KI-09）: `_conv_rng` で合成。`world.rng` は触らない。
- **セーブ非対象**: MatingPhase はセーブに含めない。交尾イベントの残り tick から
  復元可能な導出値とする（KI-09 のスナップショット原則）。
- **R-18 OFF / adult.json 不在 → 通常文面フォールバック**: 既存設計を維持。
- **子供カテゴリへの性的内容混入を構造的に防止**: `not is_child()` ガード維持。

---

## 5. dialogue.json 側のフェーズ対応（参考）

セリフ側は既存の `mating_m/f` と `mating_climax_m/f` の分離で
概ね対応できるが、前戯専用のセリフカテゴリを追加すると密度が上がる。

### 5.1 追加候補

```json
"mating_foreplay_m": [
  "{name}「さわる…さわるぞ…えへへ」",
  "{name}「ここ、やわらかい…すき…」",
  "{name}「なめる！ なめなめ、する！ じっとしろ！」",
  "{name}「おっきい ちち、もみもみ！ おれの！」",
  "{name}「しごく！ しごしご！ おれ、じょうず？」",
  ...
],
"mating_foreplay_f": [
  "{name}「あう…そこ、くすぐったい…」",
  "{name}「もっと、やさしく…あう…」",
  "{name}「したの、さわらないで…あ、さわって…」",
  "{name}「ちち、もむの…じょうず…えへ…」",
  ...
]
```

コミカルな幼児語はセリフ側で担い、地の文との二層トーンを維持する。

### 5.2 人間捕虜・側室のフェーズ対応

人間セリフ（`mating_hm_g`, `mating_hf_g` 等）にも前戯→クライマックスの
トーン変化を持たせる。人間は言葉が崩壊していく過程が描ける
（最初は理性的→快感で途切れる→言葉にならない）。

---

## 6. 移行戦略

### 段階1: 文体原則の適用（データのみ）
- 既存 `mating_explicit_*` のスロット語彙を文体原則で書き直す
- `nursery_explicit` / `_human` の語彙改修
- この段階ではフェーズ遷移なし。品質向上のみ。

### 段階2: フェーズ遷移の実装（コード）
- `MatingPhase` enum + 遷移ロジック
- 前戯・クライマックスの文法キー新設
- `test_dialogue.gd` 拡張

### 段階3: サブ行為の追加（データ＋コード）
- `foreplay_oral_*`, `foreplay_paizuri`, `foreplay_sumata` 新設
- ForeplayAct 選択ロジック
- パイズリ条件チェック

### 段階4: dialogue.json のフェーズ対応（データ）
- `mating_foreplay_m/f` 新設
- 人間セリフのフェーズ分離
- `nursery` からの地の文除去・統合
