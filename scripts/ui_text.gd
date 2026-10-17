class_name UiText
extends RefCounted
## Shared text styling: every number is shown in the theme's "Bright" colour.
## Feed text through `numbers()` and show the result in a RichTextLabel with bbcode on.
## (The whole game is set in one font, so numbers need no special typeface.)

static var _number: RegEx = RegEx.create_from_string("\\d+(?:\\.\\d+)?(?:/s|%|s\\b)?")


## The colour numbers are drawn in: whatever the theme says Bright text is.
static func number_color() -> Color:
	return ThemeDB.get_project_theme().get_color("font_color", "Bright")


static func numbers(text: String) -> String:
	var safe := text.replace("[", "[lb]")  # plain "[" in the text must not start a tag
	return _number.sub(safe, "[color=#%s]$0[/color]" % number_color().to_html(false), true)
