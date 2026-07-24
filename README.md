# 3D Snake (Odin + raylib)

A single-player, true-3D snake game written in **Odin** with **raylib**.
The snake flies through a 12×12×12 cubic lattice in **six directions** —
no gravity, no floor, pure 3D piloting.

![AI autopilot demo](docs/autopilot.gif)

*The built-in AI (press `B`) piloting a 90+ segment snake — BFS pathfinding
with survival lookahead, shown in the modern tube skin.*

## Feeding Lab (投喂实验室)

Press `F` on the title screen: the roles flip — **the AI flies the snake, you
invent the food**. Type any word (`T`) and the game deterministically
generates a food from it: color, shape, spin, rarity, and 1–3 effects
(speed burst, freeze, growth, body chop, score bonus/penalty, dizziness,
explosion…). The AI places it in the cube and hunts it down.

![feeding lab demo](docs/feeding.gif)

*A scripted tasting menu: apple + star → chili speed rage → grenade blows
the tail off → poop & poison mushroom (the snake will remember these).*

- **8 preset foods** on keys `1`–`8`: 苹果, 辣椒 (speed rage), 冰棍 (slow-mo),
  手榴弹 (blows off tail segments), 便便 (score penalty), 毒蘑菇 (dizziness),
  星星 (legendary bonus), 神秘蛋 (random effects every time)
- **Free-form foods** — every word becomes a unique, repeatable recipe;
  rare and legendary rolls get extra effects and a glowing aura
- **The snake learns** — hurt it twice with the same food name and it
  refuses to eat that food ever again (it rots away). Keep inventing!
- **Food dex** (`Tab`) — every kind you've discovered, with its effect tags

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

### Feeding Lab only

| Input | Action |
|---|---|
| `T` | Open the feed box — type any word, Enter to cast it |
| `1` – `8` | Cast a preset food instantly |
| `Tab` | Toggle the food dex (discovered kinds & effects) |

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
