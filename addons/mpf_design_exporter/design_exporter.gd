@tool
class_name MPFDesignExporter
extends RefCounted

## Compiles the authoring scenes in [code]res://design/[/code] into MPF/GMC-ready
## scenes in [code]res://generated/[/code].
##
## The exporter is a tiny compiler: [code]generated = f(design)[/code].
## Every run is a FULL REBUILD - the output directory is deleted and recreated
## from scratch, so a renamed or deleted design node can never leave a stale
## artifact behind.
##
## This file contains no editor UI. It only uses APIs that also work outside the
## editor (DirAccess / FileAccess / load / PackedScene / ResourceSaver), so it can
## be driven from the "MPF Tools" menu, from another @tool script, or headless
## from CI. The EditorPlugin in plugin.gd is a thin wrapper around it.
##
## Authoring rules (validated, see ExportResult):
## [codeblock]
## design/game.tscn              -> generated/slides/game.tscn
##   root node       : MPFSlide  (the slide itself)
##   MPFWidget child : ScoreWidget -> generated/widgets/score_widget.tscn
##   everything else : stays in the generated slide
## [/codeblock]

# --- Configuration -----------------------------------------------------------
# Kept as constants on purpose: the build must be reproducible from the repo
# alone, with no hidden editor settings involved.

## The ONLY source of truth. Scanned recursively for .tscn files.
const DESIGN_ROOT := "res://design"
## Build output. Fully deleted and regenerated on every export.
const OUTPUT_ROOT := "res://generated"
## Sub-directories inside OUTPUT_ROOT (GMC looks up scenes by file name, these
## two names mirror GMC's own "slides" / "widgets" content folders).
const SLIDES_SUBDIR := "slides"
const WIDGETS_SUBDIR := "widgets"
## Safety marker. The exporter refuses to recursively delete OUTPUT_ROOT unless
## this file exists inside it, so a mistyped path can never nuke real content.
const MARKER_FILE := ".mpf_generated"
## Human-readable build report written next to the generated scenes.
const REPORT_FILE := "BUILD_REPORT.md"
## The DMD is a fixed 128x32 canvas - no anchors, no scaling, absolute pixels.
const DISPLAY_SIZE := Vector2i(128, 32)
## Slide/widget names must be usable as MPF config keys and as file names.
const NAME_PATTERN := "^[a-z][a-z0-9_]*$"

## Metadata written onto every generated root node. Purely informational, but it
## makes a generated scene identifiable in the Inspector and by other tooling.
const META_GENERATED := "mpf_generated"
const META_SOURCE := "mpf_generated_from"
## Optional metadata the author can set on a design node to override the derived
## MPF name (e.g. name the node "PlayerScoreWidget" but export it as "score").
const META_NAME_OVERRIDE := "mpf_name"

const NOTICE := """THIS DIRECTORY IS GENERATED - DO NOT EDIT MANUALLY.

Everything in here is produced by addons/mpf_design_exporter from the scenes in
res://design/. It is deleted and rebuilt in full on every export, so any manual
change will be lost without warning. Edit the design scenes instead.
"""


## Result of one export run: what was produced, and what went wrong.
class ExportResult extends RefCounted:
	var slides: Array[String] = []           # generated slide paths
	var widgets: Array[String] = []          # generated widget paths
	var placements: Array[Dictionary] = []   # {slide, widget, x, y, order}
	var errors: PackedStringArray = []
	var warnings: PackedStringArray = []
	## When true, messages are only collected, not pushed to the editor log.
	## Used for the internal validation pass so nothing is reported twice.
	var quiet := false

	func error(msg: String) -> void:
		errors.append(msg)
		if not quiet:
			push_error("[MPF Export] %s" % msg)

	func warn(msg: String) -> void:
		warnings.append(msg)
		if not quiet:
			push_warning("[MPF Export] %s" % msg)

	## Pushes every collected message to the editor log at once. Used when a
	## quiet validation pass turns out to be what the caller gets back.
	func flush() -> void:
		quiet = false
		for message in warnings:
			push_warning("[MPF Export] %s" % message)
		for message in errors:
			push_error("[MPF Export] %s" % message)

	func is_ok() -> bool:
		return errors.is_empty()

	func summary() -> String:
		return "%d slide(s), %d widget(s), %d error(s), %d warning(s)" % [
			slides.size(), widgets.size(), errors.size(), warnings.size()
		]


## When true, the run validates everything (scanning, naming, packing) but does
## not touch the filesystem. Set through export_all(true).
var _dry_run := false


