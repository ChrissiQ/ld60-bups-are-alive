class_name GenomeRibbon
extends GridContainer
## A bup's genome as a chromosome map, the way a linkage map or a graphical genotype lays one out: a bacterium is haploid with one chromosome, so the
## loci run down a single bar in a fixed order (Genome.LOCI), each slot its own colour with the allele in it, and the locus name and the allele's value beside
## it, always in view. `show_bup` takes a bup's info (a living bup's, or the family record of a dead one: both have every gene).

const SLOT_SIZE := Vector2(46.0, 22.0)
const MUTATOR_NAMED_ABOVE := 1.05  ## a mutator gets its allele's name; the usual rate (1) has none to give

signal entry_requested(id: String)  ## a band was clicked: the encyclopedia entry of its gene

var _slots := {}  ## locus -> its GenomeSlot
var _values := {}  ## locus -> its value label


func _ready() -> void:
	columns = 2
	theme_type_variation = &"GenomeGrid"
	for locus: String in Genome.LOCI:
		var slot := GenomeSlot.new()
		slot.locus = locus
		slot.symbol = Strings.t("genome.symbol_" + locus)
		slot.top = locus == Genome.LOCI[0]
		slot.bottom = locus == Genome.LOCI[-1]
		slot.custom_minimum_size = SLOT_SIZE
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slot.chosen.connect(func(l: String) -> void: entry_requested.emit(Encyclopedia.entry_for_locus(l)))
		_slots[locus] = slot
		add_child(slot)
		var value_label := Label.new()
		value_label.theme_type_variation = &"StatValue"
		value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_values[locus] = value_label
		add_child(value_label)


## Fills the map from a bup's info. `with_tips` gives the slots their hover name and lets a click ask for the encyclopedia (the card that follows the pointer has neither).
func show_bup(info: Dictionary, with_tips := true) -> void:
	var reach := int(info.get("reach", 0))
	for locus: String in Genome.LOCI:
		var slot: GenomeSlot = _slots[locus]
		var value_label: Label = _values[locus]
		match locus:
			"donor":
				var on: bool = info.get("donor", false)
				slot.show_allele(1.0, on)
				value_label.text = Strings.t("genome.donor_yes") if on else Strings.t("genome.donor_no")
			"key":
				var level := Genome.key_level(reach)
				slot.show_allele(level / 2.0, level > 0)
				value_label.text = Strings.t(["genome.key_none", "genome.key_primed", "genome.key_yes", "genome.key_yes"][level])
			"mutator":
				var fold: float = info.get(Genome.INFO_KEYS["mutator"], 1.0)
				var shade := Genome.allele_fraction(locus, fold)
				slot.show_allele(shade, true)
				value_label.text = Strings.t("genome.fold", [String.num(fold, 0 if fold >= 10.0 else 1)]) + ("  " + Genome.mutator_allele_name(fold) if fold > MUTATOR_NAMED_ABOVE else "")
			_:
				var value: float = info[Genome.INFO_KEYS[locus]]
				var shade := Genome.allele_fraction(locus, value)
				var level := Genome.reach_level(reach, locus)
				slot.show_allele(shade, true)
				var text := Genome.format(locus, value)
				value_label.text = Strings.t("genome.raised", [text, level]) if level > 0 else text
		slot.tooltip_text = Strings.t("genome.name_" + locus) if with_tips else ""
		slot.mouse_filter = Control.MOUSE_FILTER_STOP if with_tips else Control.MOUSE_FILTER_IGNORE
