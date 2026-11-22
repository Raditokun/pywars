# AGENTS.md — Programmable RTS (Working Title)

> **Purpose:** Persistent project context and guardrails for Codex and other coding agents working on this Godot project.
>
> **Status:** Early concept / careful prototyping. This is **not** permission to implement the entire game at once.
>
> **Decision rule:** The creator's latest explicit instruction overrides this document. If a requested feature would substantially change the concept, explain the tradeoff and ask before building it. Keep tentative ideas tentative.

## 1. The one-sentence vision

Build a **real-time, 1v1, code-controlled RTS** in which players write and update Python programs during an ongoing match to automate a base, produce robots, and coordinate combat. Individual robots have their own behaviors, while a central commander script sets army-wide strategy. **Better software should provide a meaningful competitive advantage.**

### Design promise

**"You don't command an army. You program an army that knows how to command itself."**

This is intended to feel like a real strategy game, **not** a series of coding exercises, a programming quiz, or just an RTS with typed movement commands. Inspiration includes the automation loop of *The Farmer Was Replaced* and the economy/production/combat dynamics of *StarCraft* and *Clash of Clans*. These are design references, **not** instructions to clone any game.

## 2. Decisions already made (preserve these)

1. **Godot 4** is the game engine. The intended playable view is **top-down/isometric-feeling 3D**, on an understandable grid or tile-based arena.
2. **Real-time programming:** The simulation keeps running while both players edit, run, debug, and replace their programs. There is no mandatory code-writing phase followed by a separate execution-only phase.
3. **Code is the gameplay control mechanism.** Players should not directly WASD-control robots or manually click them across the battlefield like a normal RTS. The UI may allow selecting, inspecting, editing, and deploying programs.
4. **Two levels of autonomy:** A **commander script** chooses objectives, production priorities, and group orders; **unit behavior scripts** decide how robots execute those orders based on their local information.
5. **Traditional RTS production:** Workers gather resources and build infrastructure; buildings produce standard robot classes; programs define their behavior. **Do not** introduce a modular robot-parts construction system for the first prototype.
6. **Factories assign behaviors to produced units.** Many units may share a reusable script. In principle, individual units may have customized behavior later, but that is not required immediately.
7. **Scripts are reusable across matches.** A player can save a working codebase and bring it into future matches, then modify it live.
8. **The original arena idea matters:** Two players begin on opposite sides of a temporary barrier. They develop their bases and automation; the barrier eventually drops, opening PvP. **Coding continues before and after it drops.**
9. **Symmetrical competitive start:** Both players begin with equivalent basic resources, units, and technology. Wins should come from strategy and code, not asymmetrical paid/upgraded starting strength.
10. **Small, carefully tested milestones are more important than speed.** Prototype the interaction before expanding the feature set.

## 3. Core player experience

A representative match:

1. Both players begin with a Headquarters (HQ) and a couple of workers, in separated starting areas.
2. Saved worker scripts begin gathering **Ore**, returning it to the base, and building when commanded.
3. The commander uses the available Ore to set construction and robot-production priorities.
4. A Factory manufactures robots (initially basic soldiers), assigning the appropriate behavior program as they spawn.
5. The temporary middle wall drops after a configurable preparation period. From then on robots can cross into enemy territory.
6. Scouts and units may observe enemies, but information is **not omniscient**: the command layer should only have access to knowledge revealed by appropriate game systems. Full scouting/fog-of-war complexity can come later.
7. Players **keep editing programs while the match runs**: fix a bad worker routine, deploy a better retreat rule, change defensive priorities, etc.
8. Victory comes from destroying the enemy HQ (initial proposed win condition).

The tension should arise from competing priorities: economic growth vs. early aggression, production vs. defense, automation reliability vs. adaptability, and robust code vs. brittle scripts.

## 4. Programming model: commander + robot behavior

### Provisional three-tab prototype

Start the first programming prototype with **three active script roles**:

- `commander.py` — overall strategy, economy/production intentions, task assignment, squad orders.
- `worker.py` — worker behavior such as gathering, returning resources, building, and staying safe.
- `soldier.py` — combat behavior such as moving to orders, attacking, guarding, and retreating.

**This is a provisional prototype constraint, not a permanent product decision.** The creator is considering **one or three programs per match** and possibly a limit on lines of code; exact caps are **undecided**. Do **not** silently enforce a line limit, final slot cap, or ban on helper functions. Test whether three tabs make the prototype approachable first. Saved code between matches is a separate concern from how many scripts may be active at once.

Possible future roles: `scout.py`, `builder.py`, per-squad/per-unit overrides, and shared libraries. **Do not implement these before requested.**

### Responsibilities and behavior