## Full global rebuild. This is the only public entry point.
##
## The build runs in two passes, like a compiler that refuses to emit an object
## file for a program that does not compile:
##   1. a dry pass that loads, validates and packs everything but writes nothing;
##   2. if - and only if - that pass is clean, the real pass that deletes
##      res://generated/ and writes it again from scratch.
## A broken design therefore never produces half-built output, and never
## destroys the previous (working) build.
##
## With `dry_run` only the first pass runs: that is the "Validate Design" action.
func export_all(dry_run: bool = false) -> ExportResult:
	# The internal validation pass of a full build stays quiet: if it succeeds,
	# the real pass reports the same warnings again, and if it fails its result
	# (with every message) is what the caller gets back.
	var check := _run_pass(true, not dry_run)
	if dry_run or not check.is_ok():
		if check.quiet:
			check.flush()
		return check
	return _run_pass(false, false)


func _run_pass(dry_run: bool, quiet: bool) -> ExportResult:
	_dry_run = dry_run
	var result := ExportResult.new()
	result.quiet = quiet

	if not DirAccess.dir_exists_absolute(DESIGN_ROOT):
		result.error("Design directory '%s' does not exist - nothing to export." % DESIGN_ROOT)
		return result

	# 1. Wipe the previous build (guarded by the marker file).
	if not _reset_output_dir(result):
		return result

	# 2. Collect every design scene. Sorted so the build order - and therefore
	#    the report - is deterministic regardless of filesystem ordering.
	var design_scenes := _find_design_scenes(DESIGN_ROOT)
	design_scenes.sort()
	if design_scenes.is_empty():
		result.warn("No .tscn files found under '%s'." % DESIGN_ROOT)

	# 3. Compile each design scene. The dictionaries map a generated MPF name to
	#    the design scene that produced it, which is how duplicates are caught.
	var slide_names := {}
	var widget_names := {}
	for design_path in design_scenes:
		_export_design_scene(design_path, result, slide_names, widget_names)

	# 4. Warn about names that collide with hand-authored GMC content, because
	#    GMC's media traversal keys scenes by file name alone: a duplicate name
	#    means one of the two scenes silently wins.
	_check_legacy_collisions(slide_names, widget_names, result)

	# 5. Write the human-readable report (widget placements + config snippets).
	_write_report(result)
	return result


# --- Output directory handling ----------------------------------------------

## Deletes OUTPUT_ROOT (only if it carries the marker file) and recreates the
## empty skeleton. Returns false if the export must be aborted.
func _reset_output_dir(result: ExportResult) -> bool:
	var marker_path := OUTPUT_ROOT.path_join(MARKER_FILE)
	if _dry_run:
		# Validation must not delete or create anything, but it should still
		# report the condition that would abort a real export.
		if DirAccess.dir_exists_absolute(OUTPUT_ROOT) and not FileAccess.file_exists(marker_path):
			result.error("'%s' exists but has no '%s' marker; an export would refuse to delete it." % [
				OUTPUT_ROOT, MARKER_FILE])
		return true
	if DirAccess.dir_exists_absolute(OUTPUT_ROOT):
		# The destructive step is gated on the marker: if the constant above ever
		# points at a real content folder, that folder will not have the marker
		# and the export aborts instead of deleting the user's work.
		if not FileAccess.file_exists(marker_path):
			result.error(
				"Refusing to delete '%s': safety marker '%s' is missing. " % [OUTPUT_ROOT, MARKER_FILE]
				+ "If this really is the generated output directory, create the marker file "
				+ "(or delete the directory yourself) and export again."
			)
			return false
		var err := _remove_dir_recursive(OUTPUT_ROOT)
		if err != OK:
			result.error("Could not delete '%s': %s" % [OUTPUT_ROOT, error_string(err)])
			return false

	# Recreate the skeleton. make_dir_recursive_absolute() creates every missing
	# level, so this also creates OUTPUT_ROOT itself.
	for sub in [SLIDES_SUBDIR, WIDGETS_SUBDIR]:
		var err := DirAccess.make_dir_recursive_absolute(OUTPUT_ROOT.path_join(sub))
		if err != OK:
			result.error("Could not create '%s': %s" % [OUTPUT_ROOT.path_join(sub), error_string(err)])
			return false

	# The marker doubles as the "do not edit" notice.
	_write_text_file(OUTPUT_ROOT.path_join(MARKER_FILE), NOTICE, result)
	_write_text_file(OUTPUT_ROOT.path_join("README.md"), "# Generated MPF content\n\n" + NOTICE, result)
	return true


