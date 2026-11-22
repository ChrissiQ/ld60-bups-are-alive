extends SceneTree
## Run: godot --headless --path . -s tests/sources_test.gd
## The sources: every `@Key` cited in the code, the strings, the tools, the tests and the documentation has its entry in docs/sources.md, and every entry there
## is cited somewhere.

const SOURCES := "res://docs/sources.md"
const DIRS := ["res://scripts", "res://gpu", "res://ui", "res://text", "res://tools", "res://tests", "res://docs"]
const ROOT_FILES := ["res://AGENTS.md", "res://CONTRIBUTING.md", "res://README.md"]
const EXTS := ["gd", "cfg", "md", "txt"]


func _init() -> void:
	var entries := {}
	var heading_rx := RegEx.create_from_string("(?m)^### ([A-Z][A-Za-z]+[0-9]{4}[a-z]?)\\s*$")
	for m in heading_rx.search_all(FileAccess.get_file_as_string(SOURCES)):
		TestUtil.check(not entries.has(m.get_string(1)), "%s is listed once" % m.get_string(1))
		entries[m.get_string(1)] = false
	TestUtil.check(not entries.is_empty(), "docs/sources.md has entries (%d)" % entries.size())

	var cite_rx := RegEx.create_from_string("@([A-Z][A-Za-z]+[0-9]{4}[a-z]?)\\b")
	var missing := []
	var paths: Array = ROOT_FILES.duplicate()
	for dir: String in DIRS:
		_collect(dir, paths)
	for path: String in paths:
		if path == SOURCES:
			continue
		for m in cite_rx.search_all(FileAccess.get_file_as_string(path)):
			var key := m.get_string(1)
			if entries.has(key):
				entries[key] = true
			else:
				missing.append("%s in %s" % [key, path])
	TestUtil.check(missing.is_empty(), "every cited key has an entry in docs/sources.md (%s)" % [missing])
	var uncited := entries.keys().filter(func(k: String) -> bool: return not entries[k])
	TestUtil.check(uncited.is_empty(), "every entry in docs/sources.md is cited (%s)" % [uncited])
	TestUtil.finish(self, "SOURCES TESTS OK", "SOURCES TESTS FAILED:")


func _collect(dir: String, out: Array) -> void:
	out.append_array(TestUtil.files([dir], EXTS))
	for sub in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(sub), out)
