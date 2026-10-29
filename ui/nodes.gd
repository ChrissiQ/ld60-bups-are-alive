class_name Nodes
extends RefCounted
## Small helpers for building and emptying node trees.


## Removes every child of a node and frees it (it is out of the tree at once; the freeing waits for the frame's end).
static func clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