## Depth-first recursive delete. DirAccess.remove_absolute() only removes empty
## directories, so children have to go first.
func _remove_dir_recursive(path: String) -> Error:
	var dir := DirAccess.open(path)
	if dir == null:
		return DirAccess.get_open_error()
	# include_hidden is required or the .mpf_generated marker would survive and
	# leave the directory non-empty.
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		var err := _remove_dir_recursive(child) if dir.current_is_dir() else DirAccess.remove_absolute(child)
		if err != OK:
			dir.list_dir_end()
			return err
		entry = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path)


## Recursively collects every .tscn below `path` that is a design scene.
## Files and directories whose name starts with "_" are ignored, which is how
## shared building blocks are kept out of the build:
## [code]design/_parts/icon.tscn[/code] can be instanced by design scenes without
## being exported as a slide or widget of its own.
func _find_design_scenes(path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return found
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if entry.begins_with("_"):
			pass  # shared building block, not a design scene
		elif dir.current_is_dir():
			found.append_array(_find_design_scenes(child))
		elif entry.ends_with(".tscn"):
			found.append(child)
		entry = dir.get_next()
	dir.list_dir_end()
	return found


# --- Design scene compilation ------------------------------------------------

func _export_design_scene(design_path: String, result: ExportResult,
		slide_names: Dictionary, widget_names: Dictionary) -> void:
	var packed := ResourceLoader.load(design_path, "PackedScene") as PackedScene
	if packed == null:
		result.error("'%s' could not be loaded as a PackedScene." % design_path)
		return

	# GEN_EDIT_STATE_INSTANCE keeps the editor-side state of the scene (nested
	# scene instances stay instances instead of being flattened, and their
	# property overrides are preserved), which is what we need before re-packing.
	# It is an editor-only feature; instantiate() returns null in a plain
	# (non-tool) build, so fall back to a runtime instantiation there.
	var root: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if root == null:
		root = packed.instantiate()
	if root == null:
		result.error("'%s' could not be instantiated." % design_path)
		return

	# free() at every exit path: these nodes are never added to the SceneTree,
	# so nothing else will clean them up.
	if root is MPFWidget:
		# A design scene may also hold a single stand-alone widget (a widget that
		# is not owned by one particular slide).
		var name := _mpf_name_for(root, design_path.get_file().get_basename())
		if _validate_name(name, "widget", design_path, widget_names, result):
			widget_names[name] = design_path
			_export_widget(root, name, design_path, result)
		root.free()
		return

	if not (root is MPFSlide):
		result.error(
			"'%s': the root node '%s' (%s) is not an MPFSlide. " % [design_path, root.name, root.get_class()]
			+ "A design scene must have an MPFSlide root (or a single MPFWidget root). "
			+ "Prefix the file or its folder with '_' to keep it out of the build."
		)
		root.free()
		return

	var slide_name := _mpf_name_for(root, design_path.get_file().get_basename())
	if not _validate_name(slide_name, "slide", design_path, slide_names, result):
		root.free()
		return
	slide_names[slide_name] = design_path

	_check_canvas(root, design_path, result)

	# Collect the widgets while the tree is still intact, so their position on
	# the 128x32 canvas can be measured relative to the slide root.
	var widgets: Array[Node] = []
	_collect_widgets(root, widgets, design_path, result)
	_check_animation_players(root, widgets, design_path, result)

	for order in widgets.size():
		var widget: Node = widgets[order]
		var widget_name := _mpf_name_for(widget, String(widget.name).to_snake_case())
		if not _validate_name(widget_name, "widget", design_path, widget_names, result):
			continue
		widget_names[widget_name] = design_path

		var offset := _offset_in_slide(widget, root, design_path, result)
		result.placements.append({
			"slide": slide_name,
			"widget": widget_name,
			"x": int(round(offset.x)),
			"y": int(round(offset.y)),
			"order": order,
		})
		if offset.x < 0 or offset.y < 0 or offset.x >= DISPLAY_SIZE.x or offset.y >= DISPLAY_SIZE.y:
			result.warn("'%s': widget '%s' sits at %s, outside the %dx%d canvas." % [
				design_path, widget.name, offset, DISPLAY_SIZE.x, DISPLAY_SIZE.y])

		# A PackedScene only stores nodes whose `owner` is the scene root, so the
		# widget's own subtree has to be re-owned from the design root onto the
		# widget. The list is built BEFORE detaching, while the ownership
		# information of the design scene is still intact.
		var authored := _collect_authored(widget, root)

		# Detach the widget from the design tree. This is what makes the
		# generated slide "widget-free": MPF adds the widgets back at runtime
		# through the widget_player, into the slide's own _widgets container.
		widget.get_parent().remove_child(widget)
		widget.owner = null
		for node in authored:
			node.owner = widget
		# The slide-relative position is NOT baked into the widget scene: at
		# runtime MPFWidget.initialize() overwrites position with the
		# widget_player's x/y settings (which default to 0), so anything stored
		# here would be thrown away. The design position is reported instead.
		widget.position = Vector2.ZERO
		_export_widget(widget, widget_name, design_path, result)
		widget.free()

	_save_scene(root, _slide_path(slide_name), design_path, result)
	result.slides.append(_slide_path(slide_name))
	root.free()


## MPFSceneBase has an exported `animation_player` reference that GMC plays for
## the created/active/inactive/removed animations. Godot stores such a reference
## as a NodePath inside the saved scene, so it only survives packing when the
## target sits in the same scene. A slide pointing at an AnimationPlayer inside
## a widget (or the other way round) would silently lose its animations, so it
## is rejected here instead.
func _check_animation_players(slide_root: Node, widgets: Array[Node],
		design_path: String, result: ExportResult) -> void:
	var slide_player := _animation_player_of(slide_root)
	for widget in widgets:
		if slide_player != null and widget.is_ancestor_of(slide_player):
			result.error(
				"'%s': the slide's animation_player ('%s') is inside widget '%s'. " % [
					design_path, slide_player.name, widget.name]
				+ "Move it out of the widget: the two become separate scenes."
			)
		var widget_player := _animation_player_of(widget)
		if widget_player != null and not widget.is_ancestor_of(widget_player):
			result.error(
				"'%s': widget '%s' points at an animation_player ('%s') outside itself. " % [
					design_path, widget.name, widget_player.name]
				+ "Each widget must contain its own AnimationPlayer."
			)


## The AnimationPlayer an MPFSlide/MPFWidget node points at, or null.
##
## get() rather than direct property access, because the GMC classes are not
## @tool scripts: inside the editor their nodes only carry the values stored in
## the scene file, and an exported node reference is stored as a NodePath that
## has to be resolved by hand. In a running game the same property is already a
## Node, so both cases are handled.
func _animation_player_of(node: Node) -> AnimationPlayer:
	var value = node.get("animation_player")
	if value is NodePath:
		return null if value.is_empty() else node.get_node_or_null(value) as AnimationPlayer
	return value as AnimationPlayer


## Depth-first collection of the widgets belonging to `slide_root`, in tree
## order (which is also the design-time draw order, back to front).
func _collect_widgets(node: Node, acc: Array[Node],
		design_path: String, result: ExportResult) -> void:
	for child in node.get_children():
		if child is MPFWidget:
			# Nested widgets cannot be expressed in MPF: a widget_player entry
			# always targets a slide, never another widget.
			var nested := _find_nested_widget(child)
			if nested != null:
				result.error("'%s': widget '%s' contains another widget ('%s'). Widgets cannot be nested." % [
					design_path, child.name, nested.name])
				continue
			if not child.scene_file_path.is_empty():
				result.warn(
					"'%s': widget '%s' is an instance of '%s'. " % [design_path, child.name, child.scene_file_path]
					+ "It will be flattened into the generated widget, which creates a second source of truth - "
					+ "author the widget inline in the design scene instead."
				)
			acc.append(child)
		else:
			_collect_widgets(child, acc, design_path, result)


func _find_nested_widget(node: Node) -> Node:
	for child in node.get_children():
		if child is MPFWidget:
			return child
		var deeper := _find_nested_widget(child)
		if deeper != null:
			return deeper
	return null


## Position of `widget` relative to `slide_root`, in pixels.
## The display is a fixed 128x32 canvas with no scaling, so summing the parent
## chain's positions is exact - unless someone rotated or scaled a parent, which
## is reported as a warning.
func _offset_in_slide(widget: Node, slide_root: Node, design_path: String, result: ExportResult) -> Vector2:
	var offset := Vector2.ZERO
	var node: Node = widget
	while node != null and node != slide_root:
		if node is Control:
			offset += node.position
			if not node.scale.is_equal_approx(Vector2.ONE) or not is_zero_approx(node.rotation):
				result.warn("'%s': '%s' is rotated or scaled; the reported widget position is approximate." % [
					design_path, node.name])
		elif node is Node2D:
			offset += node.position
		node = node.get_parent()
	return offset


## Every node of `subtree` that was authored directly in the design scene, i.e.
## owned by `design_root`. Nodes belonging to a nested scene instance are owned
## by that instance's own root instead and are deliberately left out, so the
## instance stays an instance in the generated scene rather than being inlined.
func _collect_authored(subtree: Node, design_root: Node) -> Array[Node]:
	var authored: Array[Node] = []
	for child in subtree.get_children():
		if child.owner == design_root:
			authored.append(child)
			authored.append_array(_collect_authored(child, design_root))
	return authored


## Packs `node` as the root of its own scene and writes it to `out_path`.
## `node` must already have correct ownership: no owner on the root itself, and
## every node that should be saved owned by it.
func _save_scene(node: Node, out_path: String, design_path: String, result: ExportResult) -> void:
	node.set_meta(META_GENERATED, true)
	node.set_meta(META_SOURCE, design_path)

	var packed := PackedScene.new()
	var err := packed.pack(node)
	if err != OK:
		result.error("Could not pack '%s' from '%s': %s" % [out_path, design_path, error_string(err)])
		return
	if _dry_run:
		return
	# FLAG_BUNDLE_RESOURCES is deliberately NOT used: external resources (fonts,
	# textures, scripts) must stay external references, exactly as in the design
	# scene, so the generated scene is small and shares the same assets.
	err = ResourceSaver.save(packed, out_path)
	if err != OK:
		result.error("Could not save '%s': %s" % [out_path, error_string(err)])
		return
	_strip_uids(out_path)


## Removes every `uid="uid://..."` attribute from a saved scene file.
##
## Two reasons, both about determinism:
## * ResourceSaver assigns a fresh random UID to every newly saved scene, so the
##   generated file would differ on every build.
## * The UIDs of the referenced scripts and resources come from each machine's
##   local .uid sidecar files. Keeping them would make the output depend on the
##   local editor state, and a mismatching UID only produces a warning anyway.
##
## Godot resolves an ext_resource without a UID by its path, which is exactly
## what is wanted here: the generated scenes are plain path references into the
## project, and GMC looks them up by file name.
func _strip_uids(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var regex := RegEx.new()
	regex.compile(r'(\[(?:gd_scene|ext_resource)[^\]]*?) uid="uid://[^"]*"')
	var stripped := regex.sub(text, "$1", true)
	if stripped == text:
		return
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(stripped)
	file.close()


func _export_widget(widget: Node, widget_name: String, design_path: String, result: ExportResult) -> void:
	var out_path := _widget_path(widget_name)
	_save_scene(widget, out_path, design_path, result)
	result.widgets.append(out_path)


func _slide_path(slide_name: String) -> String:
	return OUTPUT_ROOT.path_join(SLIDES_SUBDIR).path_join("%s.tscn" % slide_name)


func _widget_path(widget_name: String) -> String:
	return OUTPUT_ROOT.path_join(WIDGETS_SUBDIR).path_join("%s.tscn" % widget_name)


# --- Naming and validation ---------------------------------------------------

## The MPF name of a node: the `mpf_name` metadata if the author set one,
## otherwise the snake_cased fallback (node name for widgets, file name for
## slides). MPF references scenes by these names in slide_player/widget_player.
func _mpf_name_for(node: Node, fallback: String) -> String:
	if node.has_meta(META_NAME_OVERRIDE):
		return String(node.get_meta(META_NAME_OVERRIDE)).strip_edges()
	return fallback.to_snake_case()


func _validate_name(name: String, kind: String, design_path: String,
		seen: Dictionary, result: ExportResult) -> bool:
	var regex := RegEx.new()
	regex.compile(NAME_PATTERN)
	if regex.search(name) == null:
		result.error("'%s': invalid %s name '%s' - expected lower_snake_case (%s)." % [
			design_path, kind, name, NAME_PATTERN])
		return false
	if seen.has(name):
		result.error("'%s': duplicate %s name '%s', already generated from '%s'. " % [
			design_path, kind, name, seen[name]]
			+ "MPF identifies scenes by file name, so the names must be unique across all design scenes.")
		return false
	return true


## The design is authored for a fixed 128x32 display. Anchors/scaling are not
## supported by the exporter, so flag anything that suggests a different setup.
func _check_canvas(root: Node, design_path: String, result: ExportResult) -> void:
	if root is Control:
		var control := root as Control
		var size := control.size
		if int(size.x) != DISPLAY_SIZE.x or int(size.y) != DISPLAY_SIZE.y:
			result.warn("'%s': slide root size is %s, expected %dx%d." % [
				design_path, size, DISPLAY_SIZE.x, DISPLAY_SIZE.y])
		if control.anchor_right != 0.0 or control.anchor_bottom != 0.0:
			result.warn("'%s': slide root uses anchors. The DMD is a fixed %dx%d canvas; use absolute offsets." % [
				design_path, DISPLAY_SIZE.x, DISPLAY_SIZE.y])


## GMC's media traversal keys every scene by its file name across res://slides,
## res://widgets and res://modes/*/. A generated name that already exists there
## would shadow (or be shadowed by) the hand-authored scene.
func _check_legacy_collisions(slide_names: Dictionary, widget_names: Dictionary, result: ExportResult) -> void:
	for pair in [["slides", slide_names], ["widgets", widget_names]]:
		var kind: String = pair[0]
		var names: Dictionary = pair[1]
		var existing := {}
		_index_scene_names("res://%s" % kind, existing)
		var modes := DirAccess.open("res://modes")
		if modes != null:
			modes.list_dir_begin()
			var mode := modes.get_next()
			while mode != "":
				if modes.current_is_dir():
					_index_scene_names("res://modes/%s/%s" % [mode, kind], existing)
				mode = modes.get_next()
			modes.list_dir_end()
		for name in names:
			if existing.has(name):
				result.warn("Generated %s '%s' has the same name as the hand-authored '%s'. GMC will only see one of them." % [
					kind.trim_suffix("s"), name, existing[name]])


func _index_scene_names(path: String, acc: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_index_scene_names(child, acc)
		elif entry.ends_with(".tscn"):
			acc[entry.get_basename()] = child
		entry = dir.get_next()
	dir.list_dir_end()


# --- Reporting ---------------------------------------------------------------

## Writes the build report. It carries the one piece of information that cannot
## live in the generated scenes: where each widget sat on the design canvas.
## MPFWidget.initialize() takes its position from the widget_player's x/y
## settings (MPF defaults both to 0), so those values belong in the MPF config.
func _write_report(result: ExportResult) -> void:
	var lines := PackedStringArray()
	lines.append("# MPF design build report")
	lines.append("")
	lines.append(NOTICE)
	lines.append("Generated %d slide(s) and %d widget(s) from `%s`." % [
		result.slides.size(), result.widgets.size(), DESIGN_ROOT])
	lines.append("")
	lines.append("## Widget placement")
	lines.append("")
	lines.append("A widget's position on the slide is **not** stored in the widget scene:")
	lines.append("`MPFWidget.initialize()` overwrites the root position with the")
	lines.append("`widget_player` `x:`/`y:` settings (MPF defaults both to `0`).")
	lines.append("Copy the values below into your MPF config to reproduce the design layout.")
	lines.append("Widgets are stacked by `priority` (higher = in front); the suggested")
	lines.append("values follow the top-to-bottom order of the design scene.")
	lines.append("")

	var by_slide := {}
	for placement in result.placements:
		if not by_slide.has(placement["slide"]):
			by_slide[placement["slide"]] = []
		by_slide[placement["slide"]].append(placement)

	var slide_keys := by_slide.keys()
	slide_keys.sort()
	for slide_name in slide_keys:
		lines.append("### %s" % slide_name)
		lines.append("")
		lines.append("```yaml")
		lines.append("widget_player:")
		lines.append("  some_event:")
		for placement in by_slide[slide_name]:
			lines.append("    %s:" % placement["widget"])
			lines.append("      slide: %s" % slide_name)
			lines.append("      x: %d" % placement["x"])
			lines.append("      y: %d" % placement["y"])
			lines.append("      priority: %d" % ((placement["order"] + 1) * 10))
		lines.append("```")
		lines.append("")

	if not result.warnings.is_empty():
		lines.append("## Warnings")
		lines.append("")
		for warning in result.warnings:
			lines.append("- %s" % warning)
		lines.append("")
	if not result.errors.is_empty():
		lines.append("## Errors")
		lines.append("")
		for err in result.errors:
			lines.append("- %s" % err)
		lines.append("")

	_write_text_file(OUTPUT_ROOT.path_join(REPORT_FILE), "\n".join(lines), result)


func _write_text_file(path: String, text: String, result: ExportResult) -> void:
	if _dry_run:
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		result.error("Could not write '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(text)
	file.close()
