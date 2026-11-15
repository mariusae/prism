# bike-probe

Drives Bike and Weft's editor with the same keys, and compares what each
does: the outline after, and what is chosen. See `docs/bike-parity.md`.

- `probes.py` — the probes: an outline (tab-indented; ` [c]` collapsed,
  ` {task}` a type, `∅` an empty row), where the caret starts, the keys.
- `run_bike.py [label…]` — runs them in Bike 2 (`BIKE_APP` names its
  bundle), writing `bike-results.json`. It presses keys through System
  Events, and only ever while Bike is in front; it builds its outlines in
  a scratch document of its own.
- `run_weft.py [label…]` — runs them in a debug WeftMac started with
  `-GraphPath <scratch graph>`, through its `EditorProbe` hook: the keys
  are sent inside Weft's own window, never through the system.
- `compare.py` — the two side by side, where they differ.

`bike2-results.json` is Bike 2.0 (312)'s answers, kept to compare against
without Bike running.
