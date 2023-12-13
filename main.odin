package main

import "core:runtime"
import "core:fmt"
import "core:container/bit_array"
import "core:math"
// import "core:mem/virtual"
// import "core:sys/windows"
import "core:time"
import "core:intrinsics"

Row :: struct($K, $T: typeid)
	where intrinsics.type_is_integer(K) {
	values: []T
}

row_cnt :: #force_inline proc(row: Row($K, $V)) -> K {
	return K(len(row.values))
}

row_get :: #force_inline proc (row: Row($K, $T), k: K) -> T {
	return row.values[k]
}

row_set :: #force_inline proc (row: Row($K, $V), k: K, v: V) {
	row.values[k] = v
}

Bar :: struct($K, $T: typeid) 
	where intrinsics.type_is_integer(K) {
	values: []T
}

bar_get :: #force_inline proc (bar: Bar($K, $T), k: K) -> T {
	return bar.values[k]
}

bar_cnt :: #force_inline proc(bar: Bar($K, $V)) -> K {
	return K(len(bar.values))
}

get :: proc{
	row_get,
	bar_get,
}
set :: proc{row_set}
cnt :: proc{
	row_cnt,
	bar_cnt,
}


BufferId :: distinct i32
ConstraintId :: distinct i32
NodeId :: distinct i32
EdgeId :: distinct i32
TimeInterruptId :: distinct i32
TransitionInterruptId :: distinct i32

Node :: union #no_nil {
	BufferId,
	ConstraintId,
}

Link :: struct {
	EdgeId: EdgeId,
	NodeId: NodeId,
}

Target :: distinct Link
Source :: distinct Link

DownType :: union {
	TimeInterruptId,
	TransitionInterruptId,
}

push_relabel_solve :: proc (
	flowRates: Row(EdgeId, f64),
	excesses: Row(NodeId, f64),
	levels: Row(BufferId, f64),
	capacities: Row(BufferId, f64),
	limits: Row(ConstraintId, f64),
	nodes: Bar(NodeId, Node),
	bufferSources: Bar(BufferId, Maybe(Source)),
	bufferTargets: Bar(BufferId, Maybe(Target)),
	constraintSources: Bar(ConstraintId, Source),
	constraintTargets: Bar(ConstraintId, Target),
	bufferNodeIds: []NodeId,
	downStatus: Row(ConstraintId, Maybe(DownType)),
) {
	toPush := make([dynamic]NodeId, 0, 16, allocator = context.temp_allocator)
	toReturn := make([dynamic]NodeId, 0, 16, allocator = context.temp_allocator)
	isSaturated := bit_array.create(int(cnt(nodes)), allocator = context.temp_allocator)

	// Perform the initial pushes of flow to the Buffer targets
	for nodeId, bufferId in bufferNodeIds {
		bufferId := BufferId(bufferId)
		target, hasTarget := get(bufferTargets, BufferId(bufferId)).?
			if hasTarget {
				if get(levels, bufferId) > 0.0 {
					set(flowRates, target.EdgeId, math.INF_F64) 
					set(excesses, target.NodeId, math.INF_F64)
				}
				append(&toPush, target.NodeId)
			}
		}

	for (len(toPush) > 0) || (len(toReturn) > 0) {
		for len(toPush) > 0 {
			nodeId := pop(&toPush)
			node := get(nodes, nodeId)
			switch innerId in node {
				case BufferId: {
					bufferId := BufferId(innerId)
					if (get(excesses, nodeId) > 0.0) && 
						((get(levels, bufferId) <= 0.0 || get(levels, bufferId) >= get(capacities, bufferId))) {
							source, hasSource := get(bufferSources,bufferId).?
							target, hasTarget := get(bufferTargets,bufferId).?

							if hasSource && hasTarget {
								if bit_array.get(isSaturated, nodeId) {

									inletRate :=  get(flowRates, source.EdgeId)
									outletRate := get(flowRates, target.EdgeId)

									if (get(levels, bufferId) >= get(capacities, bufferId)) && (inletRate > outletRate){
										bit_array.set(isSaturated, nodeId)
										newExcess := get(excesses, source.NodeId) + get(flowRates, source.EdgeId) - get(flowRates, target.EdgeId)
										set(excesses, source.NodeId, newExcess) 
										set(flowRates, source.EdgeId, get(flowRates, target.EdgeId))
										append(&toReturn, source.NodeId)
									} else if get(levels, bufferId) <= 0.0 {
										set(flowRates, target.EdgeId, get(excesses, nodeId))
										set(excesses, target.NodeId, get(excesses, target.NodeId) + get(excesses, nodeId))
										set(excesses, nodeId, 0.0)
										append(&toPush, target.NodeId)
									}
								} else {
									set(flowRates, target.EdgeId, get(flowRates, target.EdgeId) + get(excesses, nodeId))
									set(excesses, target.NodeId, get(excesses, target.NodeId) + get(excesses, nodeId))
									set(excesses, nodeId, 0.0)
									append(&toPush, target.NodeId)
								}
							} else if (hasSource && (!hasTarget)) {
								if get(levels, bufferId) >= get(capacities, bufferId) {
									set(flowRates, source.EdgeId, 0.0)
									set(excesses, source.NodeId, get(excesses, source.NodeId) + get(excesses, nodeId))
									set(excesses, nodeId, 0.0)
									append(&toReturn, source.NodeId)
									bit_array.set(isSaturated, nodeId)
								}
							}
						}
				}
				case ConstraintId: {
					constraintId := ConstraintId(innerId)
					source := get(constraintSources, constraintId)
					target := get(constraintTargets, constraintId)
					
					if bit_array.get(isSaturated, target.NodeId){
						bit_array.set(isSaturated, nodeId)
						set(flowRates, source.EdgeId, get(flowRates, target.EdgeId))
						set(excesses, source.NodeId, get(excesses, source.NodeId) + get(excesses, target.NodeId))
						append(&toReturn, source.NodeId)
					} else {
						
						downType, isDown := get(downStatus, constraintId).?
						
						pushAmount : f64
						if isDown {
							pushAmount = 0.0
						} else {
							excess := get(excesses, nodeId)
							remainingFlowCapacity := get(limits, constraintId) - get(flowRates, target.EdgeId)
							pushAmount = math.min(excess, remainingFlowCapacity)
						}

						set(excesses, nodeId, get(excesses, nodeId) - pushAmount)
						set(flowRates, target.EdgeId, get(flowRates, target.EdgeId) + pushAmount)
						set(excesses, target.NodeId, get(excesses, target.NodeId) + pushAmount)
						append(&toPush, target.NodeId)

						if get(excesses, nodeId) > 0.0 {
							set(flowRates, source.EdgeId, get(flowRates, target.EdgeId))
							set(excesses, source.NodeId, get(excesses, source.NodeId) + get(excesses, nodeId))
							set(excesses, nodeId, 0.0)
							append(&toReturn, source.NodeId)
							bit_array.set(isSaturated, nodeId)
						}
					}
				}
			}
		}

		for len(toReturn) > 0 {
			nodeId := pop(&toReturn)
			node := get(nodes, nodeId)

			switch innerId in node {
				case BufferId: {
					bufferId := innerId

					if (get(excesses, nodeId) > 0.0) && (get(levels, bufferId) >= get(capacities, bufferId)) {
						source, hasSource := get(bufferSources, bufferId).?
						target, hasTarget := get(bufferTargets, bufferId).?

						if (hasSource && hasTarget) {
							if get(flowRates, source.EdgeId) > get(flowRates, target.EdgeId) {
								set(flowRates, source.EdgeId, get(flowRates, target.EdgeId))
								set(excesses, source.NodeId, get(excesses, source.NodeId) + get(excesses, nodeId))
								set(excesses, nodeId, 0.0)
								append(&toReturn, source.NodeId)
							}
						}
					}
				}
				case ConstraintId: {
					constraintId := innerId
					source := get(constraintSources, constraintId)
					target := get(constraintTargets, constraintId)
					bit_array.set(isSaturated, nodeId)
					set(flowRates, source.EdgeId, get(flowRates, target.EdgeId))
					set(excesses, source.NodeId, get(excesses, source.NodeId) + get(excesses, nodeId))
					set(excesses, nodeId, 0.0)
					append(&toReturn, source.NodeId)
				}
			}
		}
	}
}


