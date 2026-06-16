extends SceneTree
## 演出テキスト (data/dialogue.json + data/messages.json) と TextDB ローダの検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_dialogue.gd
##   - 会話カテゴリが全て揃い非空か / プレースホルダ規約 ({name} と {other}=ペアのみ)
##   - 名前音節 (M1/M2/F1/F2) が非空で、名前生成が決定的か
##   - イベント文面キーが全て存在し、String.format が {key} を正しく埋めるか
## テキストは演出層なのでシム RNG (KI-09) には一切触れない。

const CHATTER_CATEGORIES := [
	"child", "hungry", "sleep", "work", "wander", "fear",
	"combat", "enraged", "courting", "mating", "pregnant", "chatter_pair",
	# 性別別 (発言者の性別と矛盾させない / 寝床・交尾・捕虜系)。
	"courting_m", "courting_f", "mating_m", "mating_f",
	"concubine_m", "concubine_f", "pending_bond_m", "pending_bond_f",
	"nursery",
	# 異種つがい (ゴブリン×人間)。命名 <base>_<自種><性別>_<相手種> (g/h, m/f, g/h)。
	"courting_gm_h", "mating_gm_h", "courting_gf_h", "mating_gf_h",
	"courting_hf_g", "mating_hf_g", "courting_hm_g", "mating_hm_g",
	"courting_hm_h", "mating_hm_h", "courting_hf_h", "mating_hf_h",
	"pregnant_hf_g", "pregnant_gf_h", "pregnant_hf_h", "pregnant_hf",
	"nursery_human",
	# 捕虜つがいの種族別 (ゴブリン捕虜=バカっぽい / 人間捕虜=普通の口調)。
	"concubine_gm", "concubine_gf", "pending_bond_gm", "pending_bond_gf",
	# 人間 (アミナ/承認済み捕虜) の状態別・普通口調 (ゴブリンのバカ口調と対比)。
	"hungry_h", "sleep_h", "work_h", "wander_h", "fear_h",
]

const EVENT_KEYS := [
	"raid", "raid_final", "raid_small", "raid_end", "surge",
	"death_accident", "death_combat", "fledge", "birth", "birth_nursery", "grow",
	"mite_eaten", "fumble_dropped", "fumble", "forage", "guard", "alarm",
	"quarrel", "court", "court_timeout", "mating", "pregnant", "dispatch",
	"field_spawn_forage", "field_spawn_animal", "field_spawn_traveler",
	"field_spawn_wanderer", "field_spawn_camp", "field_spawn_ruins", "field_spawn_maiden",
	"field_haul_animal", "field_haul_ruins", "field_haul", "field_captive", "field_gem",
	"field_trade_gems", "field_trade", "field_faux_pas", "wanderer_joined", "wanderer_left",
	"field_maiden_amina", "field_maiden", "field_camp_win", "field_camp_loss",
	"field_camp_loss_none", "field_recall", "field_done", "field_expire",
	"amina_foreshadow", "amina_closed", "amina_joined", "mine_done_gem", "mine_done",
	"dig_done", "build_start", "build_done", "repair_done", "breach_warn", "breach",
	"victory", "defeat_totem", "defeat", "captive_gain", "captive_joined", "sacrifice",
	"release_captive", "tribute", "tribute_gems", "gems_hoard_warn", "take_concubine",
	"pending_bond", "approve_bond", "birth_nursery_goblin", "birth_nursery_human",
	"restore", "new_game", "new_game_difficulty",
]

# 性別別カテゴリ。発言者の性別と一人称が矛盾しないことを機械的に保証する。
# 雌カテゴリに男性一人称『俺』、雄カテゴリに女性一人称が混ざっていないか検査する。
const FEMALE_CATEGORIES := [
	"courting_f", "mating_f", "concubine_f", "pending_bond_f", "pregnant",
	# 異種の雌カテゴリ (ゴブリン雌 / 人間雌)。人間雌は『わたし』口調・『俺』を使わない。
	"courting_gf_h", "mating_gf_h", "pregnant_gf_h",
	"courting_hf_g", "mating_hf_g", "courting_hf_h", "mating_hf_h",
	"pregnant_hf_g", "pregnant_hf_h", "pregnant_hf",
	# ゴブリン捕虜の雌 (バカっぽい・あたい口調・『俺』を使わない)。
	"concubine_gf", "pending_bond_gf",
]
const MALE_CATEGORIES := [
	"courting_m", "mating_m", "concubine_m", "pending_bond_m",
	# 異種の雄カテゴリ (ゴブリン雄 / 人間雄)。女性一人称『あたい/あたし』を使わない。
	"courting_gm_h", "mating_gm_h",
	"courting_hm_g", "mating_hm_g", "courting_hm_h", "mating_hm_h",
	# ゴブリン捕虜の雄 (バカっぽい・おれ口調)。
	"concubine_gm", "pending_bond_gm",
]

