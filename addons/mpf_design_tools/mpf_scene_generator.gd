@tool
extends RefCounted

## MPF design -> GMC scene generator (core logic, no editor UI).
##
## HOW IT WORKS (full rebuild, every time)
##   res://design/**/*.tscn     <- the ONLY source of truth (one design scene per slide)
##        | 1. load + instantiate every design scene in memory (never added to the SceneTree)
##        | 2. validate everything             -> any error: stop, output is NOT touched
##        | 3. split each design scene into 1 slide + N widgets and pack them in memory
##        | 4. delete the output directories   (only if they contain the marker file)
##        v 5. save every packed scene
##   res://slides/_generated/<slide_name>.tscn
##   res://widgets/_generated/<widget_name>.tscn
##
## DESIGN SCENE RULES (v1)
##   * The root node is an MPFSlide. The design FILE name becomes the GMC slide name
##     (res://design/game.tscn -> slide "game").
##   * Every MPFWidget that is a DIRECT child of that root becomes its own widget scene.
##     Its NODE name in snake_case becomes the GMC widget name
##     (PlayerScoreWidget -> "player_score_widget").
##   * Everything else stays in the slide.
##   * Names must be unique across the whole design directory AND must not clash with
##     hand-made scenes in res://slides, res://widgets or res://modes/*/(slides|widgets),
##     because GMC identifies scenes by file name only.
##
## WIDGET POSITIONING
##   GMC's MPFWidget.initialize() overwrites the widget root's position with the
##   widget_player 'x' / 'y' settings (MPF 0.80 default: 0, 0). A position stored on the
##   root would therefore be thrown away. Instead every generated widget looks like:
##       <widget_name>        MPFWidget, position (0,0), size 128x32   <- GMC moves this by x/y
##         _design_layout     Control holding the design position/size/rotation/scale/modulate
##           ...the widget's original children...
##   With the default x: 0 / y: 0 the widget shows up exactly where it was designed.
##   Non-zero widget_player x/y become an offset from the designed position.
##
## ANIMATIONS
##   GMC plays slide animations and widget animations separately (each MPFSceneBase has
##   its own `animation_player`, and widgets can be added/removed at any time), so an
##   animation must stay on the side that owns the nodes it animates:
##   * An AnimationPlayer INSIDE a widget may only animate nodes inside that widget
##     (the widget root included). It is exported with the widget and keeps working:
##     `_design_layout` takes over the root's role, so "." tracks still hit the right node.
##   * An AnimationPlayer in the slide content may only animate slide content.
##   Every track of every animation is checked; a track crossing the slide/widget
##   boundary is an error, because it would silently stop working in the generated scenes.

# --- Configuration ------------------------------------------------------------

## The only source of truth.
const DESIGN_DIR := "res://design"

## Output directories. They MUST be somewhere GMC's media scanner looks
## (addons/mpf-gmc/scripts/media.gd scans res://slides/** and res://widgets/**).
const SLIDE_OUTPUT_DIR := "res://slides/_generated"
const WIDGET_OUTPUT_DIR := "res://widgets/_generated"

## An output directory is only ever deleted if this file exists inside it.
const MARKER_FILE_NAME := ".mpf_generated"

## Inner node that carries a widget's design placement (see WIDGET POSITIONING).
const LAYOUT_NODE_NAME := "_design_layout"

const DISPLAY_SIZE := Vector2(128, 32)

const GENERATED_NOTICE := "THIS FILE IS GENERATED from res://design. DO NOT EDIT MANUALLY - it is deleted and rebuilt on every generation."

const MPF_SLIDE_SCRIPT := "res://addons/mpf-gmc/classes/mpf_slide.gd"
const MPF_WIDGET_SCRIPT := "res://addons/mpf-gmc/classes/mpf_widget.gd"


## One scene to write. Built completely in memory before anything is deleted.
class Output:
	var kind: String          # "slide" or "widget"
	var name: String          # GMC name == output file name without ".tscn"
	var source: String        # human readable origin, for error messages and the marker file
	var output_path: String
	var packed: PackedScene


var errors: PackedStringArray = []
var warnings: PackedStringArray = []

var _name_regex := RegEx.create_from_string("^[a-z0-9_]+$")


# --- Public entry point -------------------------------------------------------

