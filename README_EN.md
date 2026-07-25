# 🐍 Shinake

> **食（shi）× Snake × Shine** — the AI flies the snake, you play food god.
> Say one word, invent a dish, watch what it does to the snake.

[![Release](https://img.shields.io/github/v/release/vajraimb/Shinake?color=brightgreen)](../../releases)
[![License](https://img.shields.io/github/license/vajraimb/Shinake)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-black)](/)
[![Built with](https://img.shields.io/badge/built%20with-Odin%20%2B%20raylib-blue)](https://odin-lang.org/)
[![Stars](https://img.shields.io/github/stars/vajraimb/Shinake?style=social)](../../stargazers)

[简体中文](README.md) | **English**

![Feeding Lab demo](docs/feeding.webp)

*A scripted tasting menu: apple + star → chili speed rage → grenade blows
the tail off → poop & poison mushroom (the snake remembers those two —
and refuses them forever).*

## 🎮 Up and running in 30 seconds

1. Grab `Shinake-macos-arm64.zip` from [Releases](../../releases) and unzip
   (first launch: right-click → **Open**, or
   `xattr -d com.apple.quarantine shinake`)
2. Press `F` on the title screen to enter the **Feeding Lab**
3. Press `T`, type any word — "durian", say — and hit Enter

Watch the AI snake lunge for your creation. Press `E` for the **Creator
Workshop**, or `B` to watch the AI play by itself.

## ✨ Why you'll get hooked

- 🔄 **Roles reversed** — you're not driving this time. The AI flies;
  you invent the food. Every word becomes a unique recipe with color,
  shape, rarity, and effects
- 🕹️ **The original hardcore challenge** — classic mode is fully intact:
  hit Enter on the title screen and pilot the six-way snake yourself.
  Sounds easy — it really isn't. Press `B` anytime to let the AI take
  over (or show you how it's done)
- 🗣️ **Create with one sentence** — tell the workshop "rocket chili" or
  "a hen that lays eggs", and the AI drafts the whole package: name,
  color, and a scripted "rage for 4s, then explode and chop the tail"
- 🧬 **11 effect primitives, freely orchestrated** — egg-laying, shield,
  head-tail reverse, score multiplier… compose them with
  delay / repeat / chance. Your killer combo can be **saved as your own
  primitive** that future AI designs will reference
- 🧊 **A true-3D snake** — no floor, no gravity, six directions inside a
  12³ cube. Press `B` and watch the AI paint with a 90-segment body
- 📮 **Viral share codes** — one keystroke (`C`) copies your creation;
  a friend pastes it to play. Your **creator byline** travels inside
- 🎓 **Hands-on tutorial** — first launch walks you through 8 steps of
  food-god school; press `H` anytime to retake it, `Esc` to skip
- 📺 **Attract mode** — idle on the title screen for 30 s and the AI
  snake starts its own demo reel; any key takes over
- 📊 **Battle-report card** — auto-generated on death / press `G` for an
  800×450 card (weird menu + rank badge); the text version copies with
  one keystroke, repo link included
- 🧱 **Obstacle maps** — 5 built-ins: Void / Pillar Forest / Cross
  Corridors / Hive / Random Cave; press `N` on the title screen to cycle.
  AI pathfinding, food spawning and the minimap are all wall-aware

![Obstacle map · the Hive](docs/map.png)

*The Hive map: 23 solid 2×2×2 blocks scattered through the cube; the AI
autopilot threads the maze while the tri-view minimap tracks every wall.*

![Attract mode](docs/attract.webp)

*This attract loop was recorded fully autonomously with `SNAKE_RECORD` +
`make_demo.py` (241-frame animated WebP, under 0.5 MB).*

![Battle-report card](docs/report.png)

*Auto-generated on death in both manual classic and the Feeding Lab — and
press `G` anytime mid-feeding too: an 800×450 card saved next to the binary,
`C` copies the text version.*

| Workshop · manual design | Workshop · AI blueprint |
| :---: | :---: |
| ![workshop](docs/workshop.png) | ![workshop blueprint](docs/workshop-blueprint.png) |

## 🗺️ Roadmap

**✅ Already served**

- True-3D six-way flight, panoramic orbit + first-person cameras
- AI autopilot: BFS pathfinding + survival simulation, auto-restart
- Feeding Lab: AI flies, you invent — 8 presets, free-form words,
  and a snake that learns to refuse your poisons
- Live LLM recipes (works with Kimi / OpenAI / Ollama; fully offline
  without a key)
- Creator Workshop: sliders + natural-language ideas → effect
  blueprints (11 primitives + timing flow)
- User macros (your own primitives), creator byline, share codes,
  64-slot local library

**🚧 Now cooking**

- **Fully open creation** — script-level new primitives (macros are v0;
  the registry interface is ready)
- **Food Market** — publish / rank / download recipes; share codes are
  the prelude
- ✅ **Obstacle maps** (v3.0) → 🚧 **Map share codes & map library** (v3.1)
  → 🚧 **Map editor** (v3.2) → 💭 **Maps you eat into being**
  (blueprint `spawn_obstacle`, v3.3)

**💭 Wild ideas**

- "Nastiest Recipe" weekly challenge — share-code battles: whose dish
  wrecks the AI hardest
- Highlight replays — last 30 s always recording, one-key export
- Achievements — Master Alchemist, Poison Grandmaster, 100-Cast Streak…
- Skin workshop · spectator mode

## 🧪 Technical notes

<details>
<summary><b>AI recipe configuration (optional; fully offline without a key)</b></summary>

New words can be "cooked" live by an LLM (any OpenAI-compatible endpoint):

```bash
export FEED_LLM_API_KEY=sk-...                     # unset = local generation only
export FEED_LLM_BASE_URL=https://api.moonshot.cn/v1  # default
export FEED_LLM_MODEL=kimi-k2-0905-preview           # default
```

Requests go out via `curl` on a worker thread — the game never blocks.
Failures, timeouts (12 s), and bad output all fall back to local recipes.
The workshop's "★ describe an idea" uses the same variables.
</details>

<details>
<summary><b>Share code & blueprint format</b></summary>

- Share code: `SNAKE3D1.` + base64url(JSON). v2 carries name/hue/shape/
  rarity/flavor/effect fields, optional blueprint, optional bundled
  macros, and a creator byline; v1 codes still import fine
- Blueprint primitives: `speed` `growth` `score` `shake` `confuse`
  `flash` `burst` `spawn_food` `shield` `reverse` `score_mult`; flow
  nodes `delay` `repeat` `chance` `use` (macro reference)
- Everything is clamped (growth ±6, score −50~100, confusion ≤6 s,
  ≤32 actions per blueprint…) — no AI answer or shared code can break
  the game's balance
- Local files: `best.txt` high score · `creations.json` library ·
  `macros.json` primitives · `creator.txt` nickname (`SNAKE_CREATOR`
  env takes precedence)
</details>

<details>
<summary><b>Recording the demo reel (SNAKE_RECORD)</b></summary>

Runs the 24 s attract scenario (the same scripted playlist + rotating
captions as the title-screen demo) in a hidden window, capturing an
offscreen frame every 100 ms, then assembles them into an animated WebP
with PIL:

```bash
SNAKE_RECORD=/tmp/shinake_rec ./shinake        # → /tmp/shinake_rec/frames/f0001.png…f0241.png
python3 make_demo.py /tmp/shinake_rec/frames docs/attract.webp --fps 10
```

`make_demo.py`: tunable `--fps 10` `--width 512` `--quality 70`,
plus `--selftest`. The same demo also plays live after 30 s idle on the
title screen; any key exits.
</details>

<details>
<summary><b>Full controls</b></summary>

| Input | Action |
|---|---|
| `A/D/W/S` or arrows | Screen-relative steering |
| `B` | AI autopilot |
| `M` | Modern tube / classic cube skin |
| `V` | First-person / orbit camera |
| `IJKL` / mouse drag | Rotate / orbit the cube, `U`/`O`/wheel zoom |
| `-` / `=` | Slow down / speed up |
| `P` / `Space` | Pause (`Q` back to title while paused) · `R` restart |
| Game-over screen | `Enter` play again · `Esc` back to title (feeding deaths stop here too, report card included) |
| `H` | Tutorial (restart anytime, title or in-game) |
| `N` | Cycle obstacle map (title screen, 5 built-ins) |

Feeding Lab: `T` feed box · `1-8` presets · `⇧1-8` quick-cast creations ·
`E` workshop · `Tab` dex (`↑↓` select, `Enter` cast, `X` delete creation,
`C` copy share code, `E` remix) · `G` battle-report card (auto-generated on
death; `C` copies the text report) · `Cmd+V` paste a share code

Workshop: `↑↓` fields · `←→` adjust · `Enter` edit/confirm · `Esc` close
</details>

<details>
<summary><b>Build from source & self-tests</b></summary>

Requires the [Odin compiler](https://odin-lang.org/) (ships with
`vendor:raylib`):

```bash
odin build . -out:shinake -o:speed
./shinake
```

Single file `main.odin`, no other dependencies. Headless self-tests:
`SNAKE_SELFTEST=1 ./shinake` (39 checks: share codes, blueprint engine,
library, picky-eater regression, tutorial + attract state machines,
battle report, obstacle maps, game-over flow), `SNAKE_LLMTEST=1` (LLM path, with `mock_llm.py`),
`SNAKE_SHOT=1` (offscreen captures), `SNAKE_RECORD=<dir>` (demo-reel
frames), `SNAKE_REPORT=1` (sample battle-report card).
</details>

## 📦 Download

[Releases](../../releases) · `Shinake-macos-arm64.zip` (macOS Apple
Silicon, self-contained: raylib statically linked, system fonts only).

---

*Shinake = 食(shi) + snake + shine. The art of feeding, the glow of the snake.*
