use super::{validate, Goal, Result};
use std::{
    cmp::Reverse,
    collections::{BinaryHeap, HashMap},
};

// Dijkstra with positive skill costs. The sequence number and skill names are
// stable tie-breakers so identical inputs yield identical plans.
pub(super) fn plan(goal: &Goal) -> Result<Vec<usize>> {
    validate(goal)?;
    if goal.initial_state == goal.goal_state {
        return Ok(Vec::new());
    }
    let mut best: HashMap<String, (u64, usize)> = HashMap::new();
    let mut predecessor: HashMap<String, (String, usize)> = HashMap::new();
    let mut queue: BinaryHeap<Reverse<(u64, usize, String)>> = BinaryHeap::new();
    best.insert(goal.initial_state.clone(), (0, 0));
    queue.push(Reverse((0, 0, goal.initial_state.clone())));

    let mut indexes: Vec<usize> = (0..goal.skills.len()).collect();
    indexes.sort_by(|&left, &right| goal.skills[left].id.cmp(&goal.skills[right].id));

    let mut outgoing: HashMap<&str, Vec<usize>> = HashMap::new();
    for index in indexes {
        outgoing
            .entry(&goal.skills[index].from)
            .or_default()
            .push(index);
    }
    while let Some(Reverse((cost, hops, state))) = queue.pop() {
        if best.get(&state) != Some(&(cost, hops)) {
            continue;
        }
        if state == goal.goal_state {
            break;
        }
        let Some(edges) = outgoing.get(state.as_str()) else {
            continue;
        };
        for &index in edges {
            let skill = &goal.skills[index];
            let next_cost = cost + u64::from(skill.cost);
            let next_hops = hops + 1;
            let candidate = (next_cost, next_hops);
            if best.get(&skill.to).is_none_or(|old| candidate < *old) {
                best.insert(skill.to.clone(), candidate);
                predecessor.insert(skill.to.clone(), (state.clone(), index));
                queue.push(Reverse((next_cost, next_hops, skill.to.clone())));
            }
        }
    }
    if !best.contains_key(&goal.goal_state) {
        return Err("No verified skill path reaches the requested goal".into());
    }
    let mut path = Vec::new();
    let mut cursor = goal.goal_state.as_str();
    while cursor != goal.initial_state {
        let (previous, index) = predecessor
            .get(cursor)
            .ok_or("Planner predecessor chain is incomplete")?;
        path.push(*index);
        cursor = previous;
    }
    path.reverse();
    Ok(path)
}