## Runs a full rebuild. Returns true on success. Details are in `errors` / `warnings`
## and are also printed to the Output panel.
func generate_all() -> bool:
	errors.clear()
	warnings.clear()
	_info("Full rebuild: %s -> %s , %s" % [DESIGN_DIR, SLIDE_OUTPUT_DIR, WIDGET_OUTPUT_DIR])

	# ---- Phase A: build + validate in memory. Nothing on disk changes here. ----
	if not _check_gmc_classes():
		return _finish(false, "GMC classes are unavailable. The generated directories were NOT modified.")
	_check_output_config()
	var design_paths := _find_scenes(DESIGN_DIR, true)
	if design_paths.is_empty() and errors.is_empty():
		_error("No design scenes (*.tscn) found in %s." % DESIGN_DIR)

	var outputs: Array[Output] = []
	for path in design_paths:
		outputs.append_array(_build_from_design_scene(path))
	_check_names(outputs)
	for dir_path in [SLIDE_OUTPUT_DIR, WIDGET_OUTPUT_DIR]:
		_check_output_dir_can_be_replaced(dir_path)

	if not errors.is_empty():
		return _finish(false, "Validation failed. The generated directories were NOT modified.")

	# ---- Phase B: destructive. Delete old output, write new output. ----
	for dir_path in [SLIDE_OUTPUT_DIR, WIDGET_OUTPUT_DIR]:
		if not _recreate_output_dir(dir_path, outputs):
			return _finish(false, "Could not recreate %s. Output may be INCOMPLETE - fix the error and run again." % dir_path)
	for output in outputs:
		_save(output)
	if not errors.is_empty():
		return _finish(false, "Some scenes failed to save. Output is INCOMPLETE - fix the error and run again.")

	var slide_count := outputs.filter(func(o: Output): return o.kind == "slide").size()
	return _finish(true, "Generated %d slide(s) and %d widget(s)." % [slide_count, outputs.size() - slide_count])


# --- Building one design scene ------------------------------------------------

func _build_from_design_scene(path: String) -> Array[Output]:
	var result: Array[Output] = []
	var errors_before := errors.size()

	# ResourceLoader.load() returns the PackedScene resource (the saved .tscn), not nodes.
	var packed := ResourceLoader.load(path) as PackedScene
	if packed == null or not packed.can_instantiate():
		_error("%s: could not be loaded as a scene." % path)
		return result

	# instantiate() turns the PackedScene into a real node tree. The tree lives only in
	# memory: it is never added to the SceneTree, so no _ready()/_enter_tree() runs.
	# GEN_EDIT_STATE_INSTANCE instantiates "like the editor does": it keeps the extra
	# bookkeeping that lets pack() store instanced sub-scenes as instances (with only
	# their overridden properties) instead of flattening them.
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)

	if not (root is MPFSlide):
		_error("%s: the root node '%s' must be an MPFSlide, but it is %s." % [path, root.name, _type_name(root)])
		root.free()
		return result

	var slide_name := path.get_file().get_basename()
	if not _name_regex.search(slide_name):
		_error("%s: slide name '%s' (the file name) must be snake_case: a-z, 0-9, _." % [path, slide_name])

	var widgets := _collect_widgets(path, root)
	_check_layering(path, root)
	_check_slide_animation_player(path, root, widgets)
	_check_animation_tracks(path, root, widgets)
	for widget in widgets:
		_check_widget(path, root, widget)

	if errors.size() != errors_before:
		root.free()
		return result

	# "Editable Children" flags are stored on the design root by node PATH, so they
	# must be read before any node is moved.
	var editable_by_widget := {}
	for widget in widgets:
		editable_by_widget[widget] = _editable_instances_under(root, widget)

	# Split: detach widgets. What remains under `root` is exactly the slide content.
	for widget in widgets:
		root.remove_child(widget)

	var slide_output := _pack_slide(path, slide_name, root)
	if slide_output:
		result.append(slide_output)
	root.free()

	for widget in widgets:
		var widget_output := _pack_widget(path, widget, editable_by_widget[widget])
		if widget_output:
			result.append(widget_output)
		widget.free()

	return result


func _collect_widgets(path: String, root: Node) -> Array[Control]:
	var widgets: Array[Control] = []
	for child in root.get_children():
		if child is MPFWidget:
			widgets.append(child)

	for node in _descendants(root):
		var where := "%s: node '%s'" % [path, root.get_path_to(node)]
		if node is MPFSlide:
			_error("%s is an MPFSlide inside another slide. A design scene contains exactly one slide (its root)." % where)
		elif node is MPFWidget and node.get_parent() != root:
			_error("%s is an MPFWidget but not a direct child of the slide root. Nested widgets are not supported." % where)
	return widgets


