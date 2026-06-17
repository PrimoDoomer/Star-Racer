extends SceneTree

## Minimal headless test runner for the Godot client — no external addon needed.
##
## Run from the repo root with:
##   godot --headless --path client --script res://tests/run_tests.gd
##
## Add a test by writing a `test_*` method and calling it from `_run_all()`.
## Use `_check(condition, message)` for each assertion. The process exits 0 when
## every check passes and 1 otherwise, so CI (and `cargo test`-style tooling)
## can gate on it.

var _checks := 0
var _failures := 0

func _initialize() -> void:
	_run_all()
	if _failures == 0:
		print("OK: %d checks passed" % _checks)
	else:
		printerr("FAILED: %d of %d checks failed" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("  x ", message)

func _run_all() -> void:
	test_track_cache_roundtrip()
	test_track_cache_rejects_stale_hash()
	test_track_cache_missing_returns_empty()
	test_locale_en_fr_key_parity()
	test_locale_no_empty_strings()

# --- TrackCache (client/scripts/track_cache.gd) ----------------------------

const _TEST_ID := "__unit_test_track__"

func _cleanup_cache() -> void:
	DirAccess.remove_absolute(TrackCache.DIR.path_join(_TEST_ID + ".json"))

func test_track_cache_roundtrip() -> void:
	_cleanup_cache()
	var track := {"segments": [1, 2, 3], "name": "Test"}
	TrackCache.store(_TEST_ID, "abc123", track)

	_check(TrackCache.cached_hash(_TEST_ID) == "abc123",
		"cached_hash returns the stored hash")
	var loaded = TrackCache.load_track(_TEST_ID, "abc123")
	_check(loaded != null, "load_track returns the def when the hash matches")
	_check(typeof(loaded) == TYPE_DICTIONARY and loaded.get("name") == "Test",
		"loaded def round-trips its contents")
	_cleanup_cache()

func test_track_cache_rejects_stale_hash() -> void:
	_cleanup_cache()
	TrackCache.store(_TEST_ID, "current_hash", {"name": "Test"})
	_check(TrackCache.load_track(_TEST_ID, "old_hash") == null,
		"load_track returns null when the cached hash is stale")
	_cleanup_cache()

func test_track_cache_missing_returns_empty() -> void:
	_cleanup_cache()
	_check(TrackCache.cached_hash(_TEST_ID) == "",
		"cached_hash is empty when nothing is cached")
	_check(TrackCache.load_track(_TEST_ID, "any") == null,
		"load_track is null when nothing is cached")

# --- Locale (client/scripts/locale.gd) -------------------------------------
# Read the STRINGS constant straight off the script class, so the test needs
# neither the Locale autoload nor any TranslationServer side effects.

func _locale_strings() -> Dictionary:
	return load("res://scripts/locale.gd").STRINGS

func test_locale_en_fr_key_parity() -> void:
	var strings := _locale_strings()
	var en: Dictionary = strings["en"]
	var fr: Dictionary = strings["fr"]
	for key in en:
		_check(fr.has(key), "fr is missing translation key: %s" % key)
	for key in fr:
		_check(en.has(key), "en is missing translation key: %s" % key)

func test_locale_no_empty_strings() -> void:
	var strings := _locale_strings()
	for code in strings:
		for key in strings[code]:
			_check(String(strings[code][key]) != "",
				"empty translation for %s/%s" % [code, key])
