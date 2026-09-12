extends GMCMedia

## Makes GMC find the exporter's output in res://generated/.
##
## GMC's media traversal (addons/mpf-gmc/scripts/media.gd) only looks in
## res://slides, res://widgets and res://modes/*/{slides,widgets} - or, if
## gmc.cfg sets [gmc] content_root, in res://<content_root>/{slides,widgets}.
## res://generated is none of those, so without this override the generated
## scenes would be invisible to the slide_player and widget_player.
##
## GMC allows every one of its internal scripts to be replaced from gmc.cfg
## (see addons/mpf-gmc/mpf_gmc.gd, which reads the class name as the config key).
## Enable this file by adding to res://gmc.cfg:
##
## [codeblock]
## [gmc]
## GMCMedia="res://addons/mpf_design_exporter/runtime/gmc_generated_media.gd"
## [/codeblock]
##
## Nothing else changes: the normal traversal still runs first, so hand-authored
## scenes in res://slides keep working exactly as before.

const GENERATED_ROOT := "res://generated"


func generate_traversal() -> void:
	# Run GMC's own traversal first (res://slides, res://widgets, modes, and the
	# defaults shipped with GMC).
	super()
	# Then add the build output. Later entries overwrite earlier ones, so a
	# generated scene wins over a hand-authored scene of the same name; the
	# exporter warns about that case at build time.
	self.recurse_dir("%s/slides" % GENERATED_ROOT, self.slides)
	self.recurse_dir("%s/widgets" % GENERATED_ROOT, self.widgets)
	self.log.debug("Added generated slides/widgets from %s", GENERATED_ROOT)
