class_name TraitRows
extends VBoxContainer
## The rows of a colony's traits: the genes' means (`Genome.LABELED`), then mutations, harm, donors, the acetate key and generation, one `StatRow` each. It is what the tray's
## "Dish details" and "All dishes" sections hold, so both show the same list in the same formats: a new statistic is added here, once. Optional `leading` rows (a key and its label)
## come first, set by `set_lead`. The rows are made the first time `show_stats` is called.

const STAT_ROW := preload("res://ui/stat_row.tscn")

var leading: Array[Array] = []  ## [key, label] of the rows before the traits (see `set_lead`)
var _rows := {}  ## key -> its StatRow


## Every statistic's key, in the order of the rows.
static func keys() -> Array:
	return Genome.LABELED + ["mutations", "harm", "donor", "key", "generation"]


static func _label(key: String) -> String:
	match key:
		"mutations": return Strings.t("hud.colony_mutations")
		"harm": return Strings.t("hud.colony_harm")
		"donor": return Strings.t("hud.colony_donors")
		"key": return Strings.t("hud.colony_key")
		"generation": return Strings.t("hud.colony_generation")
	return Genome.label(key)


static func format(key: String, value: float) -> String:
	match key:
		"mutations": return "%.1f" % value
		"harm", "donor", "key": return "%.1f%%" % (value * 100.0)
		"generation": return UiText.thousands(value, 1)
	return Genome.format(key, value)


## A row before the traits (made with the rest when they are first shown).
func set_lead(key: String, label: String) -> void:
	leading.append([key, label])


## Sets a leading row's text.
func set_lead_text(key: String, text: String) -> void:
	if _rows.has(key):
		(_rows[key] as StatRow).value_text = text


## Shows each trait of `stats` (a Dictionary keyed by `keys()`, the dish's `population_stats` or a mean of them).
func show_stats(stats: Dictionary) -> void:
	if _rows.is_empty():
		for pair in leading:
			_add_row(pair[0], pair[1])
		for key: String in keys():
			_add_row(key, _label(key))
	for key: String in keys():
		(_rows[key] as StatRow).value_text = format(key, float(stats[key]))


func _add_row(key: String, label: String) -> void:
	var row: StatRow = STAT_ROW.instantiate()
	row.label_text = label
	add_child(row)
	_rows[key] = row