func _check_widget(path: String, root: Node, widget: Control) -> void:
	var where := "%s: widget '%s'" % [path, widget.name]

	if widget.scene_file_path != "":
		_error("%s is an instance of '%s'. v1 requires widgets to be authored directly in the design scene." % [where, widget.scene_file_path])

	var widget_name := String(widget.name).to_snake_case()
	if not _name_regex.search(widget_name):
		_error("%s: generated widget name '%s' must be snake_case: a-z, 0-9, _. Rename the node." % [where, widget_name])

	var anim_player := _node_property(widget, "animation_player")
	if anim_player and not widget.is_ancestor_of(anim_player):
		_error("%s: its animation_player must be a node inside the widget." % where)
	elif anim_player == null and _descendants(widget).any(func(n: Node): return n is AnimationPlayer):
		_warn("%s contains an AnimationPlayer but its 'animation_player' property is empty, so GMC will not play created/active/removed animations or widget_player 'action: animation' on it." % where)

	if not widget.visible:
		_warn("%s is hidden in the design. It will also be hidden at runtime." % where)

	if widget.anchor_left != 0.0 or widget.anchor_top != 0.0 or widget.anchor_right != 0.0 or widget.anchor_bottom != 0.0:
		_warn("%s uses anchors. The generator assumes absolute (top-left anchored) positions." % where)

	var script: Script = widget.get_script()
	if script and script.resource_path != MPF_WIDGET_SCRIPT:
		_warn("%s uses a custom script. Generated widgets have an extra '%s' node, so reach children with %%UniqueName instead of $Child paths." % [where, LAYOUT_NODE_NAME])


## At runtime GMC puts all widgets in a container that is added AFTER all slide
## content, so widgets always draw above slide nodes, whatever the design order is.
func _check_layering(path: String, root: Node) -> void:
	var first_widget: Node = null
	for child in root.get_children():
		if child is MPFWidget:
			if first_widget == null:
				first_widget = child
		elif first_widget and child is CanvasItem and child.visible:
			_warn("%s: '%s' is above widget '%s' in the design, but at runtime GMC draws every widget above slide content. Move it before the widgets or give it a higher z_index." % [path, child.name, first_widget.name])


func _check_slide_animation_player(path: String, root: Node, widgets: Array[Control]) -> void:
	var anim_player := _node_property(root, "animation_player")
	if anim_player == null:
		return
	for widget in widgets:
		if widget == anim_player or widget.is_ancestor_of(anim_player):
			_error("%s: the slide's animation_player is inside widget '%s', which is exported separately." % [path, widget.name])


## Checks every track of every AnimationPlayer / AnimationTree in the design scene.
## A player and all the nodes it animates must be on the same side of the split:
## all in the slide content, or all inside the same widget.
func _check_animation_tracks(path: String, root: Node, widgets: Array[Control]) -> void:
	for node in _descendants(root):
		var mixer := node as AnimationMixer  # base class of AnimationPlayer and AnimationTree
		if mixer == null:
			continue
		var home := _widget_containing(mixer, widgets)  # null means "slide content"
		var where := "%s: '%s'" % [path, root.get_path_to(mixer)]

		# Track paths are relative to the player's root_node (default "..", its parent).
		var anim_root := mixer.get_node_or_null(mixer.root_node)
		if anim_root == null:
			_warn("%s: root_node '%s' does not point to a node, its tracks cannot be checked." % [where, mixer.root_node])
			continue
		if _widget_containing(anim_root, widgets) != home:
			_error("%s: root_node '%s' points %s. Set root_node to a node on the same side." % [where, mixer.root_node, _side_text(_widget_containing(anim_root, widgets), home)])
			continue

		for library_name in mixer.get_animation_library_list():
			var library := mixer.get_animation_library(library_name)
			for animation_name in library.get_animation_list():
				var animation := library.get_animation(animation_name)
				var label := String(animation_name) if library_name == &"" else "%s/%s" % [library_name, animation_name]
				for track in animation.get_track_count():
					var track_path := animation.track_get_path(track)
					# "Label:position" -> node part "Label"; ".:modulate" -> "."
					var target := anim_root
					if track_path.get_name_count() > 0:
						target = anim_root.get_node_or_null(NodePath(track_path.get_concatenated_names()))
					var track_where := "%s animation '%s' track '%s'" % [where, label, track_path]
					if target == null:
						_warn("%s does not point to an existing node." % track_where)
						continue
					var target_home := _widget_containing(target, widgets)
					if target_home != home:
						_error("%s animates '%s', which is %s. Slides and widgets are exported to separate scenes, so this track would break. Move the track to an AnimationPlayer on the same side." % [track_where, root.get_path_to(target), _side_text(target_home, home)])


