@tool
extends EditorPlugin

## Editor UI for the design exporter.
##
## This file deliberately contains no export logic at all - it only wires two
## menu entries to MPFDesignExporter and reports the result. Everything that
## actually builds scenes lives in design_exporter.gd, so the build can also be
## run headless (see addons/mpf_design_exporter/README.md).
##
## The menu appears under the editor's [b]Project > Tools > MPF Tools[/b] menu:
## [codeblock]
## MPF Tools
## |-- Generate All MPF Scenes   (full rebuild of res://generated/)
## +-- Validate Design           (same checks, writes nothing)
## [/codeblock]

const DesignExporter := preload("design_exporter.gd")

const MENU_TITLE := "MPF Tools"
const ID_GENERATE := 0
const ID_VALIDATE := 1

var _menu: PopupMenu


func _enter_tree() -> void:
	# A PopupMenu handed to add_tool_submenu_item() becomes a submenu of the
	# editor's Project > Tools menu. It is not owned by the editor, so we have to
	# free it again in _exit_tree().
	_menu = PopupMenu.new()
	_menu.add_item("Generate All MPF Scenes", ID_GENERATE)
	_menu.add_item("Validate Design", ID_VALIDATE)
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_tool_submenu_item(MENU_TITLE, _menu)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_TITLE)
	if is_instance_valid(_menu):
		_menu.queue_free()
	_menu = null


func _on_menu_id_pressed(id: int) -> void:
	match id:
		ID_GENERATE:
			_run(false)
		ID_VALIDATE:
			_run(true)


func _run(dry_run: bool) -> void:
	var exporter := DesignExporter.new()
	var result := exporter.export_all(dry_run)

	var title := "Validate Design" if dry_run else "Generate All MPF Scenes"
	# A failed generate never writes anything (the exporter validates first), so
	# say that explicitly instead of showing counts that were not produced.
	var aborted := not dry_run and not result.is_ok()
	print_rich("[b]%s:[/b] %s" % [title, result.summary()])
	if aborted:
		print_rich("[color=red]Build aborted - nothing was written, the previous output is untouched.[/color]")
	for warning in result.warnings:
		print_rich("[color=yellow]  warning: %s[/color]" % warning)
	for error in result.errors:
		print_rich("[color=red]  error: %s[/color]" % error)

	if not dry_run and not aborted:
		# The generated files were written behind the editor's back, so tell the
		# FileSystem dock to re-scan. Without this the new scenes only show up
		# after the next focus change.
		EditorInterface.get_resource_filesystem().scan()

	_show_dialog(title, result, aborted)


## Shows the outcome in a dialog, so a failed export cannot be missed by someone
## who is not watching the Output panel.
func _show_dialog(title: String, result, aborted: bool) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = _dialog_text(result, aborted)
	# Editor dialogs have to be parented to the editor's own control tree.
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	# Free the dialog once it closes; it is single-use.
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)


func _dialog_text(result, aborted: bool) -> String:
	var lines := PackedStringArray()
	if aborted:
		lines.append("Build aborted - nothing was written.")
	lines.append(result.summary())
	# Keep the dialog readable: the full list is always in the Output panel.
	var shown := 0
	for message in result.errors + result.warnings:
		if shown == 8:
			lines.append("... see the Output panel for the full list.")
			break
		lines.append("- %s" % message)
		shown += 1
	return "\n".join(lines)
