# 3D Snake (Odin + raylib)

A single-player, true-3D snake game written in **Odin** with **raylib**.
The snake flies through a 12×12×12 cubic lattice in **six directions** —
no gravity, no floor, pure 3D piloting.

![AI autopilot demo](docs/autopilot.gif)

*The built-in AI (press `B`) piloting a 90+ segment snake — BFS pathfinding
with survival lookahead, shown in the modern tube skin.*

## Features

- **True 3D movement** — six directions (±X, ±Y, ±Z) inside a 12³ cube
- **AI autopilot** (`B`) — watch the AI play: BFS shortest path to the food,
  plus a survival simulation that only commits to a meal when the head can
  still reach its own tail afterwards; falls back to tail-chasing to stay
  alive and auto-restarts after death. Take back control anytime with `B`
- **Two snake skins** (`M`) — a glossy modern tube body (tapered capsules,
  emerald→ocean gradient, specular glints, head aura, distance fog) or the
  classic cube look
- **Panoramic orbit camera** by default: the whole cube rotates around its
  center as one rigid object (keyboard `IJKL` or mouse drag), with an
  optional **first-person view** (press `V`)
- **Screen-relative steering** — in orbit view `A/D/W/S` always mean
  screen-left/right/up/down, no matter how the cube is rotated
- **Flight-path guide** — a dotted line ahead of the snake shows where flying
  straight leads, colored green → yellow → red by distance to the obstacle
- **Navigation aids** — tri-view minimap (top / front / side projections),
  a camera-linked axis compass, an on-screen guidance arrow with key hints,
  a dashed head→food tether line, and a live "cells away" readout
- **Speed control** — `-` slows down, `=` speeds up; eating also accelerates
- Pause anytime and keep orbiting the frozen cube to plan your route
- Smooth interpolated movement and 90° turn animations, particles,
  procedurally synthesized sound effects (no asset files),
  persistent best score

## Screenshots

| Modern tube skin | AI autopilot, 94 segments |
|---|---|
| ![gameplay](docs/gameplay.png) | ![long snake](docs/snake-long.png) |

![title screen](docs/title.png)

## Controls

| Input | Action |
|---|---|
| `A` / `D` or `←` / `→` | Steer screen-left / screen-right |
| `W` / `S` or `↑` / `↓` | Steer screen-up / screen-down |
| `B` | Toggle AI autopilot |
| `M` | Toggle modern / classic skin |
| `J` / `L` | Rotate the cube |
| `I` / `K` | Tilt the cube |
| `U` / `O` or mouse wheel | Zoom in / out |
| Mouse drag (left or right) | Orbit (alternative) |
| `V` | Toggle first-person / orbit camera |
| `-` / `=` | Slow down / speed up |
| `P` or `Space` | Pause / resume |
| `R` | Restart |
| `Space` / `Enter` | Start / play again |

## Download

Grab the prebuilt binary from
[Releases](../../releases) (`snake3d-macos-arm64.zip`, macOS Apple Silicon).
The binary is self-contained (raylib statically linked, system fonts only).

> First launch: macOS Gatekeeper may block an unsigned download —
> right-click the app and choose **Open**, or run
> `xattr -d com.apple.quarantine snake3d`.

## Build from source

Requires the [Odin compiler](https://odin-lang.org/) (ships with `vendor:raylib`):

```bash
odin build . -out:snake3d -o:speed
./snake3d
```

Single file: `main.odin`, no other dependencies.
