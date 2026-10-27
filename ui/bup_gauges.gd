class_name BupGauges
extends VBoxContainer
## The two bars at the top of a bup's panel: its MASS (how big it is: the bar's length is its body's, a tick where it was born, the end where it divides, and with starvation on a red tick
## where it dies) and its RESERVE (the energy it holds, out of the most its body can hold, a tick at the floor below which growth stops). The reserve's colour says how the bup stands:
## amber at the floor (food-limited: all its food goes straight into growth), red when it is starving, green above. `show_bup` takes a living bup's info or a dead one's record: a dead bup's
## bars are what they were when it died, in grey.

const VALUE_WIDTH := 110.0  ## the room at the end of a row: its number and the word beside the reserve's
const FOOD_LIMITED_BELOW := 1.25  ## the reserve is food-limited while it is within this many times the floor
const STARVING_BELOW := 0.5  ## and starving, with no starvation option, below this share of the floor

var _mass_bar: GaugeBar
var _mass_value: Label
var _reserve_bar: GaugeBar
var _reserve_value: Label
var _reserve_state: Label


func _ready() -> void:
	theme_type_variation = &"SnugStack"
	var mass := _row("gauges.mass")
	_mass_bar = mass[0]
	_mass_value = mass[1]
	var reserve := _row("gauges.reserve")
	_reserve_bar = reserve[0]
	_reserve_value = reserve[1]
	_reserve_state = reserve[2]


## A row: the name, the bar and its number (and, for the reserve, the word of its state): [bar, number, word or null].
func _row(name_key: String) -> Array:
	var row := HBoxContainer.new()
	row.theme_type_variation = &"TightRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Label.new()
	name_label.text = Strings.t(name_key)
	name_label.theme_type_variation = &"Small"
	name_label.custom_minimum_size.x = 52.0
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	var bar := GaugeBar.new()
	bar.custom_minimum_size = Vector2(80.0, 20.0)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	var end := HBoxContainer.new()  # (the number, and for the reserve the word of its state: both rows keep the same room, so their bars are as long as each other)
	end.theme_type_variation = &"TightRow"
	end.alignment = BoxContainer.ALIGNMENT_END
	end.custom_minimum_size.x = VALUE_WIDTH
	end.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var value := Label.new()
	value.theme_type_variation = &"StatValue"
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	end.add_child(value)
	var word: Label = null
	if name_key == "gauges.reserve":
		word = Label.new()  # (after the number, only while it is food-limited or starving)
		word.mouse_filter = Control.MOUSE_FILTER_IGNORE
		end.add_child(word)
	row.add_child(end)
	add_child(row)
	return [bar, value, word]


## `info` is a bup's info (alive) or its family record (dead); `starvation` is whether the dish lets bups starve.
func show_bup(info: Dictionary, starvation: bool, alive: bool) -> void:
	var mass: float = info["mass"]
	var birth: float = info["birth_mass"]
	var divides: float = maxf(info["div_mass"], 0.001)
	var energy: float = info["energy"]
	var capacity: float = maxf(info["max_energy"], 0.001)
	var floor_energy: float = Cell.MAINTENANCE_FLOOR
	var starving := alive and ((starvation and mass < birth) or energy < floor_energy * STARVING_BELOW)
	var limited := alive and not starving and energy <= floor_energy * FOOD_LIMITED_BELOW
	var tone := GaugeBar.Tone.DEAD if not alive else (GaugeBar.Tone.STARVING if starving else GaugeBar.Tone.NORMAL)
	var share: Array[float] = [birth / divides]
	_mass_bar.show_gauge(GaugeBar.Kind.MASS, tone, mass / divides, share, (Biology.STARVE_MIN_MASS_SHARE * birth / divides) if starvation else -1.0, 0.0)
	_mass_value.text = String.num(mass, 1)
	var reserve_tone := tone
	if limited:
		reserve_tone = GaugeBar.Tone.LIMITED
	var floor_share: Array[float] = [floor_energy / capacity]
	_reserve_bar.show_gauge(GaugeBar.Kind.RESERVE, reserve_tone, energy / capacity, floor_share, -1.0, floor_energy / capacity)
	_reserve_value.text = String.num(energy, 0)
	_reserve_state.text = Strings.t("gauges.starving") if starving else (Strings.t("gauges.food_limited") if limited else "")
	_reserve_state.theme_type_variation = &"StatStarving" if starving else &"StatLimited"