## Returns the widget that is `node` or contains it, or null if `node` is slide content.
static func _widget_containing(node: Node, widgets: Array[Control]) -> Control:
	for widget in widgets:
		if widget == node or widget.is_ancestor_of(node):
			return widget
	return null


static func _side_text(target_home: Control, player_home: Control) -> String:
	var target_text := "slide content" if target_home == null else "inside widget '%s'" % target_home.name
	var player_text := "slide content" if player_home == null else "widget '%s'" % player_home.name
	return "%s while the player belongs to %s" % [target_text, player_text]


# --- Packing ------------------------------------------------------------------

func _pack_slide(design_path: String, slide_name: String, root: Node) -> Output:
	# The instantiated root remembers the file it came from; the slide is a new file.
	root.scene_file_path = ""
	_stamp(root, design_path)
	return _pack("slide", slide_name, design_path, SLIDE_OUTPUT_DIR, root)


func _pack_widget(design_path: String, widget: Control, editable_instances: Array[Node]) -> Output:
	var widget_name := String(widget.name).to_snake_case()
	var source := "%s : %s" % [design_path, widget.name]

	# 1. Move the design placement into an inner layout node (see WIDGET POSITIONING).
	#    All children move together, so relative NodePaths inside the widget (for
	#    example AnimationPlayer tracks) keep working: "_design_layout" takes over the
	#    visual role of the old root.
	var layout := Control.new()
	layout.name = LAYOUT_NODE_NAME
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in widget.get_children():
		widget.remove_child(child)
		layout.add_child(child)
	widget.add_child(layout)

	layout.position = widget.position
	layout.size = widget.size
	layout.rotation = widget.rotation
	layout.scale = widget.scale
	layout.pivot_offset = widget.pivot_offset
	layout.modulate = widget.modulate
	layout.clip_contents = widget.clip_contents

	widget.position = Vector2.ZERO
	widget.size = DISPLAY_SIZE
	widget.rotation = 0.0
	widget.scale = Vector2.ONE
	widget.pivot_offset = Vector2.ZERO
	widget.modulate = Color.WHITE
	widget.clip_contents = false

	# GMC sends "widget_<node name>_removed", so the node name should equal the GMC name.
	widget.name = widget_name

	# 2. Ownership. PackedScene.pack() only saves nodes whose `owner` is the packed root.
	#    In the design scene, the owner of these nodes was the design root. Nodes that
	#    belong to an instanced sub-scene are owned by that sub-scene's root: keep those.
	widget.owner = null
	for node in _descendants(widget):
		if node.owner == null or not (node.owner == widget or widget.is_ancestor_of(node.owner)):
			node.owner = widget
	for node in editable_instances:
		widget.set_editable_instance(node, true)

	_stamp(widget, source)
	return _pack("widget", widget_name, source, WIDGET_OUTPUT_DIR, widget)


func _pack(kind: String, gmc_name: String, source: String, out_dir: String, root: Node) -> Output:
	# pack() converts a live node tree into a PackedScene (the data of a .tscn).
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		_error("%s: PackedScene.pack() failed for %s '%s': %s" % [source, kind, gmc_name, error_string(err)])
		return null
	var output := Output.new()
	output.kind = kind
	output.name = gmc_name
	output.source = source
	output.output_path = out_dir.path_join(gmc_name + ".tscn")
	output.packed = packed
	return output


func _stamp(root: Node, source: String) -> void:
	# Metadata is saved in the .tscn and shown at the bottom of the Inspector.
	root.set_meta(&"generated_notice", GENERATED_NOTICE)
	root.set_meta(&"generated_from", source)


# --- Project-wide validation --------------------------------------------------

