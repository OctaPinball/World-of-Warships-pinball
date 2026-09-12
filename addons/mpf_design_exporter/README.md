# MPF Design Exporter

Design a complete 128x32 DMD slide - slide content **and** its widgets - in one
Godot scene, then compile it into the separate slide/widget scenes that MPF and
GMC expect.

```text
res://design/            (the only source of truth, hand-authored)
      |
      v   Project > Tools > MPF Tools > Generate All MPF Scenes
res://generated/         (build artifact, deleted and rewritten every time)
   |- slides/
   +- widgets/
```

## Why

GMC needs a slide scene and a widget scene to be separate files: the
`slide_player` instantiates a slide, and the `widget_player` adds widgets into
it at runtime (`MPFSlide.process_widget()` puts each widget into the slide's own
`_widgets` container). Authoring them separately means you never see the real
composition while you work. The design scene lets you lay the whole slide out at
once; the exporter splits it up again.

## Authoring rules

```text
design/game.tscn                       -> generated/slides/game.tscn
+-- DesignGame        (MPFSlide root)      slide name = FILE name
    |- Background     (ColorRect)          stays in the slide
    |- ScoreWidget    (MPFWidget)       -> generated/widgets/score_widget.tscn
    |   |- ScoreLabel                      stays inside the widget
    |   +- ScoreIcon
    +- BallSaveWidget (MPFWidget)       -> generated/widgets/ball_save_widget.tscn
```

* A design scene's root must be an `MPFSlide` (or a single `MPFWidget`, for a
  widget that does not belong to one particular slide). Nodes are recognised by
  their actual class - `node is MPFSlide` / `node is MPFWidget` - never by name.
* **Slide name** = the design file name (`design/game.tscn` -> slide `game`).
  **Widget name** = the node name in `snake_case` (`ScoreWidget` ->
  `score_widget`). Override either by setting the `mpf_name` metadata on the
  node (Inspector > Node > Metadata; add a String entry named `mpf_name`).
* Names must be unique across the whole design directory, because GMC keys every
  scene by file name alone.
* Widgets cannot be nested inside other widgets - MPF always targets a slide.
* If a slide or widget uses GMC's `animation_player` property (the
  created/active/inactive/removed animations), the AnimationPlayer it points at
  must live inside that same node: the slide and the widget become separate
  scenes, and Godot cannot store a node reference that crosses the boundary.
  Give each widget its own AnimationPlayer.
* Files and folders starting with `_` are ignored, e.g. `design/_parts/icon.tscn`
  for shared pieces that design scenes instance but that are not slides or
  widgets themselves.

## Widget positions

The exporter does **not** bake the design position into the widget scene, and
that is deliberate: GMC's `MPFWidget.initialize()` ends with

```gdscript
self.position.x = settings["x"]
self.position.y = settings["y"]
```

so the root position is always overwritten by the `widget_player` settings
(MPF's config spec defaults both `x` and `y` to `0`). The widget scene keeps its
own internal layout with the root at `(0, 0)`, and each widget's position on the
128x32 canvas is written to `generated/BUILD_REPORT.md` as a ready-to-paste
`widget_player` block:

```yaml
widget_player:
  some_event:
    score_widget:
      slide: game
      x: 10
      y: 4
      priority: 10
```

`priority` controls the stacking order at runtime (higher = in front); the
suggested values follow the top-to-bottom order of the design scene. Note that
widgets always draw *above* the slide's own content, because GMC adds them in a
container on top of the slide.

## Full rebuild, always

Every run deletes `res://generated/` completely and regenerates it. A renamed or
deleted widget can therefore never leave a stale file behind, and the output is
always exactly `f(design)`. There is no incremental mode, no "keep existing
file", and no manual per-widget export step.

Two safety rails:

* The recursive delete only runs if `res://generated/.mpf_generated` exists. If
  the output path is ever wrong, the export aborts instead of deleting content.
* The build runs in two passes: everything is loaded, validated and packed
  first, and only a completely clean run is allowed to write. A broken design
  leaves the previous output untouched.

The output is deterministic - the same design directory produces byte-identical
files - so it can be committed without churn. Do not edit anything in
`res://generated/`; it is overwritten without warning.

## Making GMC see the output

GMC's media traversal only looks in `res://slides`, `res://widgets` and
`res://modes/*/`. `runtime/gmc_generated_media.gd` extends `GMCMedia` and adds
`res://generated/slides` and `res://generated/widgets` to that traversal. It is
enabled in `res://gmc.cfg`:

```ini
[gmc]
GMCMedia="res://addons/mpf_design_exporter/runtime/gmc_generated_media.gd"
```

Hand-authored scenes in `res://slides` keep working exactly as before; the
exporter warns if a generated name collides with one of them.

## Files

| File | What it is |
| --- | --- |
| `design_exporter.gd` | All the logic. No editor UI, no `EditorInterface`, so it also runs headless. |
| `plugin.gd` | The `EditorPlugin`: adds *Project > Tools > MPF Tools* with **Generate All MPF Scenes** and **Validate Design**. |
| `runtime/gmc_generated_media.gd` | Runtime-only: teaches GMC to look in `res://generated/`. |

## Running it without the editor UI

`design_exporter.gd` is a plain `RefCounted`, so anything with a Godot script
context can drive it:

```gdscript
var exporter := MPFDesignExporter.new()
var result := exporter.export_all()      # full rebuild
var check := exporter.export_all(true)   # validate only, writes nothing
print(result.summary())                  # "2 slide(s), 5 widget(s), 0 error(s), 1 warning(s)"
```

Note that global class names such as `MPFSlide` are only registered when the
project runs through the editor, so a CI build should invoke it from an editor
context (for example a small `EditorPlugin` run with
`godot --headless --editor`), not with `godot --headless --script`.

## Godot APIs used, and why

* `@tool` - makes a script run inside the editor. Without it the exporter would
  only execute in a running game.
* `EditorPlugin` + `add_tool_submenu_item()` - the *MPF Tools* menu.
* `PackedScene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)` - builds a live
  node tree from a scene file while preserving editor state, so nested scene
  instances stay instances instead of being flattened when re-packed.
* `Node.owner` - a `PackedScene` only stores nodes owned by the scene root. The
  exporter re-owns a widget's subtree onto the widget before packing it, which is
  what turns a branch of the design tree into a scene of its own.
* `PackedScene.pack()` + `ResourceSaver.save()` - serialise that node tree back
  into a `.tscn` file.
* `DirAccess` / `FileAccess` - directory scan, recursive delete, marker file.
* `EditorInterface.get_resource_filesystem().scan()` - tells the editor to pick
  up files that were written behind its back.
