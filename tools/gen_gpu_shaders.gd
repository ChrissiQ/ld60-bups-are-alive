extends SceneTree
## Writes gpu/shaders/<kernel>.glsl for every kernel of GpuKernels.all() (gpu/kernels*.gd). Run it after editing a kernel,
## then import:
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/gen_gpu_shaders.gd
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --import
## tests/gpu_shaders_test.gd fails while the files differ from what this would write.

const DIR := "res://gpu/shaders"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var all := GpuKernels.all()
	var changed := 0
	for kernel_name: String in all:
		var path := DIR.path_join(kernel_name + ".glsl")
		var text: String = all[kernel_name]["source"]
		if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text:
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			printerr("cannot write ", path)
			quit(1)
			return
		f.store_string(text)
		f.close()
		changed += 1
	for f in DirAccess.get_files_at(DIR):  # a shader whose kernel was removed
		if f.get_extension() == "glsl" and not all.has(f.get_basename()):
			printerr("stale shader with no kernel (delete it and its .import): ", f)
	print("%d kernels, %d files written" % [all.size(), changed])
	quit(0)
