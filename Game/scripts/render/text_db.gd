extends RefCounted
class_name TextDB
## 演出層テキストの一元ロード (会話セリフ・イベントフィード文面・名前音節)。
##
## 力学には一切関与しない演出層。シム RNG を消費しない (KI-09)。テキストは
## res://data/ の JSON にまとまっており、**コードを触らず JSON を編集するだけ**で
## セリフ/文面を差し替え・増量できる。
##   - data/dialogue.json : { "conversation": {<状態キー>: [行...]}, "names": {M1,M2,F1,F2} }
##   - data/messages.json : { "events": {<キー>: "テンプレ"}, "labels": {<群>: {<キー>: 文字列}} }
## プレースホルダは GDScript String.format の波括弧形式 ({name} {count} {who} ...)。
## ファイルが無い/壊れていても落ちない (空辞書 + 警告 → 呼び出し側のフォールバック)。

const DIALOGUE_PATH := "res://data/dialogue.json"
const MESSAGES_PATH := "res://data/messages.json"

static var _dialogue: Dictionary = {}
static var _messages: Dictionary = {}
static var _loaded := false

## JSON を 1 つ読み込む。無い/壊れていれば空辞書 + 警告 (クラッシュさせない)。
static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("TextDB: ファイルが無い " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("TextDB: 開けない " + path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("TextDB: JSON 解析失敗 " + path)
		return {}
	return parsed as Dictionary

## 初回アクセス時に 1 度だけロード (名前の決定性のため、セッション中はキャッシュ固定)。
static func ensure_loaded() -> void:
	if _loaded:
		return
	_dialogue = _load_json(DIALOGUE_PATH)
	_messages = _load_json(MESSAGES_PATH)
	_loaded = true

## テスト/ホットリロード用に再読込を強制する。
static func reload() -> void:
	_loaded = false
	ensure_loaded()

# ── 会話セリフ (dialogue.json) ──────────────────────────────
## カテゴリの行配列を返す (無ければ空配列)。
static func chatter_lines(category: String) -> Array:
	ensure_loaded()
	var conv: Variant = _dialogue.get("conversation", {})
	if typeof(conv) != TYPE_DICTIONARY:
		return []
	var arr: Variant = (conv as Dictionary).get(category, [])
	return (arr as Array) if typeof(arr) == TYPE_ARRAY else []

## カテゴリから 1 行を rng で選び、fields で {name}/{other} を埋めて返す。
## 候補が無ければ ""。rng は必ず演出 RNG を渡すこと (シム RNG を消費しない / KI-09)。
static func pick_chatter(category: String, rng: RandomNumberGenerator, fields: Dictionary = {}) -> String:
	var arr := chatter_lines(category)
	if arr.is_empty():
		return ""
	return String(arr[rng.randi() % arr.size()]).format(fields)

# ── 名前音節 (dialogue.json "names") ────────────────────────
## 音節配列 (M1/M2/F1/F2) を返す。無ければ空配列 (呼び出し側がフォールバック)。
static func names(key: String) -> Array:
	ensure_loaded()
	var n: Variant = _dialogue.get("names", {})
	if typeof(n) != TYPE_DICTIONARY:
		return []
	var arr: Variant = (n as Dictionary).get(key, [])
	return (arr as Array) if typeof(arr) == TYPE_ARRAY else []

# ── イベントフィード文面 (messages.json) ────────────────────
## イベントキーのテンプレを fields で埋めて返す。無ければ fallback (+ 警告)。
static func msg(key: String, fields: Dictionary = {}, fallback: String = "") -> String:
	ensure_loaded()
	var events: Variant = _messages.get("events", {})
	if typeof(events) != TYPE_DICTIONARY:
		return fallback
	var tpl: Variant = (events as Dictionary).get(key, null)
	if typeof(tpl) != TYPE_STRING:
		push_warning("TextDB: イベント文面が無い key=" + key)
		return fallback
	return String(tpl).format(fields)

## ラベル群 group の key を返す。無ければ group["_default"]、それも無ければ fallback。
static func label(group: String, key: String, fallback: String = "") -> String:
	ensure_loaded()
	var labels: Variant = _messages.get("labels", {})
	if typeof(labels) != TYPE_DICTIONARY:
		return fallback
	var g: Variant = (labels as Dictionary).get(group, {})
	if typeof(g) != TYPE_DICTIONARY:
		return fallback
	var gd := g as Dictionary
	if gd.has(key):
		return String(gd[key])
	if gd.has("_default"):
		return String(gd["_default"])
	return fallback
