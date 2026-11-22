"""Run one trusted local behavior and exchange JSON Lines with Godot."""

import json
import os
import runpy
import sys
import traceback


def main(behavior_file):
    # Keep the original stdout pipe for protocol messages. Ordinary prints,
    # including writes to stdout's file descriptor, belong on stderr.
    protocol_fd = os.dup(sys.stdout.fileno())
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")

    with os.fdopen(protocol_fd, "w", encoding="utf-8", newline="\n") as protocol:
        def send(message):
            protocol.write(json.dumps(message, allow_nan=False) + "\n")
            protocol.flush()

        try:
            on_tick = runpy.run_path(behavior_file, run_name="pywars_worker").get("on_tick")
            if not callable(on_tick):
                raise TypeError("Behavior must define on_tick(observation)")
        except Exception as error:
            traceback.print_exc()
            send({"type": "startup_error", "message": describe(error)})
            return 1

        send({"type": "ready"})
        for line in sys.stdin.buffer:
            try:
                request = json.loads(line)
                if request["type"] != "observe":
                    raise ValueError("Expected an observe request")
                ids = {"tick_id": request["tick_id"], "robot_id": request["robot_id"]}
                observation = request["observation"] | ids
            except (ValueError, TypeError, KeyError) as error:
                print(f"Invalid Godot request: {describe(error)}", file=sys.stderr)
                continue

            try:
                action = on_tick(observation)
                send({"type": "decision", **ids, "action": action})
            except Exception as error:
                traceback.print_exc()
                send({"type": "error", **ids, "message": describe(error)})
    return 0


def describe(error):
    return f"{type(error).__name__}: {error}"[:1000]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
