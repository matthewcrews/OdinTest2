package main

import "core:runtime"
import "core:fmt"
import "core:container/bit_array"
import "core:math"
// import "core:mem/virtual"
// import "core:sys/windows"
import "core:time"

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
	flowRates,
	excesses,
	levels,
	capacities,
	limits: []f64,
	nodes: []Node,
	bufferSources: []Maybe(Source),
	bufferTargets: []Maybe(Target),
	constraintSources: []Source,
	constraintTargets: []Target,
	bufferNodeIds: []NodeId,
	downStatus: []Maybe(DownType),
) {
	toPush := make([dynamic]NodeId, 0, 16, allocator = context.temp_allocator)
	toReturn := make([dynamic]NodeId, 0, 16, allocator = context.temp_allocator)
	isSaturated := bit_array.create(len(nodes), allocator = context.temp_allocator)

	// Perform the initial pushes of flow to the Buffer targets
	for nodeId, bufferId in bufferNodeIds {
		target, hasTarget := bufferTargets[bufferId].?
		if hasTarget {
			if levels[bufferId] > 0.0 {
				flowRates[target.EdgeId] = math.INF_F64
				excesses[target.NodeId] = math.INF_F64
			}
			append(&toPush, target.NodeId)
		}
	}

	for (len(toPush) > 0) || (len(toReturn) > 0) {
		for len(toPush) > 0 {
			nodeId := pop(&toPush)
			node := nodes[nodeId]
			switch innerId in node {
				case BufferId: {
					bufferId := innerId
					if (excesses[nodeId] > 0.0) && 
						((levels[bufferId] <= 0.0 || levels[bufferId] >= capacities[bufferId])) {
							source, hasSource := bufferSources[bufferId].?
							target, hasTarget := bufferTargets[bufferId].?

							if hasSource && hasTarget {
								if bit_array.get(isSaturated, nodeId) {

									inletRate := flowRates[source.EdgeId]
									outletRate := flowRates[target.EdgeId]

									if (levels[bufferId] >= capacities[bufferId]) && (inletRate > outletRate){
										bit_array.set(isSaturated, nodeId)
										excesses[source.NodeId] = excesses[source.NodeId] + flowRates[source.EdgeId] - flowRates[target.EdgeId]
										flowRates[source.EdgeId] = flowRates[target.EdgeId]
										append(&toReturn, source.NodeId)
									} else if levels[bufferId] <= 0.0 {
										flowRates[target.EdgeId] = excesses[nodeId]
										excesses[target.NodeId] = excesses[target.NodeId] + excesses[nodeId]
										excesses[nodeId] = 0.0
										append(&toPush, target.NodeId)
									}
								} else {
									flowRates[target.EdgeId] = flowRates[target.EdgeId] + excesses[nodeId]
									excesses[target.NodeId] = excesses[target.NodeId] + excesses[nodeId]
									excesses[nodeId] = 0.0
									append(&toPush, target.NodeId)
								}
							} else if (hasSource && (!hasTarget)) {
								if levels[bufferId] >= capacities[bufferId] {
									flowRates[source.EdgeId] = 0.0
									excesses[source.NodeId] = excesses[source.NodeId] + excesses[nodeId]
									excesses[nodeId] = 0.0
									append(&toReturn, source.NodeId)
									bit_array.set(isSaturated, nodeId)
								}
							}
						}
				}
				case ConstraintId: {
					constraintId := innerId
					source := constraintSources[constraintId]
					target := constraintTargets[constraintId]
					
					if bit_array.get(isSaturated, target.NodeId){
						bit_array.set(isSaturated, nodeId)
						flowRates[source.EdgeId] = flowRates[target.EdgeId]
						excesses[source.NodeId] = excesses[source.NodeId] + excesses[target.NodeId]
						append(&toReturn, source.NodeId)
					} else {
						
						downType, isDown := downStatus[constraintId].?
						
						pushAmount : f64
						if isDown {
							pushAmount = 0.0
						} else {
							excess := excesses[nodeId]
							remainingFlowCapacity := limits[constraintId] - flowRates[target.EdgeId]
							pushAmount = math.min(excess, remainingFlowCapacity)
						}

						excesses[nodeId] = excesses[nodeId] - pushAmount
						flowRates[target.EdgeId] = flowRates[target.EdgeId] + pushAmount
						excesses[target.NodeId] = excesses[target.NodeId] + pushAmount
						append(&toPush, target.NodeId)

						if excesses[nodeId] > 0.0 {
							flowRates[source.EdgeId] = flowRates[target.EdgeId]
							excesses[source.NodeId] = excesses[source.NodeId] + excesses[nodeId]
							excesses[nodeId] = 0.0
							append(&toReturn, source.NodeId)
							bit_array.set(isSaturated, nodeId)
						}
					}
				}
			}
		}

		for len(toReturn) > 0 {
			nodeId := pop(&toReturn)
			node := nodes[nodeId]

			switch innerId in node {
				case BufferId: {
					bufferId := innerId

					if (excesses[nodeId] > 0.0) && (levels[bufferId] >= capacities[bufferId]) {
						source, hasSource := bufferSources[bufferId].?
						target, hasTarget := bufferTargets[bufferId].?

						if (hasSource && hasTarget) {
							if flowRates[source.EdgeId] > flowRates[target.EdgeId] {
								flowRates[source.EdgeId] = flowRates[target.EdgeId]
								excesses[source.NodeId] = excesses[source.NodeId] + excesses[nodeId]
								excesses[nodeId] = 0.0
								append(&toReturn, source.NodeId)
							}
						}
					}
				}
				case ConstraintId: {
					constraintId := innerId
					source := constraintSources[constraintId]
					target := constraintTargets[constraintId]
					bit_array.set(isSaturated, nodeId)
					flowRates[source.EdgeId] = flowRates[target.EdgeId]
					excesses[source.NodeId] = excesses[source.NodeId] + excesses[nodeId]
					excesses[nodeId] = 0.0
					append(&toReturn, source.NodeId)
				}
			}
		}
	}
}