- The commander gives **high-level orders**, such as `mine`, `defend`, `attack`, or a target destination. It does not need to micromanage every movement step.
- Each robot has its own **local state** and acts according to its assigned behavior. It should still behave sensibly between commander updates.
- Units can report observations/status back to the commander through a bounded, explicit game API (initially this can be a simple shared team-information snapshot).
- A production building can create a standard unit and assign a program role to it. Newly built units should not require copied-and-pasted code.
- Programs should eventually support **persistent game-safe memory** between ticks (e.g., current task, known danger area, last observed enemy). It must be bounded and separate from unrestricted Python process state.
- Programs must not access the entire true game state or opponent's hidden information. APIs expose only permitted observations.

### Illustrative *pseudocode*, not a locked API

```python
# commander.py — example intent, not an established function contract
def on_tick(hq):
	hq.set_target_count("worker", 4, program="worker.py")
	hq.set_target_count("soldier", 6, program="soldier.py")

    if hq.known_threat_near_base():
		hq.order_group("soldiers", "defend")
    else:
		hq.order_group("soldiers", "prepare")
```

```python
# worker.py — example intent, not an established function contract
def on_tick(bot):
    if bot.enemy_visible_nearby():
        bot.retreat()
    elif bot.inventory_full():
        bot.deposit_ore()
    else:
        bot.gather_nearest_known_ore()
```

`set_target_count(...)` means **maintain a desired quantity**, taking current units, queued production, and resources into account; it must **not** spawn a new robot every tick. These examples document the desired *feel* only. Design a small, coherent API for approval before treating names/signatures as authoritative.

## 5. Simulation and execution principles

- Use a **fixed, server-authoritative simulation tick** as the intended foundation. Tick length is not yet decided (e.g., 200 ms would only be an experiment).
- Each robot should request a limited, explicit game action per tick (or have a clearly modeled ongoing action). **Moving, mining, crafting, and combat consume in-game time.** Printing more commands should not allow instant actions.
- Prefer a bounded `on_tick(...)` / event-callback model over arbitrary endless `while True` loops in the simulation thread.
- Live script updates should be **validated, then swapped at a safe tick boundary**. A failed update should leave the previous working program intact when feasible, and show helpful diagnostics.
- When editing one tab, **the other scripts and the match continue running**. Hot-reloading one script should not reset robot positions, resources, buildings, or the other scripts.
- A small **CPU/instruction budget** could reward good algorithms later. It is a design experiment, **not** a required first-prototype feature. Do not impose arbitrary costs tied to source-code length.
- Deterministic rules, reproducible state changes, and clear debug logs are preferable to flashy presentation at this stage.

### Security: critical, not optional for real player Python

**Never** execute untrusted player Python with unrestricted `eval`/`exec` inside Godot or a privileged game/server process. A Python subprocess by itself is **not** a secure sandbox. Ultimately, real Python must run in a properly isolated, constrained execution environment with restricted filesystem/network/process access, timeouts, and CPU/memory limits. The server must validate all game-action requests and remain authoritative. For early milestones, **mock/preset action providers are acceptable** while this design is investigated. Do not claim Python sandboxing is secure without establishing and testing its isolation boundaries.

## 6. Narrow first-playable scope

The first playable prototype is **single-player against a simple scripted opponent** (or a two-side local simulation); online 1v1 is the longer-term target, **not** a blocker for proving the game loop.

| System | Minimum implementation |
| --- | --- |
| World | Small 3D grid arena, two starting zones, temporary central wall |
| Economy | **One resource: Ore**; visible Ore deposits, worker gathering and HQ deposit |
| Buildings | **HQ + Factory** (additional structures deferred) |
| Units | **Worker + Soldier** only |
| Production | HQ can produce workers; Factory can produce soldiers; costs and queues |
| Code roles | **Commander, Worker, Soldier** (three provisional tabs) |
| Combat | Basic attack, health, death, and HQ damage |
| Win condition | Destroy opposing HQ |
| Editor | Edit, run/update, error output, and visible status per active script role |
| Persistence | Locally save/load scripts between test matches; no accounts/cloud required |
| Opponent | Simple fixed scripts sufficient to test behavior differences |

Use placeholder geometry and basic materials. **No polished art, animations, sound design, VFX, online accounts, matchmaking, rankings, monetization, tech trees, or large unit rosters during the initial prototype.**

### First proof of fun (must be observable)

Two soldiers made from the **same Factory**, with the **same statistics and resources**, must be able to behave differently because of their programs. For example, one rushes the enemy while another guards the HQ and retreats at low health. Players must be able to modify an active behavior mid-match and observe the change without restarting the world.

A second proof: two players/sides can use different worker and production policies, creating noticeably different economic and military outcomes from equivalent starting conditions.

## 7. Milestones — implement in order; stop after the requested slice

### M0 — Inspect and define a small vertical slice
- Inspect the current Godot repository, engine version, scenes, plugins, and existing architecture before writing code.
- Recommend the smallest testable change, identify dependencies/risks, and request approval before major new dependencies or architecture commitments.
- Set up a minimal Godot project structure only if needed. Keep the project runnable after each milestone.

