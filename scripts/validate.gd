class_name Validate
extends RefCounted
## Checks for untrusted data read from files, so every loader agrees on what "usable" means.


static func is_number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))


## A saved 2D point: an array of two numbers.
static func is_vec2(v: Variant) -> bool:
	return v is Array and v.size() == 2 and is_number(v[0]) and is_number(v[1])


## An array whose every item is a number.
static func all_numbers(values: Array) -> bool:
	for v: Variant in values:
		if not is_number(v):
			return false
	return true