func _check_names(outputs: Array[Output]) -> void:
	var seen := {}
	for output in outputs:
		var key := output.kind + ":" + output.name
		if seen.has(key):
			_error("Duplicate %s name '%s': from %s and from %s." % [output.kind, output.name, seen[key], output.source])
		else:
			seen[key] = output.source

	var hand_made := {
		"slide": _find_gmc_scenes("slides", SLIDE_OUTPUT_DIR),
		"widget": _find_gmc_scenes("widgets", WIDGET_OUTPUT_DIR),
	}
	for output in outputs:
		var existing: Dictionary = hand_made[output.kind]
		if existing.has(output.name):
			_error("Generated %s '%s' (from %s) has the same name as %s. GMC identifies scenes by file name only, so one would silently replace the other." % [output.kind, output.name, output.source, existing[output.name]])


## If GMC's scripts do not compile, `node is MPFSlide` is silently false for every node.
func _check_gmc_classes() -> bool:
	for script_path in [MPF_SLIDE_SCRIPT, MPF_WIDGET_SCRIPT]:
		var script := load(script_path) as Script
		if script == null or not script.can_instantiate():
			_error("'%s' is missing or does not compile. Is the mpf-gmc addon installed and enabled?" % script_path)
			return false
	return true


## Mirrors GMC's media.gd scan: res://<type>/** and res://modes/*/<type>/**.
## Returns { scene_name: path } for scenes that are NOT generated by this tool.
func _find_gmc_scenes(type_dir: String, generated_dir: String) -> Dictionary:
	var roots: PackedStringArray = ["res://" + type_dir]
	var modes := DirAccess.open("res://modes")
	if modes:
		var mode_names := modes.get_directories()
		mode_names.sort()
		for mode_name in mode_names:
			roots.append("res://modes/%s/%s" % [mode_name, type_dir])

	var found := {}
	for root_dir in roots:
		for path in _find_scenes(root_dir, false):
			if not path.begins_with(generated_dir + "/"):
				found[path.get_file().get_basename()] = path
	return found


func _check_output_config() -> void:
	# GMC scans res://<content_root>/slides instead of res://slides when this is set.
	var cfg := ConfigFile.new()
	if cfg.load("res://gmc.cfg") != OK:
		return
	var content_root := str(cfg.get_value("gmc", "content_root", ""))
	if content_root != "" and not SLIDE_OUTPUT_DIR.begins_with("res://%s/" % content_root):
		_error("gmc.cfg sets [gmc] content_root = '%s', so GMC will not find scenes in %s. Update SLIDE_OUTPUT_DIR and WIDGET_OUTPUT_DIR." % [content_root, SLIDE_OUTPUT_DIR])


# --- Output directory handling (the only destructive code) ---------------------

func _check_output_dir_can_be_replaced(dir_path: String) -> void:
	if not _is_safe_output_dir(dir_path):
		_error("Output directory '%s' failed the safety check: it must be under res://, be named '_generated', and must not overlap %s or res://addons." % [dir_path, DESIGN_DIR])
	elif DirAccess.dir_exists_absolute(dir_path) and not FileAccess.file_exists(dir_path.path_join(MARKER_FILE_NAME)):
		_error("Refusing to delete '%s': it has no %s marker file, so this generator did not create it. Move anything you need out of it, delete the folder yourself, then run again." % [dir_path, MARKER_FILE_NAME])


func _is_safe_output_dir(dir_path: String) -> bool:
	var p := dir_path.simplify_path()
	return p.begins_with("res://") \
		and p.get_file() == "_generated" \
		and p.trim_prefix("res://").split("/").size() >= 2 \
		and not p.begins_with(DESIGN_DIR) \
		and not DESIGN_DIR.begins_with(p) \
		and not p.begins_with("res://addons")


