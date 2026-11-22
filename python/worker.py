"""Editable worker policy. Godot calls on_tick through the Python runner."""


def distance(first, second):
    return abs(first[0] - second[0]) + abs(first[1] - second[1])


def move_toward(observation, target):
    current_distance = distance(observation["position"], target)
    for cell in observation["walkable_neighbors"]:
        if distance(cell, target) < current_distance:
            return {"kind": "move_to", "target": cell}
    return {"kind": "idle"}


def on_tick(observation):
    position = observation["position"]
    deposits = [ore for ore in observation["ore_deposits"] if ore["remaining"] > 0]
    if observation["mining_ticks"] > 0:
        for ore in deposits:
            if distance(position, ore["position"]) == 1:
                return {"kind": "mine", "deposit_id": ore["id"]}

    carried = observation["carried_ore"]
    if carried >= observation["capacity"] or (carried and not deposits):
        hq = observation["hq_position"]
        if distance(position, hq) == 1:
            return {"kind": "deposit"}
        return move_toward(observation, hq)

    if deposits:
        ore = min(deposits, key=lambda item: (distance(position, item["position"]), item["id"]))
        if distance(position, ore["position"]) == 1:
            return {"kind": "mine", "deposit_id": ore["id"]}
        return move_toward(observation, ore["position"])

    return {"kind": "idle"}
