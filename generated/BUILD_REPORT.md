# MPF design build report

THIS DIRECTORY IS GENERATED - DO NOT EDIT MANUALLY.

Everything in here is produced by addons/mpf_design_exporter from the scenes in
res://design/. It is deleted and rebuilt in full on every export, so any manual
change will be lost without warning. Edit the design scenes instead.

Generated 1 slide(s) and 2 widget(s) from `res://design`.

## Widget placement

A widget's position on the slide is **not** stored in the widget scene:
`MPFWidget.initialize()` overwrites the root position with the
`widget_player` `x:`/`y:` settings (MPF defaults both to `0`).
Copy the values below into your MPF config to reproduce the design layout.
Widgets are stacked by `priority` (higher = in front); the suggested
values follow the top-to-bottom order of the design scene.

### example_slide

```yaml
widget_player:
  some_event:
    example_score:
      slide: example_slide
      x: 4
      y: 2
      priority: 10
    example_ball:
      slide: example_slide
      x: 4
      y: 18
      priority: 20
```