main :: proc(){
	flowRates := []f64{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, }
	excesses := []f64{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, }
	levels := []f64{ 2000.0, 0.0, 0.0, 0.0, 0.0 }
	capacities := []f64{ 2000.0, 2000.0, 2000.0, 2000.0, 2000.0, }
	limits := []f64{ 1.0, 0.9, 0.8, 0.7 }
	nodes := []Node{
		BufferId(0),
		ConstraintId(0),
		BufferId(1),
		ConstraintId(1),
		BufferId(2),
		ConstraintId(2),
		BufferId(3),
		ConstraintId(3),
		BufferId(4),
	}
	bufferSources := []Maybe(Source) {
		nil,
		Source { 1, 1 },
		Source { 3, 2 },
		Source { 5, 3 },
		Source { 7, 4 },
	}
	bufferTargets := []Maybe(Target) {
		Target { 0, 1 },
		Target { 2, 3 },
		Target { 4, 5 },
		Target { 6, 7 },
		nil,
	}
	constraintSources := []Source {
		Source { 0, 0 },
		Source { 2, 2 },
		Source { 4, 4 },
		Source { 6, 6 },
	}
	constraintTargets := []Target {
		Target { 1, 2 },
		Target { 3, 4 },
		Target { 5, 6 },
		Target { 7, 8 },
	}
	bufferNodeIds := []NodeId {
		0,
		2,
		4,
		6,
		8,
	}
	downStatus := []Maybe(DownType) {
		nil,
		nil,
		nil,
		nil,
	}

	for _ in 1..=100 {

		start := time.tick_now()
		
		for i in 1..=1000 {
			// Reset the temp allocator
			free_all(context.temp_allocator)
		
			// Clear flow rates
			for i := 0; i < len(flowRates); i += 1	 {
				flowRates[i] = 0.0
			}
		
			// Clear excesses
			for i := 0; i < len(excesses); i += 1 {
				excesses[i] = 0.0
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