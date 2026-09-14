@tool
extends EditorScript

## Phase 1 runner for the MPF scene generator.
##
## How to run: open this file in Godot's Script editor, then File > Run (Ctrl+Shift+X).
## An EditorScript runs inside the editor process; _run() is called once per "Run".
## Results are printed to the Output panel at the bottom of the editor.

const Generator := preload("res://addons/mpf_design_tools/mpf_scene_generator.gd")


func _run() -> void:
	# The generator reads design scenes from disk, so unsaved edits must be saved first.
	EditorInterface.save_all_scenes()

	var generator := Generator.new()
	generator.generate_all()

	# Ask the editor to re-read the project folder so the FileSystem dock shows
	# the deleted/created files.
	EditorInterface.get_resource_filesystem().scan()