func _init() -> void:
	TextDB.reload()
	var ok := true
	ok = _test_chatter_present() and ok
	ok = _test_placeholders() and ok
	ok = _test_names() and ok
	ok = _test_event_keys() and ok
	ok = _test_format() and ok
	ok = _test_compose() and ok
	ok = _test_gender_voice() and ok
	ok = _test_body_traits() and ok
	if ok:
		print("DIALOGUE_OK")
		quit(0)
	else:
		print("DIALOGUE_FAIL")
		quit(1)

## 全カテゴリが存在し、現状より十分に多い (各 5 行以上) こと。
func _test_chatter_present() -> bool:
	var ok := true
	var total := 0
	for cat in CHATTER_CATEGORIES:
		var lines := TextDB.chatter_lines(cat)
		total += lines.size()
		if lines.size() < 5:
			print("  FAIL: chatter category '%s' has only %d lines (<5)" % [cat, lines.size()])
			ok = false
	if total < 200:
		print("  FAIL: total chatter lines = %d (<200) — repertoire too small" % total)
		ok = false
	if ok:
		print("  chatter-present: OK (total=%d lines across %d categories)" % [total, CHATTER_CATEGORIES.size()])
	return ok

## プレースホルダ規約: 許可は {name}/{other}/{cock}/{bust}。{other} は chatter_pair 限定。
## {cock}(雄の竿)/{bust}(雌の胸) は id 由来の身体特性で、_chat_fields が全行に渡すので任意位置可。
## %s/%d 禁止。
func _test_placeholders() -> bool:
	var ok := true
	var re := RegEx.new()
	re.compile("\\{[^}]*\\}")
	for cat in CHATTER_CATEGORIES:
		for v in TextDB.chatter_lines(cat):
			var line := String(v)
			if line.find("%s") >= 0 or line.find("%d") >= 0:
				print("  FAIL: '%s' contains %%s/%%d: %s" % [cat, line])
				ok = false
			for m in re.search_all(line):
				var tok := m.get_string()
				if tok != "{name}" and tok != "{other}" and tok != "{cock}" and tok != "{bust}":
					print("  FAIL: '%s' bad placeholder %s in: %s" % [cat, tok, line])
					ok = false
				if tok == "{other}" and cat != "chatter_pair":
					print("  FAIL: '{other}' outside chatter_pair in '%s': %s" % [cat, line])
					ok = false
	if ok:
		print("  placeholders: OK")
	return ok

## 名前音節が非空で、名前生成が決定的 (同 id → 同名) であること。
func _test_names() -> bool:
	var ok := true
	for k in ["M1", "M2", "F1", "F2"]:
		if TextDB.names(k).is_empty():
			print("  FAIL: name pool '%s' is empty" % k)
			ok = false
	var a := GobNames.name_of(42, Goblin.Sex.MALE)
	var b := GobNames.name_of(42, Goblin.Sex.MALE)
	if a != b:
		print("  FAIL: name_of not deterministic (%s != %s)" % [a, b])
		ok = false
	if a.is_empty():
		print("  FAIL: name_of returned empty")
		ok = false
	if ok:
		print("  names: OK (例: 雄#42=%s 雌#42=%s)" % [a, GobNames.name_of(42, Goblin.Sex.FEMALE)])
	return ok

## 全イベントキーが存在する (fallback に落ちない) こと。
func _test_event_keys() -> bool:
	var ok := true
	for key in EVENT_KEYS:
		if TextDB.msg(key, {}, "<MISSING>") == "<MISSING>":
			print("  FAIL: event message key missing: %s" % key)
			ok = false
	if ok:
		print("  event-keys: OK (%d keys)" % EVENT_KEYS.size())
	return ok

## String.format が {key} を (文字列・数値とも) 正しく埋め、取りこぼしが無いこと。
func _test_format() -> bool:
	var ok := true
	# 数値の埋め込み (count) と取りこぼし無し。
	var s1 := TextDB.msg("raid", {"who": "人間の討伐隊", "count": 7})
	if s1.find("人間の討伐隊") < 0 or s1.find("7") < 0 or s1.find("{") >= 0:
		print("  FAIL: format raid → '%s'" % s1)
		ok = false
	# 会話セリフの {name} 埋め込み。
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var c := TextDB.pick_chatter("hungry", rng, {"name": "ゴブA"})
	if c.is_empty() or c.find("{") >= 0:
		print("  FAIL: pick_chatter hungry → '%s'" % c)
		ok = false
	# ペアセリフの {name}/{other} 両方。
	var p := TextDB.pick_chatter("chatter_pair", rng, {"name": "ゴブA", "other": "ゴブB"})
	if p.is_empty() or p.find("{") >= 0:
		print("  FAIL: pick_chatter chatter_pair → '%s'" % p)
		ok = false
	# label の既定フォールバック。
	if TextDB.label("raid_who", "unknown_faction") != "敵対氏族の群れ":
		print("  FAIL: label _default fallback broken")
		ok = false
	if TextDB.label("raid_who", "human") != "人間の討伐隊":
		print("  FAIL: label lookup broken")
		ok = false
	if ok:
		print("  format: OK (例: %s)" % s1)
	return ok

