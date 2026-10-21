extends Node
## Gives every node its words (autoload "TextSweep"): each node that comes into the game has any "@section.name" in its
## text, tooltip, dialog title and so on swapped for the text in text/strings.cfg (see Strings), before its own `_ready`
## runs. So a scene just names its texts, and no script needs to remember to ask for them.
## It is the first autoload, so that it comes before DialogStyle: a dialog is sized with its real text.


func _ready() -> void:
	get_tree().node_added.connect(Strings.apply_to)
	Strings.apply(get_tree().root)  # (whatever came in before this)
