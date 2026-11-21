class_name IterationPlan
extends RefCounted
## One iteration of the pooled world: `k` steps of `delta` seconds, what each dish's world puts into the medium over
## them, the steps after which a history sample is taken, and what is asked of the state after them (the questions answered and the
## pictures published, recorded in the steps' list: SimCore.run).

var k := 0
var delta := 20.0
var step_times := PackedFloat64Array()  ## the world time at the end of each step
var history_flags := PackedByteArray()  ## 1 after a step whose stats are sampled (at most GpuLayout.STATS_ITER_SAMPLES an iteration)
var events := {}  ## row -> DishWorld.events() of the window (made by `SimCore._world_events`): discs, puffs, deposits and husks by step, 1-based
var event_capacity := 0  ## family events (births, and as many deaths) the iteration's ring holds; 0: the core sizes it
var questions: Array = []  ## the dishes' questions answered after the steps (SimCore.answer's form)
var view: ViewRequest = null  ## what to publish after the steps (SimCore.publish's; null: nothing)
var publish: Variant = null