main :: proc(){
	flowRates := Row(EdgeId, f64){{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, }}
	excesses := Row(NodeId, f64){{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, }}
	levels := Row(BufferId, f64){{ 2000.0, 0.0, 0.0, 0.0, 0.0 }}
	capacities := Row(BufferId, f64){{ 2000.0, 2000.0, 2000.0, 2000.0, 2000.0, }}
	limits := Row(ConstraintId, f64){{ 1.0, 0.9, 0.8, 0.7 }}
	nodes := Bar(NodeId, Node){{
		BufferId(0),
		ConstraintId(0),
		BufferId(1),
		ConstraintId(1),
		BufferId(2),
		ConstraintId(2),
		BufferId(3),
		ConstraintId(3),
		BufferId(4),
	}}
	bufferSources := Bar(BufferId, Maybe(Source)){{
		nil,
		Source { 1, 1 },
		Source { 3, 2 },
		Source { 5, 3 },
		Source { 7, 4 },
	}}
	bufferTargets := Bar(BufferId, Maybe(Target)){{
		Target { 0, 1 },
		Target { 2, 3 },
		Target { 4, 5 },
		Target { 6, 7 },
		nil,
	}}
	constraintSources := Bar(ConstraintId, Source){{
		Source { 0, 0 },
		Source { 2, 2 },
		Source { 4, 4 },
		Source { 6, 6 },
	}}
	constraintTargets := Bar(ConstraintId, Target){{
		Target { 1, 2 },
		Target { 3, 4 },
		Target { 5, 6 },
		Target { 7, 8 },
	}}
	bufferNodeIds := []NodeId {
		0,
		2,
		4,
		6,
		8,
	}
	downStatus := Row(ConstraintId, Maybe(DownType)){{
		nil,
		nil,
		nil,
		nil,
	}}

	for _ in 1..=100 {

		start := time.tick_now()
		
		for i in 1..=1000 {
			// Reset the temp allocator
			free_all(context.temp_allocator)
		
			// Clear flow rates
			for edgeId in 0 ..< cnt(flowRates) {
				set(flowRates, edgeId, 0.0)
			}
		
			// Clear excesses
			for nodeId in 0 ..< cnt(excesses) {
				set(excesses, nodeId, 0.0)
			}
		
			push_relabel_solve(flowRates, excesses, levels, capacities, limits, nodes, bufferSources, bufferTargets,
								constraintSources, constraintTargets, bufferNodeIds, downStatus)
		}
	
		duration := time.tick_since(start)
		us := time.duration_microseconds(duration)
	
		fmt.printf("%v \n", us)

	}
// fmt.printf("Flow Rates: %v \n", flowRates)
// fmt.printf("Excesses: %v \n", excesses)

	
}