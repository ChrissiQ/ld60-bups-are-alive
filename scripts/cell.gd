class_name Cell
extends RefCounted

var pos: Vector2
var dir: Vector2
var energy: float
var genome: Genome
var generation := 0

# Derived from the genome, which is fixed for a bup's whole life, so they are worked out once.
var speed: float
var sense: float
var _radius: float
var _split_threshold: float
var _upkeep: float


func _init(p_pos: Vector2, p_genome: Genome, p_energy: float) -> void:
	pos = p_pos
	genome = p_genome
	energy = p_energy
	dir = Vector2.RIGHT
	speed = genome.get_gene("speed")
	sense = genome.get_gene("sense")
	_radius = genome.get_gene("size")
	_split_threshold = 20.0 + 10.0 * _radius
	# Energy burned per second: speed and sensing are costly.
	_upkeep = genome.get_gene("metabolism") * (
		0.6
		+ 0.0002 * speed * speed
		+ 0.01 * sense
		+ 0.15 * _radius
	)


func radius() -> float:
	return _radius


## Energy needed before dividing; bigger cells need more.
func split_threshold() -> float:
	return _split_threshold


## Energy burned per second.
func upkeep() -> float:
	return _upkeep


## A name for the info panel, going by size.
func title() -> String:
	return "LIL BUP" if _radius < 3.5 else ("BIG BUP" if _radius > 5.5 else "BUP")
