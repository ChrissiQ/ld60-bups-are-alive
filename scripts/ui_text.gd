class_name UiText
extends RefCounted
## Shared text styling: every number is shown in the theme's "Bright" colour.
## Feed text through `numbers()` and show the result in a RichTextLabel with bbcode on.
## (The number typeface, Commit Mono, comes from the theme's number types, not from this code.)

static var _number: RegEx = RegEx.create_from_string("(\\d+)(\\.\\d+)?(/s|%|s\\b)?")
const TOOLTIP_WIDTH := 38  ## characters a tooltip line holds (see TooltipFit)


## The colour numbers are drawn in: whatever the theme says Bright text is.
static func number_color() -> Color:
	return ThemeDB.get_project_theme().get_color("font_color", "Bright")


## The colour the first number of a readout is drawn in for a moment after it changed.
static func flash_color() -> Color:
	return ThemeDB.get_project_theme().get_color("font_color", "BrightFlash")


## Whole-number digits with a comma between each group of three: "178335" -> "178,335".
static func group(digits: String) -> String:
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return out


## A number as it is shown: thousands separated by commas, and the given number of decimals.
static func thousands(value: float, decimals := 0) -> String:
	var text := String.num(absf(value), decimals)
	var point := text.find(".")
	var whole := text if point < 0 else text.substr(0, point)
	var shows_nonzero := text.replace(".", "").replace("0", "") != ""
	return ("-" if value < 0.0 and shows_nonzero else "") + group(whole) + ("" if point < 0 else text.substr(point))


## Colours every number in the text, and separates its thousands.
## A dish radius (µm) as it is shown: "6.25 mm".
static func mm(radius_um: float) -> String:
	return Strings.t("ui.mm", [String.num(radius_um / StartConditions.UM_PER_MM, 2)])


## With `flash_after` (a word of the text) the first number after that word is in the flash colour instead (a figure that has just changed).
static func numbers(text: String, flash_after := "") -> String:
	var safe := text.replace("[", "[lb]")  # plain "[" in the text must not start a tag
	var colour := number_color().to_html(false)
	var out := ""
	var from := 0
	var flash_from := safe.find(flash_after) if flash_after != "" else -1
	var flashed := false
	for m in _number.search_all(safe):
		out += safe.substr(from, m.get_start() - from)
		var shown := colour
		if flash_from >= 0 and not flashed and m.get_start() >= flash_from:
			shown = flash_color().to_html(false)
			flashed = true
		out += "[code][color=#%s]%s%s%s[/color][/code]" % [shown, group(m.get_string(1)), m.get_string(2), m.get_string(3)]
		from = m.get_end()
	return out + safe.substr(from)

## The text with its lines broken at spaces so none is longer than `width` characters (a single longer word keeps its line).
static func tooltip_lines(text: String, width := TOOLTIP_WIDTH) -> String:
	var lines: PackedStringArray = []
	for paragraph in text.split("\n"):
		var line := ""
		for word in paragraph.split(" ", false):
			if line.is_empty():
				line = word
			elif line.length() + 1 + word.length() <= width:
				line += " " + word
			else:
				lines.append(line)
				line = word
		lines.append(line)
	return "\n".join(lines)
