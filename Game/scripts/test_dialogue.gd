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
]

const EVENT_KEYS := [
	"raid", "raid_final", "raid_small", "raid_end", "surge",
	"death_accident", "death_combat", "fledge", "birth", "birth_nursery", "grow",
	"mite_eaten", "fumble_dropped", "fumble", "forage", "guard", "alarm",
	"quarrel", "court", "mating", "pregnant", "dispatch",
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
	"pending_bond", "approve_bond", "restore", "new_game", "new_game_difficulty",
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

## プレースホルダ規約: 許可は {name} と {other} のみ。{other} は chatter_pair 限定。%s/%d 禁止。
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
				if tok != "{name}" and tok != "{other}":
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

## R-18 地の文の合成 (data/adult.json / ランダム表記)。非空・スロット取りこぼし無し・
## {name}/{other} 解決を確認。未知グラマは "" を返す。
func _test_compose() -> bool:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var solo := TextDB.compose("mating_explicit", rng, {"name": "ゴブA"})
	if solo.is_empty() or solo.find("{") >= 0:
		print("  FAIL: compose mating_explicit → '%s'" % solo)
		ok = false
	var pair := TextDB.compose("mating_explicit_pair", rng, {"name": "ゴブA", "other": "ゴブB"})
	if pair.is_empty() or pair.find("{") >= 0:
		print("  FAIL: compose mating_explicit_pair → '%s'" % pair)
		ok = false
	if TextDB.compose("does_not_exist", rng, {}) != "":
		print("  FAIL: compose unknown grammar should return ''")
		ok = false
	if ok:
		print("  compose: OK (例: %s)" % solo)
	return ok