func _recreate_output_dir(dir_path: String, outputs: Array[Output]) -> bool:
	# Re-check right before deleting (defence in depth).
	var errors_before := errors.size()
	_check_output_dir_can_be_replaced(dir_path)
	if errors.size() != errors_before:
		return false

	if DirAccess.dir_exists_absolute(dir_path):
		var err := _delete_recursive(dir_path)
		if err != OK:
			_error("Could not delete '%s': %s" % [dir_path, error_string(err)])
			return false

	var mk_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mk_err != OK:
		_error("Could not create '%s': %s" % [dir_path, error_string(mk_err)])
		return false

	# The marker is written immediately so a failed save below never blocks the next run.
	var marker := FileAccess.open(dir_path.path_join(MARKER_FILE_NAME), FileAccess.WRITE)
	if marker == null:
		_error("Could not write marker in '%s': %s" % [dir_path, error_string(FileAccess.get_open_error())])
		return false
	marker.store_line(GENERATED_NOTICE)
	marker.store_line("This directory is owned by addons/mpf_design_tools and is deleted on every run.")
	marker.store_line("")
	for output in outputs:
		if output.output_path.get_base_dir() == dir_path:
			marker.store_line("%s  <-  %s" % [output.output_path.get_file(), output.source])
	marker.close()
	return true


func _delete_recursive(dir_path: String) -> Error:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true  # also delete the marker and any other dot-files
	for file_name in dir.get_files():
		var err := dir.remove(file_name)
		if err != OK:
			return err
	for sub_dir in dir.get_directories():
		var err := _delete_recursive(dir_path.path_join(sub_dir))
		if err != OK:
			return err
	return DirAccess.remove_absolute(dir_path)


func _save(output: Output) -> void:
	# If an old scene with this path is still in Godot's resource cache (for example it
	# is open in an editor tab), let the new PackedScene take over that path.
	output.packed.take_over_path(output.output_path)
	# ResourceSaver.save() serializes the resource; the .tscn extension selects the text format.
	var err := ResourceSaver.save(output.packed, output.output_path)
	if err != OK:
		_error("%s: could not save %s: %s" % [output.source, output.output_path, error_string(err)])
		return
	# Godot gives new files a random UID. A UID derived from the path keeps the output
	# stable between runs, so references to generated scenes survive a rebuild.
	err = ResourceSaver.set_uid(output.output_path, _stable_uid(output.output_path))
	if err != OK:
		_warn("%s: could not set a stable UID: %s" % [output.output_path, error_string(err)])


# --- Helpers ------------------------------------------------------------------

## Returns every *.tscn below dir_path, sorted, so the output is deterministic.
func _find_scenes(dir_path: String, required: bool) -> PackedStringArray:
	var result: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		if required:
			_error("Cannot open directory '%s': %s" % [dir_path, error_string(DirAccess.get_open_error())])
		return result
	var files := dir.get_files()
	files.sort()
	for file_name in files:
		if file_name.get_extension() == "tscn":
			result.append(dir_path.path_join(file_name))
	var sub_dirs := dir.get_directories()
	sub_dirs.sort()
	for sub_dir in sub_dirs:
		result.append_array(_find_scenes(dir_path.path_join(sub_dir), required))
	return result


static func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in node.get_children():
		result.append(child)
		result.append_array(_descendants(child))
	return result


static func _editable_instances_under(root: Node, branch: Node) -> Array[Node]:
	var result: Array[Node] = []
	for node in _descendants(branch):
		if root.is_editable_instance(node):
			result.append(node)
	return result


## Reads an exported Node property such as MPFSceneBase.animation_player.
static func _node_property(holder: Node, property: String) -> Node:
	var value = holder.get(property)
	if value is Node:
		return value
	if value is NodePath and not value.is_empty():
		return holder.get_node_or_null(value)
	return null


static func _type_name(node: Node) -> String:
	var script: Script = node.get_script()
	if script and script.get_global_name() != &"":
		return String(script.get_global_name())
	return node.get_class()


static func _stable_uid(path: String) -> int:
	# ResourceUIDs are non-negative 63-bit integers; combine two 32-bit string hashes.
	var high := ("mpf_design_tools/a/" + path).hash()
	var low := ("mpf_design_tools/b/" + path).hash()
	return ((high << 31) ^ low) & 0x7FFFFFFFFFFFFFFF


func _finish(success: bool, message: String) -> bool:
	if success:
		_info(message)
	else:
		_error(message)
	_info("%d error(s), %d warning(s)." % [errors.size(), warnings.size()])
	return success


func _info(message: String) -> void:
	print("[MPF Generator] ", message)


func _warn(message: String) -> void:
	warnings.append(message)
	push_warning("[MPF Generator] " + message)
	print("[MPF Generator] WARNING: ", message)


func _error(message: String) -> void:
	errors.append(message)
	push_error("[MPF Generator] " + message)
	print("[MPF Generator] ERROR: ", message)