### M1 — Deterministic world and autonomous units
- Render a small 3D grid arena with HQ, Ore nodes, a temporary wall, and worker/soldier placeholders.
- Implement world state, movement rules, gathering, deposit, unit health, and simple actions.
- Drive one worker with an internal *preset* behavior first. A real Python runtime is **not required** to validate simulation rules.

### M1.5 — Trusted local Python worker
- Use one external Python runner to select actions for the existing M1 worker. Godot still owns simulation ticks and validates all actions.
- Edit `python/worker.py` between runs. A missing or late reply makes the worker idle without switching to the GDScript preset.
- This is a local development prototype. Player code isolation and live deployment remain separate work. See [the M1.5 API](docs/m1.5-python.md).

### M2 — Commander orders, production, and competing behaviors
- Implement HQ/Factory production queues and costs, simple commander objectives, and worker/soldier behavior separation.
- Demonstrate two different soldier behaviors and an economy-vs-production tradeoff using local scripts/presets.
- Add reproducible tests of unit actions and resource accounting.

### M3 — Safe live programming loop
- Design/approve the minimal Python-to-game API and isolation approach.
- Add the three-tab code editor, error display, per-role deployment, and locally saved scripts.
- Verify a valid update changes running behavior; an invalid update doesn't destroy an ongoing match.
- Do not ship an unsafe Python executor as a temporary shortcut without explicitly marking and isolating the risk.

### M4 — Playable local RTS match
- Make the barrier drop, support AI attacks and HQ destruction, add a simple scripted opponent, and test the complete loop.
- Balance only enough to expose meaningful strategic decisions. Reassess the script cap through actual playtests.

### M5 — Later, after core fun is proven
- Architect and implement real 1v1 networking with an authoritative server, safe per-player execution, fog of war/scouting, and additional roles **only with explicit approval**.

These are **planning stages**, not a command to complete all stages in one session.

## 8. Explicit non-goals and anti-drift rules

**Do not turn this into:**

- A direct-control action game or normal click-to-command RTS.
- A turn-based or prepare-then-watch coding competition.
- A game where typing speed or number of lines typed determines victory.
- A coding tutorial with quizzes, syntax challenges, or mandatory lesson progression.
- A single-robot duel with no economy, factories, or broader army coordination.
- A physical robot-building/circuit-design simulator.
- A large StarCraft clone with dozens of unit types and tech trees.
- An autonomous AI-LLM game where language models replace the player's written Python.

**Do not introduce without approval:** new resource types, complex crafting, procedurally generated worlds, class/character progression, equipment systems, weapons beyond the necessary prototype, player accounts, networking services, cloud saves, monetization, detailed UI redesigns, or speculative abstractions that do not support the current milestone.

If a future idea sounds cool but isn't necessary to validate the current milestone, put it under **Later / Ideas**, not in the implementation.

## 9. Decisions intentionally left open

These are NOT requirements until the creator approves them:

- Final game title and visual identity.
- Final number of **active program slots per match** (creator is considering one or three).
- Whether to impose a **line-of-code cap**, and if so how to avoid punishing good abstractions. **Do not enforce one yet.**
- Whether every unit can have a unique script, versus shared role programs only.
- Fixed tick rate; exact wall-drop time; unit movement/action durations.
- Final unit prices, build times, resource income rates, and maximum army sizes.
- CPU/instruction budget as a strategic game resource.
- Fog of war, scouts, radio networks, communication disruption, and persistent unit memory beyond minimal safe state.
- Multiplayer hosting/netcode and any specific Python sandbox implementation.

When a choice must be made to complete a small test, choose the **simplest reversible default**, label it a prototype assumption, and report it to the creator.

## 10. Codex workflow agreement

For **every** implementation task:

1. **Read this file first** and inspect relevant existing code. Preserve the concept and prior working functionality.
2. State which milestone and acceptance criterion the task addresses. Propose the **smallest playable/testable change**.
3. Do **not** silently expand scope, add dependencies, overhaul architecture, or implement extra features. Ask before making a major product or technical decision not settled above.
4. Prefer clear, modular Godot scenes/scripts and straightforward APIs over speculative frameworks. Keep simulation rules separate from presentation and future Python execution adapters.
5. Run available Godot project checks and appropriate tests (including headless tests where supported); do not falsely claim verification.
6. Report **what changed, how it was tested, known limitations, and the next smallest step**.
7. If the creator explicitly changes the game design, propose an update to this `AGENTS.md` so future sessions remain aligned.
8. **Stop after the requested task.** Do not autonomously build the next milestone.

### First request after connecting Codex

> Read `AGENTS.md` and inspect the existing Godot project. **Do not change files yet.** Summarize your understanding of the game, identify the smallest M0/M1 vertical slice we can test, note technical risks (especially Python execution), and propose a concrete step-by-step plan. Wait for me to choose the first task before coding.

---

**North star:** The game succeeds if writing smarter code produces a demonstrably smarter, more effective RTS army—without removing the strategic choices and excitement of a live battle.