## 身体特性 (Goblin.endowment/bust) が 0..1 の範囲で、同じ id は常に同じ値 (決定的・保存不要)。
## 異なる id ではばらつく (一様でない種 §3.5)。竿と胸は独立した混合であること。
func _test_body_traits() -> bool:
	var ok := true
	for gid in [0, 1, 42, 1000, 99999]:
		var e := Goblin.endowment(gid)
		var b := Goblin.bust(gid)
		if e < 0.0 or e >= 1.0 or b < 0.0 or b >= 1.0:
			print("  FAIL: 身体特性が 0..1 外 id=%d e=%f b=%f" % [gid, e, b])
			ok = false
		if e != Goblin.endowment(gid) or b != Goblin.bust(gid):
			print("  FAIL: 身体特性が非決定的 id=%d" % gid)
			ok = false
	# ばらつき: 多数の id で竿サイズが一様に偏らない (最小と最大が十分離れる)。
	var lo := 1.0
	var hi := 0.0
	for gid in range(200):
		var e := Goblin.endowment(gid)
		lo = minf(lo, e)
		hi = maxf(hi, e)
	if hi - lo < 0.5:
		print("  FAIL: 竿サイズのばらつきが小さい (range=%f)" % (hi - lo))
		ok = false
	if ok:
		print("  body-traits: OK (例: id42 竿=%.2f 胸=%.2f)" % [Goblin.endowment(42), Goblin.bust(42)])
	return ok

## 性別別カテゴリの一人称が、発言者の性別と矛盾しないこと。
## 雌カテゴリ (妊娠含む) に男性一人称『俺』、雄カテゴリに女性一人称『あたい/あたし』が
## 混ざっていないかを検査する。共有カテゴリ (hungry/work 等) はゴブリン共通口調なので対象外。
func _test_gender_voice() -> bool:
	var ok := true
	for cat in FEMALE_CATEGORIES:
		for v in TextDB.chatter_lines(cat):
			var line := String(v)
			if line.find("俺") >= 0:
				print("  FAIL: 雌カテゴリ '%s' に男性一人称『俺』: %s" % [cat, line])
				ok = false
	for cat in MALE_CATEGORIES:
		for v in TextDB.chatter_lines(cat):
			var line := String(v)
			if line.find("あたい") >= 0 or line.find("あたし") >= 0:
				print("  FAIL: 雄カテゴリ '%s' に女性一人称: %s" % [cat, line])
				ok = false
	if ok:
		print("  gender-voice: OK (雌%d/雄%d カテゴリ)" % [FEMALE_CATEGORIES.size(), MALE_CATEGORIES.size()])
	return ok

## R-18 地の文の合成 (data/adult.json / ランダム表記)。非空・スロット取りこぼし無し・
## {name}/{other} 解決を確認。性別別 (雄/雌) + つがい両者 + 苗床の各グラマを検証。
## 未知グラマは "" を返す。
func _test_compose() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	# 個体視点 (ゴブリン m/f・人間 hm/hf)。相手呼称 {mate}・身体特性 {cock}/{bust}/{mate_cock} を
	# 渡す。異種・各サイズでも {} の取りこぼしが無いこと。
	for gk in ["mating_explicit_m", "mating_explicit_f", "mating_explicit_hm", "mating_explicit_hf"]:
		for mate in ["雌", "雄", "人間の女", "人間の男"]:
			var solo := TextDB.compose(gk, rng, {"name": "ゴブA", "mate": mate,
					"cock": "凶悪な巨根", "bust": "たわわな巨乳", "mate_cock": "長大な逸物"})
			if solo.is_empty() or solo.find("{") >= 0:
				print("  FAIL: compose %s (mate=%s) → '%s'" % [gk, mate, solo])
				ok = false
	# つがい両者 (フィード)。{fpre}/{mpre} に種族接頭辞を渡す (異種/同種の両方)。
	for pre in [["", ""], ["人間の ", ""], ["", "人間の "]]:
		var pair := TextDB.compose("mating_explicit_pair", rng,
				{"name": "ゴブA", "other": "ゴブB", "fpre": pre[0], "mpre": pre[1]})
		if pair.is_empty() or pair.find("{") >= 0:
			print("  FAIL: compose mating_explicit_pair (fpre=%s mpre=%s) → '%s'" % [pre[0], pre[1], pair])
			ok = false
	# 苗床 (ゴブリン母体 / 人間母体)。
	var nursery := ""
	for nk in ["nursery_explicit", "nursery_explicit_human"]:
		nursery = TextDB.compose(nk, rng, {})
		if nursery.is_empty() or nursery.find("{") >= 0:
			print("  FAIL: compose %s → '%s'" % [nk, nursery])
			ok = false
	if TextDB.compose("does_not_exist", rng, {}) != "":
		print("  FAIL: compose unknown grammar should return ''")
		ok = false
	if ok:
		print("  compose: OK (例: %s)" % nursery)
	return ok
