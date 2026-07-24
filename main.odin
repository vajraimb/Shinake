package snake3d

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

GRID_N :: 12          // 12 x 12 x 12 cubic lattice
CELL   :: 1.0

START_INTERVAL :: 0.27   // seconds per move at start
MIN_INTERVAL   :: 0.08   // fastest
SPEED_STEP     :: 0.007  // interval reduction per food

SCREEN_W :: 1600
SCREEN_H :: 900

TAU :: 6.28318530718

// Consistent axis colors used by the compass, minimap and cube edges
AXIS_X :: rl.Color{235,  95,  95, 255}
AXIS_Y :: rl.Color{105, 225, 115, 255}
AXIS_Z :: rl.Color{105, 155, 245, 255}

IV3 :: struct { x, y, z: i32 }

Particle :: struct {
    pos, vel: rl.Vector3,
    life, max_life: f32,
    color: rl.Color,
    size: f32,
}

GameState :: enum { TITLE, PLAYING, PAUSED, GAME_OVER, WIN }

ViewMode :: enum { FIRST, ORBIT }

GameMode :: enum { CLASSIC, FEEDING }

// ---------------------------------------------------------------------------
// Feeding Lab: the AI snake eats whatever the player invents
// ---------------------------------------------------------------------------

FoodShape :: enum { SPHERE, CUBE, CONE, GEM }

FoodKind :: struct {
    name:       string,   // display name (owned clone)
    author:     string,   // 预设 / 本地 / AI / 分享
    flavor:     string,   // short Chinese flavor line (owned clone, may be "")
    hue:        int,      // 0-359, regenerated into `color` via hsv_rgb(hue, 0.72, 1.0)
    color:      rl.Color,
    shape:      FoodShape,
    size:       f32,
    spin:       f32,
    rarity:     int,      // 0 common, 1 rare, 2 legendary
    fx_speed:   f32,      // move-interval multiplier while fx_speed_t > 0
    fx_speed_t: f32,
    fx_growth:  int,      // +/- segments (negative = 炸掉尾巴)
    fx_score:   int,
    fx_shake:   f32,
    fx_tint:    rl.Color, // a > 0 → fullscreen flash
    fx_confuse: f32,      // seconds of AI dizziness
    fx_bursts:  int,      // particle burst count
}

Food :: struct {
    kind: int,      // index into kinds
    pos:  IV3,
    rot:  f32,      // > 0: rotting countdown (snake refuses it)
    spin: f32,      // animation phase
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

state          := GameState.TITLE
game_mode      := GameMode.CLASSIC
autopilot      := false          // B: AI 自动驾驶（BFS 寻路 + 安全模拟）
restart_timer  : f32 = 0         // autopilot 死亡后的自动重开倒计时
snake          : [dynamic]IV3   // index 0 = head
prev_snake     : [dynamic]IV3   // positions before last tick (for smooth anim)
dir            := IV3{1, 0, 0}
head_up        := IV3{0, 1, 0}  // snake's local up (for camera roll)
prev_dir       := IV3{1, 0, 0}
prev_up        := IV3{0, 1, 0}
dir_queue      : [dynamic]IV3   // desired absolute directions (snapped to axes)
pending_growth := 0

view_mode      := ViewMode.ORBIT   // default: panoramic overview of the whole cube
modern_skin    := true             // M: 现代/经典蛇身皮肤切换

food           := IV3{8, 8, 8}
score          := 0
best           := 0
eaten          := 0
started        := false   // snake waits for the player's first steering input
move_timer     : f32 = 0
move_interval  : f32 = START_INTERVAL

particles      : [dynamic]Particle

cam            : rl.Camera3D
cam_yaw        : f32 = -0.8
cam_pitch      : f32 = 0.7
cam_dist       : f32 = 26.0
cam_target     := rl.Vector3{0, 0, 0}

shake_time     : f32 = 0
time_total     : f32 = 0

snd_eat        : rl.Sound
snd_die        : rl.Sound
snd_win        : rl.Sound
audio_ok       := false

// --- Feeding Lab state ---
kinds          : [dynamic]FoodKind
kind_by_name   : map[string]int
foods          : [dynamic]Food
snake_memory   : map[string]int  // 食物名 -> 伤害过蛇的次数（>=2 则免疫）
ai_target      := IV3{-1, -1, -1}
ai_has_target  := false
fx_speed_timer : f32 = 0
fx_speed_mult  : f32 = 1
confuse_timer  : f32 = 0
tint_timer     : f32 = 0
tint_color     := rl.Color{0, 0, 0, 0}
input_open     := false
input_buf      : [512]u8   // long enough to hold a pasted SNAKE3D1. share code
input_len      := 0
dex_open       := false          // Tab: 图鉴面板
dex_sel        := 0              // keyboard selection inside the dex panel
last_cast_kind := -1             // kinds index of the most recently cast food

// --- toast notifications (bottom-center, ~2.5s) ---
toast          : string          // owned clone
toast_t        : f32 = 0

// --- LLM recipe generation (FEED_LLM_* env config) ---
LLM_State :: enum { IDLE, COOKING, READY, FAILED }

llm_enabled    := false
llm_api_key    : string
llm_base_url   : string
llm_model      : string
llm_state      := LLM_State.IDLE // written by the worker under llm_mutex
llm_mutex      : sync.Mutex
llm_recipe     : Recipe          // written by the worker under llm_mutex
llm_word       : string          // HUD copy, owned by the main thread
llm_kind_idx   := -1             // placeholder kind index awaiting the recipe

font_ui        : rl.Font
font_bold      : rl.Font
font_cjk       : rl.Font   // 中文标签专用（Latin 部分仍用 SFNS）
fonts_ok       := false

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

cell_to_world :: proc(c: IV3) -> rl.Vector3 {
    h := f32(GRID_N - 1) * 0.5 * CELL
    return {(f32(c.x) * CELL) - h, (f32(c.y) * CELL) - h, (f32(c.z) * CELL) - h}
}

lerp_v3 :: proc(a, b: rl.Vector3, t: f32) -> rl.Vector3 {
    return a + (b - a) * t
}

cross_v3 :: proc(a, b: rl.Vector3) -> rl.Vector3 {
    return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}
}

norm_v3 :: proc(v: rl.Vector3) -> rl.Vector3 {
    l := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
    if l < 1e-6 do return {0, 0, 0}
    return v / l
}

v3_of :: proc(c: IV3) -> rl.Vector3 {
    return {f32(c.x), f32(c.y), f32(c.z)}
}

cross_i :: proc(a, b: IV3) -> IV3 {
    return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}
}

neg_i :: proc(a: IV3) -> IV3 {
    return {-a.x, -a.y, -a.z}
}

smoothstep :: proc(t: f32) -> f32 {
    x := clamp(t, 0, 1)
    return x * x * (3 - 2 * x)
}

on_snake :: proc(c: IV3) -> bool {
    for s in snake {
        if s == c do return true
    }
    return false
}

// ---------------------------------------------------------------------------
// Sound synthesis (no asset files needed)
// ---------------------------------------------------------------------------

gen_tone :: proc(freq: f32, dur: f32) -> rl.Sound {
    SR :: 22050
    n := int(dur * SR)
    samples := make([]i16, n)
    for i in 0..<n {
        t := f32(i) / SR
        env := 1.0 - t / dur
        env *= env
        v := math.sin(t * freq * TAU) * env * 9000
        samples[i] = i16(v)
    }
    wave := rl.Wave{
        frameCount = u32(n), sampleRate = SR, sampleSize = 16, channels = 1,
        data = raw_data(samples),
    }
    s := rl.LoadSoundFromWave(wave)
    delete(samples)
    return s
}

gen_sweep :: proc(f0, f1: f32, dur: f32) -> rl.Sound {
    SR :: 22050
    n := int(dur * SR)
    samples := make([]i16, n)
    phase: f32 = 0
    for i in 0..<n {
        t := f32(i) / SR
        k := t / dur
        f := f0 + (f1 - f0) * k
        phase += f * TAU / SR
        env := (1.0 - k) * (1.0 - k)
        samples[i] = i16(math.sin(phase) * env * 10000)
    }
    wave := rl.Wave{
        frameCount = u32(n), sampleRate = SR, sampleSize = 16, channels = 1,
        data = raw_data(samples),
    }
    s := rl.LoadSoundFromWave(wave)
    delete(samples)
    return s
}

play :: proc(s: rl.Sound) {
    if audio_ok do rl.PlaySound(s)
}

// ---------------------------------------------------------------------------
// Game logic
// ---------------------------------------------------------------------------

reset_game :: proc() {
    clear(&snake)
    clear(&prev_snake)
    clear(&dir_queue)
    clear(&particles)
    clear(&foods)

    c :: GRID_N / 2
    append(&snake, IV3{c + 1, c, c})
    append(&snake, IV3{c,     c, c})
    append(&snake, IV3{c - 1, c, c})
    for s in snake do append(&prev_snake, s)

    dir = IV3{1, 0, 0}
    head_up = IV3{0, 1, 0}
    prev_dir = dir
    prev_up = head_up
    pending_growth = 0
    view_mode = .ORBIT
    score = 0
    eaten = 0
    move_interval = START_INTERVAL
    move_timer = 0
    shake_time = 0
    fx_speed_timer = 0
    fx_speed_mult = 1
    confuse_timer = 0
    tint_timer = 0
    input_open = false
    input_len = 0
    ai_has_target = false

    if game_mode == .FEEDING {
        // 投喂模式：AI 常驻，自己起跑，等玩家投喂
        autopilot = true
        started = true
        spawn_kind(0) // 先放一个苹果开场
    } else {
        started = false
        spawn_food()
    }
}

spawn_food :: proc() {
    if len(snake) >= GRID_N * GRID_N * GRID_N {
        state = .WIN
        play(snd_win)
        return
    }
    for {
        f := IV3{
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
        }
        // never on the snake, and not too close to the head
        d := abs(f.x - snake[0].x) + abs(f.y - snake[0].y) + abs(f.z - snake[0].z)
        if !on_snake(f) && d >= 4 {
            food = f
            return
        }
    }
}

queue_dir :: proc(d: IV3) {
    if len(dir_queue) >= 3 do return
    last := len(dir_queue) > 0 ? dir_queue[len(dir_queue) - 1] : dir
    if d == last do return
    if d.x == -last.x && d.y == -last.y && d.z == -last.z do return  // no 180° turns
    append(&dir_queue, d)
}

apply_dir :: proc(d: IV3) {
    if d == dir do return
    if d.x == -dir.x && d.y == -dir.y && d.z == -dir.z do return  // no 180° turns
    if d == head_up {
        head_up = neg_i(dir)
    } else if d == neg_i(head_up) {
        head_up = dir
    }
    dir = d
}

step :: proc() {
    // remember previous frame for camera/interpolation smoothing
    prev_dir = dir
    prev_up = head_up

    // autopilot thinks every tick; otherwise apply one queued direction,
    // keeping the up-frame orthonormal
    if autopilot {
        if game_mode == .FEEDING {
            select_target()
            if confuse_timer > 0 && rand.float32() < 0.45 {
                apply_dir(random_safe_dir()) // 眩晕：晕头转向
            } else {
                apply_dir(ai_choose())
            }
        } else {
            ai_target = food
            ai_has_target = true
            apply_dir(ai_choose())
        }
    } else if len(dir_queue) > 0 {
        d := dir_queue[0]
        _ = pop_front(&dir_queue)
        apply_dir(d)
    }

    // remember previous layout for interpolation
    clear(&prev_snake)
    for s in snake do append(&prev_snake, s)

    head := snake[0]
    nh := IV3{head.x + dir.x, head.y + dir.y, head.z + dir.z}

    // boundary collision
    if nh.x < 0 || nh.x >= GRID_N ||
       nh.y < 0 || nh.y >= GRID_N ||
       nh.z < 0 || nh.z >= GRID_N {
        die()
        return
    }
    // self collision (tail cell frees up unless growing)
    body := pending_growth > 0 ? snake[:] : snake[:len(snake) - 1]
    for s in body {
        if s == nh {
            die()
            return
        }
    }

    inject_at(&snake, 0, nh)

    if game_mode == .FEEDING {
        // feeding: eat whatever food sits at the head cell
        for f, i in foods {
            if f.pos == nh {
                eat_food(i)
                break
            }
        }
    } else if nh == food {
        pending_growth += 1
        score += 10
        eaten += 1
        if score > best { best = score; save_best() }
        move_interval = max(MIN_INTERVAL, move_interval - SPEED_STEP)
        burst(cell_to_world(food))
        play(snd_eat)
        spawn_food()
    }

    if pending_growth > 0 {
        pending_growth -= 1
    } else {
        _ = pop(&snake)
    }

    if len(snake) >= GRID_N * GRID_N * GRID_N {
        state = .WIN
        play(snd_win)
    }
}

die :: proc() {
    state = .GAME_OVER
    view_mode = .ORBIT   // pull out to orbit view so the crash site is visible
    shake_time = 0.5
    restart_timer = 1.5
    play(snd_die)
    burst(cell_to_world(snake[0]))
}

// ---------------------------------------------------------------------------
// Autopilot (B): BFS pathfinding to the food with a survival simulation,
// tail-chasing as fallback — the classic snake-AI strategy
// ---------------------------------------------------------------------------

CELLS :: GRID_N * GRID_N * GRID_N
DIRS6 :: [6]IV3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

ai_blocked : [CELLS]bool
ai_dist    : [CELLS]i32
// 安全模拟专用的独立工作区，避免覆盖食物的 BFS 距离场
sim_blocked : [CELLS]bool
sim_dist    : [CELLS]i32

idx3 :: proc(c: IV3) -> int {
    return int(c.x) + GRID_N * (int(c.y) + GRID_N * int(c.z))
}

cell3 :: proc(i: int) -> IV3 {
    x := i % GRID_N
    y := (i / GRID_N) % GRID_N
    z := i / (GRID_N * GRID_N)
    return {i32(x), i32(y), i32(z)}
}

in_bounds :: proc(c: IV3) -> bool {
    return c.x >= 0 && c.x < GRID_N && c.y >= 0 && c.y < GRID_N && c.z >= 0 && c.z < GRID_N
}

// breadth-first distance field from target over cells marked free in blocked
bfs :: proc(target: IV3, dist: ^[CELLS]i32, blocked: ^[CELLS]bool) {
    for i in 0..<CELLS do dist[i] = -1
    if !in_bounds(target) || blocked[idx3(target)] do return

    q: [CELLS]int
    head, tail := 0, 0
    q[tail] = idx3(target)
    tail += 1
    dist[idx3(target)] = 0

    for head < tail {
        cur := q[head]
        head += 1
        c := cell3(cur)
        d := dist[cur]
        for off in DIRS6 {
            n := IV3{c.x + off.x, c.y + off.y, c.z + off.z}
            if !in_bounds(n) do continue
            ni := idx3(n)
            if blocked[ni] || dist[ni] >= 0 do continue
            dist[ni] = d + 1
            q[tail] = ni
            tail += 1
        }
    }
}

mark_body :: proc(body: []IV3, blocked: ^[CELLS]bool) {
    for i in 0..<CELLS do blocked[i] = false
    for s in body do blocked[idx3(s)] = true
    blocked[idx3(body[len(body) - 1])] = false  // tail tip will vacate
    blocked[idx3(body[0])] = false              // head moves out
}

// Take the candidate first move, then walk the target distance field to the
// target while simulating the snake's body; afterwards check the head can
// still reach its own tail (i.e. eating here doesn't trap us).
safe_to_eat :: proc(first: IV3) -> bool {
    sim := make([dynamic]IV3, len(snake))
    defer delete(sim)
    copy(sim[:], snake[:])
    grow := pending_growth

    cur := snake[0]
    steps := 0
    for {
        next := IV3{-1, -1, -1}
        if steps == 0 {
            next = IV3{cur.x + first.x, cur.y + first.y, cur.z + first.z}
            if !in_bounds(next) || ai_dist[idx3(next)] < 0 do return false
        } else {
            dn := ai_dist[idx3(cur)]
            for off in DIRS6 {
                n := IV3{cur.x + off.x, cur.y + off.y, cur.z + off.z}
                if !in_bounds(n) do continue
                if ai_dist[idx3(n)] == dn - 1 {
                    next = n
                    break
                }
            }
            if next == (IV3{-1, -1, -1}) do return false
        }
        cur = next

        inject_at(&sim, 0, cur)
        if cur == ai_target do grow += 1
        if grow > 0 {
            grow -= 1
        } else {
            _ = pop(&sim)
        }

        steps += 1
        if cur == ai_target do break
        if steps > CELLS do return false   // paranoia
    }

    // can the simulated head still reach its own tail?
    mark_body(sim[:], &sim_blocked)
    bfs(sim[len(sim) - 1], &sim_dist, &sim_blocked)
    for off in DIRS6 {
        n := IV3{sim[0].x + off.x, sim[0].y + off.y, sim[0].z + off.z}
        if in_bounds(n) && sim_dist[idx3(n)] >= 0 do return true
    }
    return false
}

ai_choose :: proc() -> IV3 {
    head := snake[0]
    tip := snake[len(snake) - 1]
    found := false
    best_dir := dir
    best_d := i32(1 << 30)

    // 1. shortest safe path to the current target (if any)
    if ai_has_target {
        mark_body(snake[:], &ai_blocked)
        bfs(ai_target, &ai_dist, &ai_blocked)
        for off in DIRS6 {
            n := IV3{head.x + off.x, head.y + off.y, head.z + off.z}
            if !in_bounds(n) || ai_blocked[idx3(n)] do continue
            d := ai_dist[idx3(n)]
            if d >= 0 && d < best_d && safe_to_eat(off) {
                best_d = d
                best_dir = off
                found = true
            }
        }
        if found do return best_dir
    }

    // 2. no safe route (or nothing edible) — chase our own tail to buy time
    mark_body(snake[:], &ai_blocked)
    bfs(tip, &ai_dist, &ai_blocked)
    best_d = 1 << 30
    for off in DIRS6 {
        n := IV3{head.x + off.x, head.y + off.y, head.z + off.z}
        if !in_bounds(n) || ai_blocked[idx3(n)] do continue
        d := ai_dist[idx3(n)]
        if d >= 0 && d < best_d {
            best_d = d
            best_dir = off
            found = true
        }
    }
    if found do return best_dir

    // 3. doomed — pick any non-lethal move
    for off in DIRS6 {
        n := IV3{head.x + off.x, head.y + off.y, head.z + off.z}
        if in_bounds(n) && !ai_blocked[idx3(n)] do return off
    }
    return dir
}

// ---------------------------------------------------------------------------
// Feeding Lab: word -> food generator, effects, snake memory
// ---------------------------------------------------------------------------

// deterministic FNV-1a hash of the word
word_hash :: proc(s: string) -> u32 {
    h: u32 = 2166136261
    for i in 0..<len(s) {
        h ~= u32(s[i])
        h *= 16777619
    }
    return h
}

// xorshift step for stable per-word pseudo-random picks
xnext :: proc(h: ^u32, n: u32) -> u32 {
    h^ ~= h^ << 13
    h^ ~= h^ >> 17
    h^ ~= h^ << 5
    if n == 0 do return 0
    return h^ % n
}

hsv_rgb :: proc(h, s, v: f32) -> rl.Color {
    i := int(h / 60) % 6
    f := h / 60 - math.floor(h / 60)
    p := v * (1 - s)
    q := v * (1 - f * s)
    t := v * (1 - (1 - f) * s)
    r, g, b: f32
    switch i {
    case 0: r, g, b = v, t, p
    case 1: r, g, b = q, v, p
    case 2: r, g, b = p, v, t
    case 3: r, g, b = p, q, v
    case 4: r, g, b = t, p, v
    case:   r, g, b = v, p, q
    }
    return {u8(r * 255), u8(g * 255), u8(b * 255), 255}
}

// generate a FoodKind deterministically from a word (seed 0 = use word hash)
gen_kind :: proc(name: string, seed: u32) -> FoodKind {
    h := seed != 0 ? seed : word_hash(name)
    k := FoodKind{name = name, author = "本地", flavor = ""}
    k.hue = int(xnext(&h, 360))
    k.color = hsv_rgb(f32(k.hue), 0.72, 1.0)
    k.shape = FoodShape(xnext(&h, 4))
    k.size = 0.26 + 0.05 * f32(xnext(&h, 4))
    k.spin = 1.2 + 0.8 * f32(xnext(&h, 4))
    roll := xnext(&h, 100)
    k.rarity = roll < 68 ? 0 : (roll < 93 ? 1 : 2)
    n_fx := 1 + k.rarity // common 1, rare 2, legendary 3
    k.fx_bursts = 1
    picked: [9]bool
    for _ in 0..<n_fx {
        e := int(xnext(&h, 9))
        if picked[e] do continue
        picked[e] = true
        switch e {
        case 0: // 暴走加速
            k.fx_speed = 0.5 + 0.05 * f32(xnext(&h, 3))
            k.fx_speed_t = 3 + f32(xnext(&h, 3))
        case 1: // 冰冻减速
            k.fx_speed = 1.7 + 0.1 * f32(xnext(&h, 3))
            k.fx_speed_t = 3 + f32(xnext(&h, 3))
        case 2: // 大补
            k.fx_growth = 2 + int(xnext(&h, 3))
        case 3: // 炸裂
            k.fx_growth = -(2 + int(xnext(&h, 3)))
            k.fx_shake = 0.5
        case 4: // 高分
            k.fx_score = 20 + 15 * int(xnext(&h, 4))
        case 5: // 恶心
            k.fx_score = -(10 + 10 * int(xnext(&h, 3)))
            k.fx_tint = {120, 80, 30, 90}
        case 6: // 眩晕
            k.fx_confuse = 2 + f32(xnext(&h, 3))
            k.fx_tint = {150, 60, 200, 70}
        case 7: // 烟花
            k.fx_shake = 0.3 + 0.1 * f32(xnext(&h, 4))
            k.fx_bursts = 3
            k.fx_score += 10
        case:   // 平淡的小点心
            k.fx_growth += 1
            k.fx_score += 10
        }
    }
    // never generate a total dud
    if k.fx_growth == 0 && k.fx_score == 0 && k.fx_speed_t == 0 &&
       k.fx_confuse == 0 && k.fx_shake == 0 {
        k.fx_growth = 1
        k.fx_score = 10
    }
    return k
}

kind_harmful :: proc(k: FoodKind) -> bool {
    return k.fx_growth < 0 || k.fx_score < 0 || k.fx_confuse > 0
}

make_presets :: proc() {
    add :: proc(name: string, hue: int, color: rl.Color, shape: FoodShape, size: f32,
                rarity: int, speed: f32, speed_t: f32, growth: int, score: int,
                shake: f32, tint: rl.Color, confuse: f32, bursts: int) {
        append(&kinds, FoodKind{
            name = strings.clone(name), author = "预设", flavor = "", hue = hue,
            color = color, shape = shape, size = size,
            spin = 2.0, rarity = rarity, fx_speed = speed, fx_speed_t = speed_t,
            fx_growth = growth, fx_score = score, fx_shake = shake,
            fx_tint = tint, fx_confuse = confuse, fx_bursts = bursts,
        })
        kind_by_name[kinds[len(kinds) - 1].name] = len(kinds) - 1
    }
    add("苹果",   0,   {230, 60, 60, 255},   .SPHERE, 0.30, 0, 0, 0, 1, 10, 0, {}, 0, 1)
    add("辣椒",   14,  {255, 90, 30, 255},   .CONE,   0.30, 1, 0.5, 5, 1, 20, 0, {255, 120, 30, 60}, 0, 2)
    add("冰棍",   195, {120, 220, 255, 255}, .CUBE,   0.28, 1, 1.7, 4, 1, 15, 0, {120, 200, 255, 60}, 0, 1)
    add("手榴弹", 120, {70, 80, 70, 255},    .SPHERE, 0.30, 1, 0, 0, -4, 0, 0.7, {255, 160, 60, 90}, 0, 4)
    add("便便",   30,  {130, 85, 40, 255},   .GEM,    0.28, 0, 0, 0, -1, -25, 0, {120, 80, 30, 100}, 0, 1)
    add("毒蘑菇", 280, {170, 70, 220, 255},  .CONE,   0.30, 1, 0, 0, 0, 5, 0, {170, 70, 220, 80}, 4, 2)
    add("星星",   50,  {255, 220, 80, 255},  .GEM,    0.30, 2, 0, 0, 2, 80, 0, {255, 220, 80, 60}, 0, 4)
    // "神秘蛋" 由 cast_preset 特判：每次生成随机效果
}

// index of a kind by name, generating (and registering) it on first use
kind_index :: proc(word: string) -> int {
    if idx, ok := kind_by_name[word]; ok do return idx
    k := gen_kind(strings.clone(word), 0)
    append(&kinds, k)
    idx := len(kinds) - 1
    kind_by_name[k.name] = idx
    return idx
}

MYSTERY_NAME :: "神秘蛋"

// spawn a food of the given kind at a random free cell
spawn_kind :: proc(kind_idx: int) {
    for _ in 0..<200 {
        f := IV3{
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
        }
        d := abs(f.x - snake[0].x) + abs(f.y - snake[0].y) + abs(f.z - snake[0].z)
        if on_snake(f) || d < 4 do continue
        occupied := false
        for of in foods do if of.pos == f { occupied = true; break }
        if occupied do continue
        append(&foods, Food{kind = kind_idx, pos = f, spin = rand.float32() * 360})
        return
    }
}

cast_word :: proc(word: string) {
    if len(word) == 0 do return
    if idx, ok := kind_by_name[word]; ok {
        spawn_kind(idx)
        last_cast_kind = idx
        return
    }
    idx := kind_index(word) // placeholder via the local hash generator
    spawn_kind(idx)
    last_cast_kind = idx
    // new word: ask the LLM for a real recipe (worker thread, non-blocking);
    // only one request in flight — extra words keep the local recipe
    if llm_enabled && llm_state == .IDLE {
        llm_start(word, idx)
    }
}

cast_preset :: proc(i: int) {
    if i < 0 || i >= 8 do return
    if i == 7 {
        // 神秘蛋：随机效果，每次都不一样
        h := u32(rand.int_max(1 << 31)) + 1
        k := gen_kind(strings.clone(MYSTERY_NAME), h)
        k.color = hsv_rgb(f32(xnext(&h, 360)), 0.5, 1.0)
        append(&kinds, k)
        spawn_kind(len(kinds) - 1)
        last_cast_kind = len(kinds) - 1
        return
    }
    spawn_kind(i)
    last_cast_kind = i
}

// ---------------------------------------------------------------------------
// Recipes: shared clamping, share codes (SNAKE3D1.*) and LLM generation
// ---------------------------------------------------------------------------

Recipe_FX :: struct {
    speed_mult: f32,
    speed_secs: f32,
    growth:     int,
    score:      int,
    shake:      f32,
    confuse:    f32,
    bursts:     int,
    tint:       Maybe([3]int),
}

Recipe :: struct {
    hue:    int,
    shape:  int,
    rarity: int,
    flavor: string,
    fx:     Recipe_FX,
}

// share code wire format: "SNAKE3D1." + base64url(json.marshal(Share_Recipe))
Share_Recipe :: struct {
    v:      int,
    name:   string,
    hue:    int,
    shape:  int,
    rarity: int,
    flavor: string,
    fx:     Recipe_FX,
}

SHARE_PREFIX :: "SNAKE3D1."

// single source of truth for recipe sanity (LLM results and share imports)
clamp_recipe :: proc(r: ^Recipe) {
    r.hue = r.hue %% 360 // floored: wraps negatives into 0-359
    r.shape  = clamp(r.shape, 0, 3)
    r.rarity = clamp(r.rarity, 0, 2)
    r.fx.speed_mult = clamp(r.fx.speed_mult, 0.45, 2.0)
    if abs(r.fx.speed_mult - 1) < 0.05 do r.fx.speed_secs = 0 // ~1.0 = no speed effect
    r.fx.speed_secs = clamp(r.fx.speed_secs, 0, 8)
    r.fx.growth  = clamp(r.fx.growth, -6, 6)
    r.fx.score   = clamp(r.fx.score, -50, 100)
    r.fx.shake   = clamp(r.fx.shake, 0, 1)
    r.fx.confuse = clamp(r.fx.confuse, 0, 6)
    r.fx.bursts  = clamp(r.fx.bursts, 1, 4)
    // never a total dud (same spirit as gen_kind)
    if r.fx.growth == 0 && r.fx.score == 0 && r.fx.speed_secs == 0 &&
       r.fx.confuse == 0 && r.fx.shake == 0 {
        r.fx.growth = 1
        r.fx.score  = 10
    }
}

// overwrite everything a recipe defines onto a kind (keeps name/size/spin).
// r.flavor must be a persistent owned string (or "").
apply_recipe_to_kind :: proc(k: ^FoodKind, r: Recipe, author: string) {
    k.hue    = r.hue
    k.color  = hsv_rgb(f32(r.hue), 0.72, 1.0)
    k.shape  = FoodShape(r.shape)
    k.rarity = r.rarity
    k.author = author
    k.flavor = r.flavor
    k.fx_speed   = r.fx.speed_mult
    k.fx_speed_t = r.fx.speed_secs
    k.fx_growth  = r.fx.growth
    k.fx_score   = r.fx.score
    k.fx_shake   = r.fx.shake
    k.fx_confuse = r.fx.confuse
    k.fx_bursts  = r.fx.bursts
    k.fx_tint = {}
    if t, ok := r.fx.tint.?; ok {
        k.fx_tint = {u8(clamp(t[0], 0, 255)), u8(clamp(t[1], 0, 255)), u8(clamp(t[2], 0, 255)), 90}
    }
}

set_toast :: proc(s: string) {
    delete(toast)
    toast = strings.clone(s)
    toast_t = 2.5
}

// ---------------------------------------------------------------------------
// Share codes: export a kind as "SNAKE3D1.<base64url(json)>", import it back
// ---------------------------------------------------------------------------

export_share_code :: proc(idx: int, allocator := context.temp_allocator) -> string {
    k := kinds[idx]
    tint: Maybe([3]int)
    if k.fx_tint.a > 0 {
        tint = [3]int{int(k.fx_tint.r), int(k.fx_tint.g), int(k.fx_tint.b)}
    }
    sr := Share_Recipe{
        v = 1, name = k.name, hue = k.hue, shape = int(k.shape),
        rarity = k.rarity, flavor = k.flavor,
        fx = {
            speed_mult = k.fx_speed, speed_secs = k.fx_speed_t,
            growth = k.fx_growth, score = k.fx_score, shake = k.fx_shake,
            confuse = k.fx_confuse, bursts = k.fx_bursts, tint = tint,
        },
    }
    data, merr := json.marshal(sr, allocator = allocator)
    if merr != nil do return ""
    defer delete(data, allocator)
    b64, berr := base64.encode(data, base64.ENC_URL_TABLE, allocator)
    if berr != nil do return ""
    defer delete(b64, allocator)
    // URL-safe alphabet, padding stripped (decode re-adds it)
    return strings.concatenate({SHARE_PREFIX, strings.trim_right(b64, "=")}, allocator)
}

// decode + clamp + register as a NEW kind (author "分享"); returns kinds index.
// Existing kinds are never mutated — live foods reference them — so a name
// clash gets a ~2, ~3, ... suffix until unique.
import_share_code :: proc(text: string) -> (int, bool) {
    payload := strings.trim_space(text)
    if !strings.has_prefix(payload, SHARE_PREFIX) do return -1, false
    payload = payload[len(SHARE_PREFIX):]
    if len(payload) == 0 do return -1, false
    padded := payload
    switch len(payload) % 4 {
    case 1: return -1, false // impossible length for base64
    case 2: padded = strings.concatenate({payload, "=="}, context.temp_allocator)
    case 3: padded = strings.concatenate({payload, "="}, context.temp_allocator)
    }
    data, derr := base64.decode(padded, base64.DEC_URL_TABLE, allocator = context.temp_allocator)
    if derr != nil || len(data) == 0 do return -1, false
    sr: Share_Recipe
    if json.unmarshal(data, &sr, allocator = context.temp_allocator) != nil do return -1, false
    if sr.v != 1 || sr.name == "" do return -1, false

    r := Recipe{hue = sr.hue, shape = sr.shape, rarity = sr.rarity,
                flavor = strings.clone(sr.flavor), fx = sr.fx}
    clamp_recipe(&r)

    name := sr.name
    suffix := 1
    for {
        if _, taken := kind_by_name[name]; !taken do break
        suffix += 1
        name = fmt.tprintf("%s~%d", sr.name, suffix)
    }
    k := gen_kind(strings.clone(name), 0) // base gives persistent name + size/spin
    apply_recipe_to_kind(&k, r, "分享")
    append(&kinds, k)
    idx := len(kinds) - 1
    kind_by_name[k.name] = idx
    return idx, true
}

// ---------------------------------------------------------------------------
// LLM recipe generation: worker thread + curl via a config file, so neither
// the API key nor the word ever appear on the command line.
// ---------------------------------------------------------------------------

LLM_SYSTEM_PROMPT :: `你在为一个3D贪吃蛇游戏设计食物。玩家给出食物名称，你只输出一个JSON对象，不要输出任何其他文字。字段：hue(0-359整数,符合该食物直觉颜色的色相), shape(0球1方块2圆锥3宝石,选最像的), rarity(0常见1稀有2传说,日常食物0,稀奇或离谱的1-2), flavor(不超过16字的中文幽默点评), fx对象:{speed_mult(0.45-2.0,小于1=加速,大于1=减速,1=无速度效果), speed_secs(0-8), growth(-6到6整数,正=长身体,负=炸掉尾巴), score(-50到100整数), shake(0-1,爆炸震屏), confuse(0-6,AI眩晕秒数), bursts(1-4,粒子烟花数), tint(全屏闪光颜色[r,g,b]各0-255,无闪光则null)}。要贴合食物真实特性:辣椒加速,冰棍减速,手榴弹炸尾,便便扣分,毒蘑菇眩晕;普通食物给温和正面效果;有害效果(负growth/负score/confuse大于0)必须有合理理由。`

LLM_Chat_Message :: struct {
    role:    string,
    content: string,
}

LLM_Chat_Request :: struct {
    model:       string,
    temperature: f32,
    messages:    []LLM_Chat_Message,
}

LLM_Resp_Message :: struct { content: string }
LLM_Resp_Choice  :: struct { message: LLM_Resp_Message }
LLM_Response     :: struct { choices: []LLM_Resp_Choice }

LLM_Job :: struct {
    word: string, // heap clone owned by the worker, freed when done
}

// read once at startup: no key = LLM path fully disabled (local hash only)
llm_init_config :: proc() {
    llm_api_key = os.get_env("FEED_LLM_API_KEY", context.allocator)
    if llm_api_key == "" do return
    llm_enabled = true
    llm_base_url = os.get_env("FEED_LLM_BASE_URL", context.allocator)
    if llm_base_url == "" do llm_base_url = "https://api.moonshot.cn/v1"
    llm_model = os.get_env("FEED_LLM_MODEL", context.allocator)
    if llm_model == "" do llm_model = "kimi-k2-0905-preview"
}

llm_start :: proc(word: string, kind_idx: int) {
    job := new(LLM_Job)
    job.word = strings.clone(word)
    sync.mutex_lock(&llm_mutex)
    llm_state = .COOKING
    sync.mutex_unlock(&llm_mutex)
    llm_kind_idx = kind_idx
    llm_word = strings.clone(word)
    // nil init_context: the worker gets its own default context (own temp
    // allocator); self_cleanup frees the Thread struct on exit
    if thread.create_and_start_with_data(job, llm_worker, nil, .Normal, true) == nil {
        llm_state = .IDLE // spawn failed: stay fully local
        llm_kind_idx = -1
        delete(llm_word)
        llm_word = ""
        delete(job.word)
        free(job)
    }
}

llm_worker :: proc(data: rawptr) {
    // NOTE: runs off the main thread — never call raylib here
    job := cast(^LLM_Job)data
    recipe: Recipe
    ok := false
    defer {
        sync.mutex_lock(&llm_mutex)
        if ok do llm_recipe = recipe
        llm_state = ok ? LLM_State.READY : LLM_State.FAILED
        sync.mutex_unlock(&llm_mutex)
        delete(job.word)
        free(job)
    }

    dir, terr := os.temp_dir(context.allocator)
    if terr != nil do return
    defer delete(dir, context.allocator)
    pid := os.get_pid()
    cfg_path  := fmt.aprintf("%s/snake3d_llm_%d.cfg", dir, pid, allocator = context.allocator)
    req_path  := fmt.aprintf("%s/snake3d_llm_%d_req.json", dir, pid, allocator = context.allocator)
    resp_path := fmt.aprintf("%s/snake3d_llm_%d_resp.json", dir, pid, allocator = context.allocator)
    defer delete(cfg_path, context.allocator)
    defer delete(req_path, context.allocator)
    defer delete(resp_path, context.allocator)
    defer {
        _ = os.remove(cfg_path)
        _ = os.remove(req_path)
        _ = os.remove(resp_path)
    }

    // request body — json.marshal handles all escaping of prompt and word
    req := LLM_Chat_Request{
        model = llm_model, temperature = 0.9,
        messages = {
            {role = "system", content = LLM_SYSTEM_PROMPT},
            {role = "user",   content = job.word},
        },
    }
    body, merr := json.marshal(req, allocator = context.allocator)
    if merr != nil do return
    defer delete(body, context.allocator)
    if os.write_entire_file(req_path, body) != nil do return

    // curl -K config: the API key lives here, never in argv
    cfg := fmt.aprintf(
        "url = \"%s/chat/completions\"\n" +
        "header = \"Authorization: Bearer %s\"\n" +
        "header = \"Content-Type: application/json\"\n" +
        "data = \"@%s\"\n" +
        "output = \"%s\"\n" +
        "max-time = 12\n" +
        "silent\n" +
        "show-error\n",
        llm_base_url, llm_api_key, req_path, resp_path, allocator = context.allocator)
    defer delete(cfg, context.allocator)
    if os.write_entire_file(cfg_path, cfg) != nil do return

    desc: os.Process_Desc
    desc.command = {"curl", "-K", cfg_path}
    child, perr := os.process_start(desc)
    if perr != nil do return
    pstate, werr := os.process_wait(child)
    if werr != nil || !pstate.exited || pstate.exit_code != 0 do return

    resp, rerr := os.read_entire_file(resp_path, context.allocator)
    if rerr != nil do return
    defer delete(resp, context.allocator)

    // outer envelope: {"choices":[{"message":{"content":"..."}}]}
    // unmarshal allocations (outer + recipe strings) intentionally persist:
    // recipe.flavor is handed to kinds[] on success, and at most one request
    // is ever in flight, so this stays a few KB per cooked word.
    outer: LLM_Response
    if json.unmarshal(resp, &outer, allocator = context.allocator) != nil do return
    if len(outer.choices) == 0 do return
    content := strip_json_fences(outer.choices[0].message.content)
    if len(content) == 0 do return
    if json.unmarshal(transmute([]u8)content, &recipe, allocator = context.allocator) != nil do return
    ok = true
}

// strip an optional ```json ... ``` fence the model may wrap the object in
strip_json_fences :: proc(s: string) -> string {
    t := strings.trim_space(s)
    if strings.has_prefix(t, "```") {
        i := strings.index_byte(t, '\n')
        if i < 0 do return ""
        t = strings.trim_space(t[i + 1:])
        if strings.has_suffix(t, "```") do t = t[:len(t) - 3]
        t = strings.trim_space(t)
    }
    return t
}

// main thread, every frame: pick up the worker's result and apply it onto the
// placeholder kind (gen_kind output stays intact on failure)
llm_poll :: proc() {
    if llm_state == .IDLE || llm_state == .COOKING do return
    sync.mutex_lock(&llm_mutex)
    st := llm_state
    r := llm_recipe
    if st != .COOKING do llm_state = .IDLE
    sync.mutex_unlock(&llm_mutex)

    idx := llm_kind_idx
    if st == .READY && idx >= 0 && idx < len(kinds) {
        clamp_recipe(&r)
        apply_recipe_to_kind(&kinds[idx], r, "AI")
        set_toast(fmt.tprintf("AI 烹饪完成: %s", kinds[idx].name))
    } else if st == .FAILED {
        set_toast("AI 烹饪失败，已使用本地配方")
    }
    if llm_word != "" {
        delete(llm_word)
        llm_word = ""
    }
    llm_kind_idx = -1
}

// SNAKE_SELFTEST=1: headless share-code roundtrip (runs before raylib init)
self_test :: proc() -> bool {
    orig := FoodKind{
        name = strings.clone("自测辣翅"), author = "本地", flavor = strings.clone("辣到灵魂出窍"),
        hue = 14, color = hsv_rgb(14, 0.72, 1.0), shape = .CONE,
        size = 0.30, spin = 2.0, rarity = 1,
        fx_speed = 0.5, fx_speed_t = 5, fx_growth = 2, fx_score = 25,
        fx_shake = 0.3, fx_tint = {255, 120, 30, 90}, fx_confuse = 0, fx_bursts = 2,
    }
    append(&kinds, orig)
    kind_by_name[orig.name] = 0

    code := export_share_code(0, context.allocator)
    fmt.println("share code:", code)
    idx, ok := import_share_code(code)
    if !ok {
        fmt.println("SELFTEST FAIL: import rejected the exported code")
        return false
    }
    k := kinds[idx]
    checks := [?]struct{field: string, pass: bool}{
        {"name",    k.name == "自测辣翅~2"}, // orig is registered, so the clone is suffixed
        {"author",  k.author == "分享"},
        {"flavor",  k.flavor == orig.flavor},
        {"hue",     k.hue == orig.hue},
        {"color",   k.color == hsv_rgb(14, 0.72, 1.0)},
        {"shape",   k.shape == orig.shape},
        {"rarity",  k.rarity == orig.rarity},
        {"speed",   k.fx_speed == orig.fx_speed},
        {"speed_t", k.fx_speed_t == orig.fx_speed_t},
        {"growth",  k.fx_growth == orig.fx_growth},
        {"score",   k.fx_score == orig.fx_score},
        {"shake",   k.fx_shake == orig.fx_shake},
        {"confuse", k.fx_confuse == orig.fx_confuse},
        {"bursts",  k.fx_bursts == orig.fx_bursts},
        {"tint",    k.fx_tint == rl.Color{255, 120, 30, 90}},
    }
    all := true
    for c in checks {
        if !c.pass {
            fmt.println("SELFTEST FAIL: field", c.field, "mismatch")
            all = false
        }
    }
    fmt.println("roundtrip:", all ? "PASS" : "FAIL")
    if !all do return false

    // case 2: no tint → tint must come back absent (alpha 0)
    plain := FoodKind{
        name = strings.clone("plain"), author = "本地", flavor = "",
        hue = 200, color = hsv_rgb(200, 0.72, 1.0), shape = .SPHERE,
        rarity = 0, fx_growth = 1, fx_score = 10, fx_bursts = 1,
    }
    append(&kinds, plain)
    kind_by_name[plain.name] = len(kinds) - 1
    code2 := export_share_code(len(kinds) - 1, context.allocator)
    idx2, ok2 := import_share_code(code2)
    if !ok2 || kinds[idx2].fx_tint.a != 0 {
        fmt.println("SELFTEST FAIL: null-tint roundtrip")
        return false
    }

    // case 3: out-of-range wire values must be clamped
    extreme := Share_Recipe{
        v = 1, name = "extreme", hue = 725, shape = 9, rarity = 7, flavor = "",
        fx = {speed_mult = 9.9, speed_secs = 99, growth = 99, score = -999,
              shake = 5, confuse = 42, bursts = 0,
              tint = [3]int{999, -5, 12}},
    }
    raw, _ := json.marshal(extreme, allocator = context.temp_allocator)
    b64, _ := base64.encode(raw, base64.ENC_URL_TABLE, context.temp_allocator)
    code3 := strings.concatenate({SHARE_PREFIX, strings.trim_right(b64, "=")}, context.temp_allocator)
    idx3, ok3 := import_share_code(code3)
    if !ok3 {
        fmt.println("SELFTEST FAIL: extreme recipe rejected")
        return false
    }
    k3 := kinds[idx3]
    clamped := k3.hue == 5 && k3.shape == .GEM && k3.rarity == 2 &&
        k3.fx_speed == 2.0 && k3.fx_speed_t == 8 && k3.fx_growth == 6 &&
        k3.fx_score == -50 && k3.fx_shake == 1 && k3.fx_confuse == 6 &&
        k3.fx_bursts == 1 && k3.fx_tint == rl.Color{255, 0, 12, 90}
    if !clamped {
        fmt.println("SELFTEST FAIL: clamping mismatch:", k3)
        return false
    }

    // case 4: garbage codes must be rejected
    bads := [?]string{
        "SNAKE3D1.not*valid*base64",
        "SNAKE3D1.aGVsbG8",          // valid base64, not JSON
        "SNAKE3D1.",
        "SNAKE3D1.eyJ2IjoyfQ",       // {"v":2} wrong version
    }
    for bad in bads {
        if _, ok4 := import_share_code(bad); ok4 {
            fmt.println("SELFTEST FAIL: bad code accepted:", bad)
            return false
        }
    }

    fmt.println("roundtrip+clamp+reject: PASS")
    return true
}

// SNAKE_LLMTEST=1: headless end-to-end test of the LLM worker (curl + parse).
// Needs FEED_LLM_API_KEY; point FEED_LLM_BASE_URL at a mock to test offline.
llm_test :: proc() -> bool {
    llm_init_config()
    if !llm_enabled {
        fmt.println("LLMTEST SKIP: FEED_LLM_API_KEY not set")
        return false
    }
    idx := kind_index("榴莲")
    llm_start("榴莲", idx)
    for i := 0; i < 600 && llm_state == .COOKING; i += 1 {
        time.sleep(50 * time.Millisecond)
    }
    if llm_state == .COOKING {
        fmt.println("LLMTEST FAIL: worker timed out")
        return false
    }
    llm_poll()
    k := kinds[idx]
    fmt.println("word:  榴莲")
    fmt.printf("kind:  author=%s hue=%d shape=%v rarity=%d flavor=%s\n",
        k.author, k.hue, k.shape, k.rarity, k.flavor)
    fmt.printf("fx:    speed=%.2f/%.1fs growth=%d score=%d shake=%.2f confuse=%.1f bursts=%d tint=%v\n",
        k.fx_speed, k.fx_speed_t, k.fx_growth, k.fx_score, k.fx_shake,
        k.fx_confuse, k.fx_bursts, k.fx_tint)
    ok := k.author == "AI"
    fmt.println("llm roundtrip:", ok ? "PASS" : "FAIL (fell back to local recipe)")
    return ok
}

// nearest food the snake is willing to eat (not rotting, not immune-refused)
select_target :: proc() {
    ai_has_target = false
    best_d := i32(1 << 30)
    for f in foods {
        k := kinds[f.kind]
        if f.rot > 0 do continue
        if kind_harmful(k) && snake_memory[k.name] >= 2 do continue // 已免疫
        d := abs(f.pos.x - snake[0].x) + abs(f.pos.y - snake[0].y) + abs(f.pos.z - snake[0].z)
        if d < best_d {
            best_d = d
            ai_target = f.pos
            ai_has_target = true
        }
    }
}

// mark foods the snake now refuses as rotting; remove fully rotten ones
update_food_rot :: proc(dt: f32) {
    for i := len(foods) - 1; i >= 0; i -= 1 {
        f := &foods[i]
        k := kinds[f.kind]
        if f.rot == 0 && kind_harmful(k) && snake_memory[k.name] >= 2 {
            f.rot = 10 // 蛇不肯吃，开始腐烂
        }
        if f.rot > 0 {
            f.rot -= dt
            if f.rot <= 0 {
                burst_col(cell_to_world(f.pos), {120, 90, 50, 255}, 10)
                ordered_remove(&foods, i)
            }
        }
    }
}

eat_food :: proc(i: int) {
    f := foods[i]
    k := kinds[f.kind]
    score = max(0, score + k.fx_score)
    eaten += 1
    if k.fx_growth > 0 {
        pending_growth += k.fx_growth
    } else if k.fx_growth < 0 {
        // 炸掉尾巴，太短就炸死了
        if len(snake) - 2 < -k.fx_growth {
            die()
            ordered_remove(&foods, i)
            return
        }
        for _ in 0..<-k.fx_growth do _ = pop(&snake)
    }
    if k.fx_speed_t > 0 {
        fx_speed_timer = k.fx_speed_t
        fx_speed_mult = k.fx_speed
    }
    shake_time = max(shake_time, k.fx_shake)
    if k.fx_tint.a > 0 {
        tint_timer = 0.7
        tint_color = k.fx_tint
    }
    confuse_timer = max(confuse_timer, k.fx_confuse)
    if kind_harmful(k) {
        snake_memory[k.name] += 1 // 蛇会记住这次伤害
    }
    if k.flavor != "" {
        set_toast(fmt.tprintf("AI 点评: %s", k.flavor))
    }
    for _ in 0..<max(k.fx_bursts, 1) do burst_col(cell_to_world(f.pos), k.color, 24)
    if audio_ok {
        rl.SetSoundPitch(snd_eat, 0.8 + 0.2 * f32(k.rarity) + rand.float32() * 0.1)
        play(snd_eat)
    }
    ordered_remove(&foods, i)
}

// confusion move: any direction that doesn't immediately kill us
random_safe_dir :: proc() -> IV3 {
    head := snake[0]
    dirs := DIRS6
    start := rand.int_max(6)
    for j in 0..<6 {
        off := dirs[(start + j) % 6]
        if off.x == -dir.x && off.y == -dir.y && off.z == -dir.z do continue
        n := IV3{head.x + off.x, head.y + off.y, head.z + off.z}
        if !in_bounds(n) do continue
        hit := false
        for s in snake[:len(snake) - 1] do if s == n { hit = true; break }
        if !hit do return off
    }
    return dir
}

burst_col :: proc(p: rl.Vector3, col: rl.Color, n: int) {
    for _ in 0..<n {
        a := rand.float32() * TAU
        b := rand.float32() * TAU
        sp := 2 + rand.float32() * 5
        v := rl.Vector3{
            math.cos(a) * math.sin(b) * sp,
            math.cos(b) * sp,
            math.sin(a) * math.sin(b) * sp,
        }
        life := 0.5 + rand.float32() * 0.4
        jitter := 0.75 + rand.float32() * 0.45
        append(&particles, Particle{
            pos = p, vel = v, life = life, max_life = life,
            color = {u8(f32(col.r) * jitter), u8(f32(col.g) * jitter), u8(f32(col.b) * jitter), 255},
            size = 0.08 + rand.float32() * 0.1,
        })
    }
}

burst :: proc(p: rl.Vector3) {
    for _ in 0..<24 {
        a := rand.float32() * TAU
        b := rand.float32() * TAU
        sp := 2 + rand.float32() * 5
        v := rl.Vector3{
            math.cos(a) * math.sin(b) * sp,
            math.cos(b) * sp,
            math.sin(a) * math.sin(b) * sp,
        }
        life := 0.5 + rand.float32() * 0.4
        append(&particles, Particle{
            pos = p, vel = v, life = life, max_life = life,
            color = rand.float32() < 0.5 ? rl.LIME : rl.GREEN,
            size = 0.08 + rand.float32() * 0.1,
        })
    }
}

update_particles :: proc(dt: f32) {
    h := f32(GRID_N) * CELL * 0.5
    for i := len(particles) - 1; i >= 0; i -= 1 {
        p := &particles[i]
        p.life -= dt
        if p.life <= 0 {
            unordered_remove(&particles, i)
            continue
        }
        p.vel.y -= 14 * dt
        p.pos += p.vel * dt
        if p.pos.y < -h + 0.05 { p.pos.y = -h + 0.05; p.vel.y *= -0.4 }
    }
}

// Snap a world-space vector to the nearest of the 6 grid axes.
snap_axis :: proc(v: rl.Vector3) -> IV3 {
    ax, ay, az := abs(v.x), abs(v.y), abs(v.z)
    if ax >= ay && ax >= az do return {v.x > 0 ? 1 : -1, 0, 0}
    if ay >= az            do return {0, v.y > 0 ? 1 : -1, 0}
    return {0, 0, v.z > 0 ? 1 : -1}
}

// Steering:
// - orbit view: SCREEN-relative (A always goes screen-left, W screen-up, ...)
// - first-person: snake-frame relative (turn left/right, pitch up/down)
handle_input :: proc() {
    // (!input_open: V also pastes into the feed box — don't flip the camera then)
    if rl.IsKeyPressed(.V) && !input_open {
        view_mode = view_mode == .FIRST ? .ORBIT : .FIRST
    }
    // M: modern / classic snake skin
    if rl.IsKeyPressed(.M) do modern_skin = !modern_skin

    if game_mode == .FEEDING {
        // 投喂模式：蛇永远是 AI 操控，玩家只管投喂
        if rl.IsKeyPressed(.TAB) {
            dex_open = !dex_open
            dex_sel = 0
        }
        if rl.IsKeyPressed(.T) {
            input_open = true
            input_len = 0
        }
        if !input_open {
            if rl.IsKeyPressed(.ONE)   do cast_preset(0)
            if rl.IsKeyPressed(.TWO)   do cast_preset(1)
            if rl.IsKeyPressed(.THREE) do cast_preset(2)
            if rl.IsKeyPressed(.FOUR)  do cast_preset(3)
            if rl.IsKeyPressed(.FIVE)  do cast_preset(4)
            if rl.IsKeyPressed(.SIX)   do cast_preset(5)
            if rl.IsKeyPressed(.SEVEN) do cast_preset(6)
            if rl.IsKeyPressed(.EIGHT) do cast_preset(7)
            if dex_open {
                rows := dex_visible_rows()
                if rl.IsKeyPressed(.UP)   do dex_sel = max(0, dex_sel - 1)
                if rl.IsKeyPressed(.DOWN) && rows > 0 do dex_sel = min(rows - 1, dex_sel + 1)
                if rl.IsKeyPressed(.C) && rows > 0 {
                    copy_share_code(min(dex_sel, rows - 1))
                }
            } else if rl.IsKeyPressed(.C) && last_cast_kind >= 0 && last_cast_kind < len(kinds) {
                copy_share_code(last_cast_kind)
            }
        }
        return
    }

    // B: toggle AI autopilot
    if rl.IsKeyPressed(.B) {
        autopilot = !autopilot
        if autopilot do clear(&dir_queue) // AI 接管前清空玩家排队的方向
    }
    if autopilot do return // AI 操控时忽略方向键

    go_left  := rl.IsKeyPressed(.A) || rl.IsKeyPressed(.LEFT)
    go_right := rl.IsKeyPressed(.D) || rl.IsKeyPressed(.RIGHT)
    go_up    := rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP)
    go_down  := rl.IsKeyPressed(.S) || rl.IsKeyPressed(.DOWN)

    if view_mode == .FIRST {
        if go_left  do queue_dir(cross_i(head_up, dir))
        if go_right do queue_dir(cross_i(dir, head_up))
        if go_up    do queue_dir(head_up)
        if go_down  do queue_dir(neg_i(head_up))
    } else {
        f := norm_v3(cam.target - cam.position)
        r := norm_v3(cross_v3(f, {0, 1, 0}))
        u := cross_v3(r, f)
        if go_left  do queue_dir(snap_axis({-r.x, -r.y, -r.z}))
        if go_right do queue_dir(snap_axis(r))
        if go_up    do queue_dir(snap_axis(u))
        if go_down  do queue_dir(snap_axis({-u.x, -u.y, -u.z}))
    }
}

// free-text food input (feeding mode): type a word, Enter to cast it
handle_text_input :: proc() {
    if !input_open do return
    for {
        c := rl.GetCharPressed()
        if c == 0 do break
        if c >= 32 && c < 127 && input_len < len(input_buf) - 1 {
            input_buf[input_len] = u8(c)
            input_len += 1
        }
    }
    // Cmd+V: paste (share codes are long, typing them is not realistic)
    if rl.IsKeyPressed(.V) && (rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)) {
        clip := rl.GetClipboardText()
        if clip != nil {
            p := transmute([^]u8)clip
            for i := 0; p[i] != 0 && input_len < len(input_buf) - 1; i += 1 {
                if p[i] >= 32 && p[i] < 127 { // same ASCII-only filter as typing
                    input_buf[input_len] = p[i]
                    input_len += 1
                }
            }
        }
    }
    if rl.IsKeyPressed(.BACKSPACE) && input_len > 0 do input_len -= 1
    if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
        if input_len > 0 {
            text := string(input_buf[:input_len])
            if strings.has_prefix(text, SHARE_PREFIX) {
                // importing a recipe shared by another player
                idx, ok := import_share_code(text)
                if ok {
                    spawn_kind(idx)
                    last_cast_kind = idx
                    set_toast(fmt.tprintf("已投喂: %s", kinds[idx].name))
                } else {
                    set_toast("分享码无效")
                }
            } else {
                cast_word(text)
            }
        }
        input_open = false
        input_len = 0
    }
    if rl.IsKeyPressed(.ESCAPE) {
        input_open = false
        input_len = 0
    }
}

// C: copy a kind's share code to the clipboard
copy_share_code :: proc(idx: int) {
    code := export_share_code(idx)
    if code == "" do return
    rl.SetClipboardText(fmt.ctprintf("%s", code))
    set_toast(fmt.tprintf("分享码已复制: %s", kinds[idx].name))
}

// ---------------------------------------------------------------------------
// Best score persistence
// ---------------------------------------------------------------------------

BEST_FILE :: "best.txt"

load_best :: proc() {
    data, err := os.read_entire_file(BEST_FILE, context.allocator)
    if err == nil {
        defer delete(data)
        v, ok := strconv.parse_int(string(data))
        if ok do best = v
    }
}

save_best :: proc() {
    _ = os.write_entire_file(BEST_FILE, fmt.tprint(best))
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

half_extent :: proc() -> f32 {
    return f32(GRID_N) * CELL * 0.5
}

draw_grid_lines :: proc(face: IV3, col: rl.Color) {
    // grid lines on one outer face of the cube; face = unit normal
    h := half_extent()
    N :: GRID_N
    for i in 0..=N {
        t := -h + f32(i) * CELL
        switch {
        case face.x != 0:
            x := face.x > 0 ? h : -h
            rl.DrawLine3D({x, t, -h}, {x, t, h}, col)
            rl.DrawLine3D({x, -h, t}, {x, h, t}, col)
        case face.y != 0:
            y := face.y > 0 ? h : -h
            rl.DrawLine3D({t, y, -h}, {t, y, h}, col)
            rl.DrawLine3D({-h, y, t}, {h, y, t}, col)
        case:
            z := face.z > 0 ? h : -h
            rl.DrawLine3D({t, -h, z}, {t, h, z}, col)
            rl.DrawLine3D({-h, t, z}, {h, t, z}, col)
        }
    }
}

draw_boundaries :: proc() {
    h := half_extent()
    n := f32(GRID_N) * CELL

    // 6 translucent faces; only skip the fill when the camera is OUTSIDE the
    // cube beyond that face (in first-person you're inside: all faces show)
    faces := [?]struct{ c, s: rl.Vector3, skip: bool }{
        {{ h, 0, 0}, {0.06, n, n}, cam.position.x >  h},
        {{-h, 0, 0}, {0.06, n, n}, cam.position.x < -h},
        {{0,  h, 0}, {n, 0.06, n}, cam.position.y >  h},
        {{0, -h, 0}, {n, 0.06, n}, cam.position.y < -h},
        {{0, 0,  h}, {n, n, 0.06}, cam.position.z >  h},
        {{0, 0, -h}, {n, n, 0.06}, cam.position.z < -h},
    }
    fill := rl.Color{80, 110, 190, 22}
    for f in faces {
        if !f.skip do rl.DrawCubeV(f.c, f.s, fill)
    }

    // cube edges, color-coded by axis direction (matches compass & minimap)
    edge_x := rl.Color{AXIS_X.r, AXIS_X.g, AXIS_X.b, 130}
    edge_y := rl.Color{AXIS_Y.r, AXIS_Y.g, AXIS_Y.b, 130}
    edge_z := rl.Color{AXIS_Z.r, AXIS_Z.g, AXIS_Z.b, 130}
    extremes := [2]f32{-h, h}
    for a in extremes {
        for b in extremes {
            rl.DrawLine3D({-h, a, b}, {h, a, b}, edge_x)  // edges parallel to X
            rl.DrawLine3D({a, -h, b}, {a, h, b}, edge_y)  // edges parallel to Y
            rl.DrawLine3D({a, b, -h}, {a, b, h}, edge_z)  // edges parallel to Z
        }
    }

    // lattice lines on ALL six faces — inside the cube you always see the
    // reference grid on the wall ahead of you (lines don't block the view)
    line_col := rl.Color{90, 120, 200, 55}
    draw_grid_lines({1, 0, 0}, line_col)
    draw_grid_lines({-1, 0, 0}, line_col)
    draw_grid_lines({0, 1, 0}, line_col)
    draw_grid_lines({0, -1, 0}, line_col)
    draw_grid_lines({0, 0, 1}, line_col)
    draw_grid_lines({0, 0, -1}, line_col)
}

// Dotted "flight path" ahead of the head: shows where going straight leads,
// colored by distance to the first obstacle (green -> yellow -> red).
draw_path_hint :: proc() {
    if state != .PLAYING && state != .PAUSED do return

    obstacle_dist := 0
    hit_self := false
    found := false
    for i in 1..=GRID_N {
        n := IV3{snake[0].x + dir.x * i32(i), snake[0].y + dir.y * i32(i), snake[0].z + dir.z * i32(i)}
        if n.x < 0 || n.x >= GRID_N || n.y < 0 || n.y >= GRID_N || n.z < 0 || n.z >= GRID_N {
            obstacle_dist = i
            found = true
            break
        }
        if on_snake(n) {
            obstacle_dist = i
            hit_self = true
            found = true
            break
        }
    }
    if !found do obstacle_dist = GRID_N + 1

    col := rl.Color{80, 230, 110, 170}          // safe
    if obstacle_dist <= 4 do col = rl.Color{240, 200, 60, 190}   // caution
    if obstacle_dist <= 2 do col = rl.Color{240, 70, 60, 220}    // danger

    // thin line ahead of the head (a line never balloons in first-person)
    hp := cell_to_world(snake[0])
    fdir := v3_of(dir)
    start := hp + fdir * 0.55
    if obstacle_dist > 1 {
        last := IV3{snake[0].x + dir.x * i32(obstacle_dist - 1),
                    snake[0].y + dir.y * i32(obstacle_dist - 1),
                    snake[0].z + dir.z * i32(obstacle_dist - 1)}
        rl.DrawLine3D(start, cell_to_world(last) + fdir * 0.4, col)
    } else {
        rl.DrawLine3D(start, start + fdir * 0.3, col)
    }
    // tiny waypoint dots only a few cells out, where they stay small on screen
    for i in 3..<obstacle_dist {
        n := IV3{snake[0].x + dir.x * i32(i), snake[0].y + dir.y * i32(i), snake[0].z + dir.z * i32(i)}
        rl.DrawSphereEx(cell_to_world(n), 0.05, 6, 6, col)
    }

    // flashing marker on the obstacle itself
    if found {
        n := IV3{snake[0].x + dir.x * i32(obstacle_dist), snake[0].y + dir.y * i32(obstacle_dist), snake[0].z + dir.z * i32(obstacle_dist)}
        // clamp into the cube for wall hits
        n.x = clamp(n.x, 0, GRID_N - 1)
        n.y = clamp(n.y, 0, GRID_N - 1)
        n.z = clamp(n.z, 0, GRID_N - 1)
        p := cell_to_world(n)
        blink := 0.5 + 0.5 * math.sin(time_total * 8)
        k := f32(0.3) + 0.15 * blink
        mark := hit_self ? rl.Color{255, 60, 60, u8(120 + 100 * blink)} : rl.Color{255, 120, 60, u8(80 + 80 * blink)}
        rl.DrawCubeWires(p, k, k, k, mark)
    }
}

// Dashed tether line from the head straight to the food (3D direction cue)
// where the snake is currently headed: the classic apple, or the AI's pick
nav_target :: proc() -> (IV3, bool) {
    if game_mode == .FEEDING do return ai_target, ai_has_target
    return food, true
}

draw_tether :: proc() {
    if state != .PLAYING && state != .PAUSED do return
    t, ok := nav_target()
    if !ok do return
    a := cell_to_world(snake[0])
    b := cell_to_world(t)
    SEG :: 24
    col := rl.Color{255, 90, 90, 75}
    for i in 0..<SEG {
        if i % 2 == 0 {
            t0 := f32(i) / SEG
            t1 := f32(i + 1) / SEG
            rl.DrawLine3D(lerp_v3(a, b, t0), lerp_v3(a, b, t1), col)
        }
    }
}

draw_food :: proc() {
    bob := math.sin(time_total * 3.2) * 0.08
    p := cell_to_world(food)
    p.y += bob
    rl.DrawSphereEx(p, 0.34, 12, 12, rl.RED)
    rl.DrawSphereEx(p + {-0.09, 0.1, -0.09}, 0.12, 8, 8, rl.Color{255, 130, 130, 255})
    // pulsing wire cube beacon
    k := 0.5 + 0.1 * math.sin(time_total * 4)
    rl.DrawCubeWires(p, k, k, k, rl.Color{255, 90, 90, 160})
    // vertical beam down to the floor for depth perception
    h := half_extent()
    rl.DrawLine3D({p.x, p.y - 0.4, p.z}, {p.x, -h, p.z}, rl.Color{255, 80, 80, 90})
    rl.DrawCubeV({p.x, -h + 0.02, p.z}, {0.3, 0.04, 0.3}, rl.Color{255, 80, 80, 70})
}

// ---------------------------------------------------------------------------
// Feeding Lab rendering
// ---------------------------------------------------------------------------

RARITY_COLORS := [3]rl.Color{
    {190, 195, 210, 255}, // common
    {90, 200, 255, 255},  // rare
    {255, 210, 70, 255},  // legendary
}

draw_foods :: proc() {
    h := half_extent()
    for f in foods {
        k := kinds[f.kind]
        p := cell_to_world(f.pos)
        p.y += math.sin(time_total * 3.2 + f.spin) * 0.07

        s := k.size
        dim: f32 = f.rot > 0 ? 0.45 : 1.0 // 腐烂变暗
        col := rl.Color{u8(f32(k.color.r) * dim), u8(f32(k.color.g) * dim), u8(f32(k.color.b) * dim), 255}

        rlgl.PushMatrix()
        rlgl.Translatef(p.x, p.y, p.z)
        rlgl.Rotatef(f.spin + time_total * 60 * k.spin * 0.5, 0, 1, 0)
        switch k.shape {
        case .SPHERE:
            rl.DrawSphereEx({0, 0, 0}, s, 12, 10, col)
        case .CUBE:
            rl.DrawCubeV({0, 0, 0}, {s * 1.7, s * 1.7, s * 1.7}, col)
        case .CONE:
            rl.DrawCylinderEx({0, -s, 0}, {0, s, 0}, s * 0.75, 0.02, 10, col)
        case .GEM:
            rl.DrawCylinderEx({0, -s, 0}, {0, 0, 0}, s * 0.7, 0.02, 8, col)
            rl.DrawCylinderEx({0, 0, 0}, {0, s, 0}, 0.02, s * 0.7, 8, col)
        }
        rlgl.PopMatrix()

        // 稀有度光环
        if k.rarity > 0 && f.rot <= 0 {
            rc := RARITY_COLORS[k.rarity]
            rl.BeginBlendMode(.ADDITIVE)
            rl.DrawSphereEx(p, s * 1.6 + 0.06 * math.sin(time_total * 4), 10, 8,
                {rc.r, rc.g, rc.b, k.rarity == 2 ? 26 : 14})
            rl.EndBlendMode()
        }
        // 落地参考线（和苹果的落地光束一个道理）
        rl.DrawLine3D({p.x, p.y - s - 0.05, p.z}, {p.x, -h, p.z}, {col.r, col.g, col.b, 60})
    }
}

// 2D labels floating above each food (call after EndMode3D)
draw_food_labels :: proc() {
    if game_mode != .FEEDING || state == .TITLE do return
    for f in foods {
        k := kinds[f.kind]
        p := cell_to_world(f.pos)
        p.y += 0.7
        sp := rl.GetWorldToScreen(p, cam)
        rc := RARITY_COLORS[k.rarity]
        w := measure_text(fmt.ctprintf("%s", k.name), 17, true)
        x := i32(sp.x) - w / 2
        y := i32(sp.y)
        // 底板
        rl.DrawRectangle(x - 7, y - 3, w + 14, 24, {10, 12, 20, 170})
        rl.DrawRectangleLinesEx({f32(x - 7), f32(y - 3), f32(w + 14), 24}, 1,
            {rc.r, rc.g, rc.b, 120})
        name_col := f.rot > 0 ? rl.Color{140, 120, 90, 255} : rc
        draw_text(fmt.ctprintf("%s", k.name), x, y, 17, name_col, true)
        if f.rot > 0 {
            draw_text("腐烂中", x, y + 20, 12, {150, 110, 70, 220})
        }
    }
}

// fullscreen effect flash
draw_tint :: proc() {
    if tint_timer <= 0 do return
    c := tint_color
    c.a = u8(f32(c.a) * clamp(tint_timer / 0.7, 0, 1))
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, c)
}

DEX_ROW_BASE   :: 26
DEX_ROW_FLAVOR :: 14

dex_row_h :: proc(k: FoodKind) -> i32 {
    return DEX_ROW_BASE + (k.flavor != "" ? DEX_ROW_FLAVOR : 0)
}

// how many kinds fit the panel with the current (variable) row heights
dex_visible_rows :: proc() -> int {
    budget := SCREEN_H - 170 - 40 - 60 // panel top, bottom margin, header
    rows := 0
    used := 0
    for rows < len(kinds) {
        used += int(dex_row_h(kinds[rows]))
        if used > budget do break
        rows += 1
    }
    return rows
}

// 图鉴: all food kinds discovered so far (↑/↓ select, C copies the share code)
draw_dex :: proc() {
    if !dex_open do return
    w: i32 = 360
    x := SCREEN_W - w - 20
    y: i32 = 170
    rows := dex_visible_rows()
    total := 0
    for i in 0..<rows do total += int(dex_row_h(kinds[i]))
    h := i32(60 + total)
    rl.DrawRectangle(x, y, w, h, {12, 14, 24, 225})
    rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 1, {120, 128, 150, 180})
    draw_text(fmt.ctprintf("食物图鉴 · 已发现 %d 种", len(kinds)), x + 16, y + 12, 20,
        rl.RAYWHITE, true)

    buf: [192]u8
    sel := min(dex_sel, rows - 1)
    ry := y + 44
    for i in 0..<rows {
        k := kinds[i]
        if i == sel {
            rl.DrawRectangle(x + 6, ry - 4, w - 12, dex_row_h(k), {70, 90, 130, 70})
        }
        rl.DrawCircle(x + 24, ry + 8, 5, k.color)
        // effect tags（中文标签 + ASCII 数值，各自用 bprintf 写入 buf 避免重叠）
        n := 0
        tag :: proc(buf: []u8, n: ^int, s: string) {
            if n^ > 0 do n^ += copy(buf[n^:], " ")
            n^ += copy(buf[n^:], s)
        }
        if k.fx_speed_t > 0 && k.fx_speed < 1 do tag(buf[:], &n, "加速")
        if k.fx_speed_t > 0 && k.fx_speed > 1 do tag(buf[:], &n, "减速")
        if k.fx_growth != 0 {
            w := fmt.bprintf(buf[n:], "%+d节", k.fx_growth)
            n += len(w)
        }
        if k.fx_score != 0 {
            if n > 0 do n += copy(buf[n:], " ")
            w := fmt.bprintf(buf[n:], "%+d分", k.fx_score)
            n += len(w)
        }
        if k.fx_confuse > 0 do tag(buf[:], &n, "眩晕")
        if k.fx_shake > 0.4 do tag(buf[:], &n, "爆炸")
        immune := kind_harmful(k) && snake_memory[k.name] >= 2
        if immune do tag(buf[:], &n, "已免疫")
        buf[n] = 0 // 上一行更长会留下残影，显式截断
        stars := k.rarity == 2 ? "***" : (k.rarity == 1 ? "**" : "*")
        rc := RARITY_COLORS[k.rarity]
        draw_text(fmt.ctprintf("%s", k.name), x + 40, ry, 18, rc, true)
        nw := measure_text(fmt.ctprintf("%s", k.name), 18, true)
        if k.author != "" {
            draw_text(fmt.ctprintf("%s", k.author), x + 46 + nw, ry + 5, 12, {125, 130, 148, 230})
        }
        draw_text(fmt.ctprintf("%s  %s", stars, cstring(raw_data(buf[:]))),
            x + 150, ry + 2, 14, {170, 175, 190, 255})
        if k.flavor != "" {
            draw_text(fmt.ctprintf("%s", k.flavor), x + 40, ry + 22, 13, {150, 152, 168, 225})
        }
        ry += dex_row_h(k)
    }
    if len(kinds) > rows {
        draw_text(fmt.ctprintf("... and %d more", len(kinds) - rows), x + 40, ry, 14,
            {120, 125, 140, 255})
    }
}

draw_input_box :: proc() {
    if !input_open do return
    w: i32 = 560
    h: i32 = 64
    x := (SCREEN_W - w) / 2
    y := SCREEN_H - h - 90
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, {0, 0, 0, 60})
    rl.DrawRectangle(x, y, w, h, {16, 20, 32, 240})
    rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 2, {255, 200, 120, 220})
    draw_text("投喂什么？", x + 18, y + 10, 15, {200, 190, 160, 255})
    // long share codes: show the tail so the pasted code stays verifiable
    typed := string(input_buf[:input_len])
    shown := typed
    if len(shown) > 56 {
        shown = strings.concatenate({"...", shown[len(shown) - 53:]}, context.temp_allocator)
    }
    draw_text(fmt.ctprintf("%s", shown), x + 18, y + 30, 24, rl.RAYWHITE, true)
    if time_total * 2 - math.floor(time_total * 2) < 0.55 {
        w := measure_text(fmt.ctprintf("%s", shown), 24, true)
        draw_text("_", x + 18 + w + 3, y + 30, 24, rl.RAYWHITE, true)
    }
    draw_text("输入食物名，或粘贴 SNAKE3D1. 分享码 · Enter 投放 · Esc 取消", x + 18, y + h + 8, 13, {140, 145, 160, 255})
}

draw_snake :: proc(alpha: f32, hide_head: bool) {
    n := len(snake)
    h := half_extent()

    // floor projection shadows (depth cue)
    for i in 0..<n {
        cur := cell_to_world(snake[i])
        j := min(i, len(prev_snake) - 1)
        p := lerp_v3(cell_to_world(prev_snake[j]), cur, alpha)
        rl.DrawCubeV({p.x, -h + 0.02, p.z}, {0.4, 0.03, 0.4}, rl.Color{80, 220, 100, 26})
    }
    // head height guide (skip in first-person: the camera sits on this line)
    if !hide_head {
        hp := cell_to_world(snake[0])
        if len(prev_snake) > 0 {
            hp = lerp_v3(cell_to_world(prev_snake[0]), hp, alpha)
        }
        rl.DrawLine3D({hp.x, hp.y, hp.z}, {hp.x, -h, hp.z}, rl.Color{200, 255, 200, 36})
    }

    for i := n - 1; i >= 0; i -= 1 {
        if hide_head && i == 0 do break
        cur := cell_to_world(snake[i])
        j := min(i, len(prev_snake) - 1)
        prv := cell_to_world(prev_snake[j])
        p := lerp_v3(prv, cur, alpha)

        // color gradient head -> tail
        t := f32(i) / f32(max(n - 1, 1))
        col := rl.Color{
            u8(60  + t * 20),
            u8(220 - t * 90),
            u8(90  - t * 40),
            255,
        }
        size: f32 = i == 0 ? 0.92 : 0.82 - 0.25 * t
        rl.DrawCubeV(p, {size, size, size}, col)

        if i == 0 {
            // eyes, oriented by the 3D facing direction
            f := rl.Vector3{f32(dir.x), f32(dir.y), f32(dir.z)}
            s := abs(f.y) == 1 ? rl.Vector3{1, 0, 0} : norm_v3(cross_v3(f, {0, 1, 0}))
            u := norm_v3(cross_v3(s, f))
            e1 := p + f * 0.42 + s * 0.2 + u * 0.18
            e2 := p + f * 0.42 - s * 0.2 + u * 0.18
            rl.DrawSphereEx(e1, 0.11, 8, 8, rl.WHITE)
            rl.DrawSphereEx(e2, 0.11, 8, 8, rl.WHITE)
            rl.DrawSphereEx(e1 + f * 0.06, 0.055, 8, 8, rl.BLACK)
            rl.DrawSphereEx(e2 + f * 0.06, 0.055, 8, 8, rl.BLACK)
        }
    }
}

// ---------------------------------------------------------------------------
// Modern skin: glossy capsule-tube body, specular highlights, depth fog, glow
// ---------------------------------------------------------------------------

seg_radius :: proc(i, n: int) -> f32 {
    if i == 0 do return 0.46
    t := f32(i) / f32(max(n - 1, 1))
    return 0.40 * (1 - 0.62 * t)   // taper toward the tail tip
}

seg_color :: proc(i, n: int) -> rl.Color {
    t := f32(i) / f32(max(n - 1, 1))
    // emerald head -> teal -> deep ocean tail, with subtle scale banding
    band: f32 = (i % 4) < 2 ? 1.0 : 0.80
    r := (86  - 61 * t) * band
    g := (245 - 105 * t) * band
    b := (150 + 45 * t) * band
    return {u8(clamp(r, 0, 255)), u8(clamp(g, 0, 255)), u8(clamp(b, 0, 255)), 240}
}

dist_v3 :: proc(a, b: rl.Vector3) -> f32 {
    dx, dy, dz := a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
}

draw_snake_modern :: proc(alpha: f32, hide_head: bool) {
    n := len(snake)
    h := half_extent()
    light := norm_v3(rl.Vector3{0.45, 1.0, 0.3})
    fog_ref := cam_dist * 2.0 + 10

    // interpolated joint positions
    pts := make([]rl.Vector3, n)
    defer delete(pts)
    for i in 0..<n {
        cur := cell_to_world(snake[i])
        j := min(i, len(prev_snake) - 1)
        pts[i] = j >= 0 ? lerp_v3(cell_to_world(prev_snake[j]), cur, alpha) : cur
    }

    // floor projection shadows (depth cue)
    for i in 0..<n {
        p := pts[i]
        r := seg_radius(i, n)
        rl.DrawCubeV({p.x, -h + 0.02, p.z}, {r * 1.7, 0.03, r * 1.7}, rl.Color{60, 200, 130, 20})
    }
    // head height guide (skip in first-person)
    if !hide_head {
        hp := pts[0]
        rl.DrawLine3D({hp.x, hp.y, hp.z}, {hp.x, -h, hp.z}, rl.Color{200, 255, 220, 30})
    }

    // tube body: tapered cylinders + joint spheres + specular glints, tail -> head
    for i := n - 1; i >= 0; i -= 1 {
        if hide_head && i == 0 do break
        r := seg_radius(i, n) * (1 + 0.045 * math.sin(time_total * 3 + f32(i) * 0.5))
        col := seg_color(i, n)
        // manual distance fog: far segments sink back, near ones pop — layering
        fog := clamp(1.18 - dist_v3(pts[i], cam.position) / fog_ref, 0.40, 1)
        body := rl.Color{u8(f32(col.r) * fog), u8(f32(col.g) * fog), u8(f32(col.b) * fog), col.a}

        if i < n - 1 {
            rn := seg_radius(i + 1, n) * (1 + 0.045 * math.sin(time_total * 3 + f32(i + 1) * 0.5))
            rl.DrawCylinderEx(pts[i], pts[i + 1], r, rn, 10, body)
        }
        rl.DrawSphereEx(pts[i], r, 12, 9, body)
        // glossy highlight bump toward the light
        rl.DrawSphereEx(pts[i] + light * (r * 0.58), r * 0.40, 8, 6, rl.Color{255, 255, 255, 52})

        if i == 0 && !hide_head {
            f := rl.Vector3{f32(dir.x), f32(dir.y), f32(dir.z)}
            s := abs(f.y) == 1 ? rl.Vector3{1, 0, 0} : norm_v3(cross_v3(f, {0, 1, 0}))
            u := norm_v3(cross_v3(s, f))
            e1 := pts[0] + f * 0.40 + s * 0.21 + u * 0.19
            e2 := pts[0] + f * 0.40 - s * 0.21 + u * 0.19
            rl.DrawSphereEx(e1, 0.12, 8, 8, rl.WHITE)
            rl.DrawSphereEx(e2, 0.12, 8, 8, rl.WHITE)
            rl.DrawSphereEx(e1 + f * 0.07, 0.06, 8, 8, rl.BLACK)
            rl.DrawSphereEx(e2 + f * 0.07, 0.06, 8, 8, rl.BLACK)
            // soft pulsing aura around the head
            rl.BeginBlendMode(.ADDITIVE)
            rl.DrawSphereEx(pts[0], 0.85 + 0.1 * math.sin(time_total * 2.5), 14, 10,
                rl.Color{50, 230, 130, 30})
            rl.EndBlendMode()
        }
    }
}

draw_particles :: proc() {
    for p in particles {
        a := p.life / p.max_life
        col := p.color
        col.a = u8(f32(255) * a)
        rl.DrawCubeV(p.pos, {p.size, p.size, p.size}, col)
    }
}

// ---------------------------------------------------------------------------
// CJK-capable UI font (Feeding Lab labels / dex / prompts)
// ---------------------------------------------------------------------------

cjk_ok := false

// every Chinese literal used in the UI — scanned to build the glyph set
CJK_SOURCE :: [?]string{
    "苹果", "辣椒", "冰棍", "手榴弹", "便便", "毒蘑菇", "星星", "神秘蛋",
    "投喂实验室 · 发现 种",
    "暴走 冰冻 眩晕",
    "投喂 快捷食物 图鉴 视角 皮肤 转 暂停 重开",
    "食物图鉴 · 已发现 种",
    "加速 减速 节 分 眩晕 爆炸 已免疫",
    "腐烂中",
    "投喂什么？",
    "投放 取消",
    "蛇自动觅食，你来发明食物 —",
    "预设 本地 分享 烹饪中 完成 失败 使用 配方 点评 复制 码 粘贴 无效 输入 或 已投喂",
}

// top-1400 Han chars by frequency, counted from ~100k chars of real Chinese
// prose (Wikipedia: 汉字/中国菜/中国历史/食物/水果/蔬菜/辣/甜/酸) — this gives
// the AI-written flavor lines near-complete glyph coverage
COMMON_CJK :: "一丁七万三上下不与专且世丘业东两严並个中临丹为主举久义之乌乐乘乙九也习书乱乳乾亂了予争事二于云互五亚些亞亡交亦产京亲人仁仅今仍从他付代令以仪们仰件价任份企伊伏伐休众优会传伤伦伯似但佈位低住体佔何余佛作使來例供依侯侵便係促俄俗俘保信修個們候借倡值假偏做停健備傳像僚儒儿元充先光克免党入內全兩八公六共关兴兵其具典养兼内再写军农冲决冷准凉减几凱出击刀分切划列刘则创初判別利别到制刺刻則削剌前割創劃劉力功加务动助努势動勢包匈化北区區十千升半华协卑单南博占卫印危即卻历压厘厚原厥去县参參又及友双反发叔取受变叙叛口古句另只召可台史右叶号司吃各合吉同名后吏向吕君吞否含启吴呈告员周味命和咸哀品哈响唐唯商問喀善喜單嗣嘉器噶嚴四回因团困围固国图圈國圖土在地场址均坏块坡型城域培基塊境墓增墨士处备复夏外多大天太夫央失头夷夹夺奇奉契奠女奴好如始姓委威子孔字存孙季学學宁它守安宋完宗官定实宣室宦宪宫宰害家容宽密富寒察實寫对导封射将將專尊對導小少尔尖尚尤就尼局层居届展属屠屬山岁岛岸島崇崛崩川州工左巨差己已巴巾币市布师帝带席帶常干平年并幾广庄序库应底庚府废度座庫康廢廣延廷建开异弃式引弘弟张弱張強强归当录形彩彭影役往征很律後徐得從御復微德心必志忠快念忽怀态思性总恢恩恭息患情想意感態慎慢應懿戎成戒或战戚戰户房所手才打托执扩扶批找承技把投抗折护担拆拉拥括拼持指损据授掉掌排採探接控推措描提握揮援操據支收改攻放政故效敗教敬数整數文斗料断斯新斷方於施旁族旗无日旧早时昌明易春昭是显時晉晋晚普景暴更書曹曾替最會月有服望朝期木未末本术朱机杀杂权李材村束条来杨東松极构林果某查标校样核根格栽桂案桓档梁條植椒楚業極楷概構標模樣機橫權次歐止正此步武歧歷死段殷母每毒比毛毫氏民气氟氢氣氧氫氯水永汁求汉汗江汤決沒沙没河油治沿況法泛注泰泽洋洛洪洲活派流济浓海消液淮深混清渐減渡温港游湖湾源準溫溶滅满滿演漠漢漸澳激濃濟灣火灭灵灾炎点為烈烤烧烹無然照熙熟熱燕營爆爭爱爲父爾片版牛牧物特状狀独猜献獨獻玄率玉王环现珍班現球理瑞瑭璋瓜瓦甘甚甜生產用田由甲电画界留略番畫異當疆疫病登發白百的皆皇皮益盐监盘盛盟目直相盾省看真着督矛知短石码研破础硝硫确碗碘碱碳確碼礎示礼社祀祖神祥祭祸禁禅福离私秋种科秦秩积称移稀程税種稱稳穆究空突窦立章端竹笔符第筆等筑策筷签简算管節範篆篡簡簽籍米类粉精糖系紀約紅純紙級素索細終組結給統經維線編總繁織繼红约级纪纳纵纷线组细织终经结给绝统继续维绿缓编缺网罗置署美群義羽習翻老考者而耕耗职联聯聲肉育肴胜胡能脱腐臣臨自至致臺與興舉舊舌舜航般船良色节花芽苏若苦英范茄草荒荣药荷获莽菌菜華营萬落葉著董蒙蔡蔬薄藏藝藩蘇虎處號虽蛋蜀蝕融血行衍術衛衡补表衰袁被袭裂製複西要覆見規視覺见观规视觉角解言計記設許註詞試話該認語說調論謂謎識譯議讀變计订认讨让议记讲许论设证识词试诛话该语说诸调豆象豪貿資質负贡财贤败货质贵贸资赋赖赤赫走赵起趁超越趋足跋距路身軍較載輸轉车转轻载较辅输辛辞辣辨農边辽达迁迅过迎运近还这进远连迫述追退送逃选透逐途這通逝速造連進遇運遍過道達遗遠適遭遷選遼避還邓邦郑郡部郭都鄭配酒酱酸采释里重野量金銀錄铁铜银错镇長长門開間閣關门问间队防阳阶阿附际陆陈降限陕院除陳陵陶陷陸隆隋随隔際隨难集雍雖雙雜離難電需震霍露霸青靖非面革韓韩音響項須頒領頭題顏類顯页项顺顿领题風风食飲養餐饪饭饮馆首香馬马驾骨體高鬥魏鮮鱼鲁鲜鳥鹹鹽麻黃黄黎黑點黨鼎齐龍龙"

load_cjk_font :: proc() {
    try_load :: proc(runes: []rune) -> (rl.Font, bool) {
        // 注意：raylib 无法解析 .ttc（会静默回退成内置默认字体），必须用纯 .ttf
        f := rl.LoadFontEx("/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
            64, raw_data(runes), i32(len(runes)))
        if rl.IsFontValid(f) && f.baseSize == 64 {
            return f, true
        }
        return {}, false
    }
    collect :: proc(s: string, runes: ^[dynamic]rune) {
        i := 0
        for i < len(s) {
            r, size := utf8.decode_rune_in_string(s[i:])
            if r != utf8.RUNE_ERROR && r > 126 {
                dup := false
                for e in runes do if e == r { dup = true; break }
                if !dup do append(runes, r)
            }
            i += size
        }
    }

    runes: [dynamic]rune
    defer delete(runes)
    for c in 32..=126 do append(&runes, rune(c))
    for s in CJK_SOURCE do collect(s, &runes)
    collect(COMMON_CJK, &runes)
    if f, ok := try_load(runes[:]); ok {
        font_cjk = f
        cjk_ok = true
        rl.SetTextureFilter(font_cjk.texture, .BILINEAR)
        return
    }
    // fallback: minimal UI-only glyph set (pre-LLM behavior)
    clear(&runes)
    for c in 32..=126 do append(&runes, rune(c))
    for s in CJK_SOURCE do collect(s, &runes)
    if f, ok := try_load(runes[:]); ok {
        font_cjk = f
        cjk_ok = true
        rl.SetTextureFilter(font_cjk.texture, .BILINEAR)
    }
}

has_cjk :: proc(t: cstring) -> bool {
    p := transmute([^]u8)t
    for i := 0; p[i] != 0; i += 1 {
        if p[i] > 126 do return true
    }
    return false
}

// Font-based text helpers (crisp modern type, falls back to the default font)
draw_text :: proc(text: cstring, x, y: i32, size: i32, color: rl.Color, bold := false) {
    if fonts_ok {
        f := bold ? font_bold : font_ui
        if cjk_ok && has_cjk(text) do f = font_cjk // 中文走专用字体
        rl.DrawTextEx(f, text, {f32(x), f32(y)}, f32(size), 1, color)
    } else {
        rl.DrawText(text, x, y, size, color)
    }
}

measure_text :: proc(text: cstring, size: i32, bold := false) -> i32 {
    if fonts_ok {
        f := bold ? font_bold : font_ui
        if cjk_ok && has_cjk(text) do f = font_cjk
        return i32(rl.MeasureTextEx(f, text, f32(size), 1).x)
    }
    return rl.MeasureText(text, size)
}

draw_centered :: proc(text: cstring, y: i32, size: i32, color: rl.Color, bold := false) {
    w := measure_text(text, size, bold)
    draw_text(text, (SCREEN_W - w) / 2, y, size, color, bold)
}

// ---------------------------------------------------------------------------
// Navigation aids: tri-view minimap + camera-linked axis compass
// ---------------------------------------------------------------------------

coord_of :: proc(c: IV3, axis: i32) -> i32 {
    switch axis {
    case 0: return c.x
    case 1: return c.y
    case:   return c.z
    }
    return 0
}

mini_px :: proc(origin, size, coord: i32) -> i32 {
    return origin + i32((f32(coord) + 0.5) / GRID_N * f32(size))
}

// One orthographic projection panel. ha = horizontal axis, va = vertical axis.
draw_projection :: proc(px, py, size: i32, ha, va: i32, flip_v: bool,
                        label: cstring, hcol, vcol: rl.Color) {
    rl.DrawRectangle(px, py, size, size, rl.Color{18, 20, 30, 200})
    // mid cross for orientation
    mid := px + size/2
    midy := py + size/2
    rl.DrawLine(px, midy, px + size, midy, rl.Color{70, 76, 92, 120})
    rl.DrawLine(mid, py, mid, py + size, rl.Color{70, 76, 92, 120})
    // axis-colored edges: bottom = horizontal axis, left = vertical axis
    rl.DrawRectangle(px, py + size - 2, size, 2, hcol)
    rl.DrawRectangle(px, py, 2, size, vcol)
    rl.DrawRectangleLinesEx({f32(px), f32(py), f32(size), f32(size)}, 1, rl.Color{120, 128, 150, 160})

    plot :: proc(px, py, size: i32, c: IV3, ha, va: i32, flip_v: bool, col: rl.Color, r: i32) {
        x := mini_px(px, size, coord_of(c, ha))
        v := mini_px(0, size, coord_of(c, va))
        y := flip_v ? py + size - v : py + v
        rl.DrawRectangle(x - r/2, y - r/2, r, r, col)
    }

    for s in snake do plot(px, py, size, s, ha, va, flip_v, rl.Color{70, 180, 80, 220}, 4)
    plot(px, py, size, food, ha, va, flip_v, rl.RED, 6)
    plot(px, py, size, snake[0], ha, va, flip_v, rl.LIME, 6)

    draw_text(label, px + 4, py - 18, 14, rl.Color{190, 195, 210, 255}, true)
}

draw_minimap :: proc() {
    size :: 108
    gap  :: 18
    y0   :: 40
    x0   :: SCREEN_W - (size * 3 + gap * 2) - 20
    draw_projection(x0, y0, size, 0, 2, false, "TOP  X> Zv", AXIS_X, AXIS_Z)
    draw_projection(x0 + size + gap, y0, size, 0, 1, true, "FRONT  X> Y^", AXIS_X, AXIS_Y)
    draw_projection(x0 + (size + gap) * 2, y0, size, 2, 1, true, "SIDE  Z> Y^", AXIS_Z, AXIS_Y)
}

draw_compass :: proc() {
    fwd := norm_v3(cam.target - cam.position)
    r := norm_v3(cross_v3(fwd, {0, 1, 0}))
    u := cross_v3(r, fwd)

    anchor := rl.Vector2{SCREEN_W - 82, SCREEN_H - 96}
    L :: 40.0
    axes := [?]struct{ d: rl.Vector3, col: rl.Color, label: cstring }{
        {{1, 0, 0}, AXIS_X, "X"},
        {{0, 1, 0}, AXIS_Y, "Y"},
        {{0, 0, 1}, AXIS_Z, "Z"},
    }
    rl.DrawCircleLines(i32(anchor.x), i32(anchor.y), 46, rl.Color{90, 96, 116, 140})
    for a in axes {
        sx := a.d.x * r.x + a.d.y * r.y + a.d.z * r.z
        sy := -(a.d.x * u.x + a.d.y * u.y + a.d.z * u.z)
        ex := anchor.x + sx * L
        ey := anchor.y + sy * L
        rl.DrawLineEx(anchor, {ex, ey}, 3, a.col)
        rl.DrawCircleV({ex, ey}, 4, a.col)
        draw_text(a.label, i32(ex) - 6, i32(ey) - 20, 16, a.col, true)
    }
    draw_text("VIEW", i32(anchor.x) - 18, i32(anchor.y) + 52, 12, rl.Color{140, 146, 165, 200})
}

// Screen-space guidance: an arrow at the head pointing toward the food's
// screen position, plus the exact keys to press (steering is screen-relative).
draw_guidance :: proc() {
    if state != .PLAYING do return
    if view_mode == .FIRST do return   // first-person has beacon + path line

    hp := cell_to_world(snake[0])
    t, ok := nav_target()
    if !ok do return
    fp := cell_to_world(t)

    // skip when the food is behind the camera (edge indicator handles that)
    fwd := norm_v3(cam.target - cam.position)
    to_food := fp - cam.position
    if to_food.x*fwd.x + to_food.y*fwd.y + to_food.z*fwd.z < 0 do return

    sh := rl.GetWorldToScreen(hp, cam)
    sf := rl.GetWorldToScreen(fp, cam)
    dx := sf.x - sh.x
    dy := sf.y - sh.y
    l := math.sqrt(dx*dx + dy*dy)
    if l < 50 do return   // nearly there on screen

    ux, uy := dx / l, dy / l
    x0 := sh.x + ux * 46
    y0 := sh.y + uy * 46
    x1 := sh.x + ux * 106
    y1 := sh.y + uy * 106

    col := rl.Color{255, 110, 110, 220}
    rl.DrawLineEx({x0, y0}, {x1, y1}, 4, col)
    // arrowhead barbs
    bx := -uy * 9
    by := ux * 9
    rl.DrawLineEx({x1, y1}, {x1 - ux*14 + bx, y1 - uy*14 + by}, 4, col)
    rl.DrawLineEx({x1, y1}, {x1 - ux*14 - bx, y1 - uy*14 - by}, 4, col)

    // which keys move the snake along the arrow (dead zone on each axis)
    horiz: cstring = ""
    vert: cstring = ""
    if ux < -0.35 do horiz = "A"
    if ux >  0.35 do horiz = "D"
    if uy < -0.35 do vert = "W"
    if uy >  0.35 do vert = "S"

    keys: cstring
    switch {
    case vert != "" && horiz != "": keys = fmt.ctprintf("%s + %s", vert, horiz)
    case vert != "":                 keys = vert
    case horiz != "":                keys = horiz
    case:                            keys = ""
    }
    if keys != "" {
        draw_text(keys, i32(x1) + 8, i32(y1) - 10, 20, rl.RAYWHITE, true)
    }
}

// Screen-edge arrow pointing at the food when it's outside the view (FP aid),
// plus a subtle crosshair in first-person mode.
draw_food_indicator :: proc() {
    if state != .PLAYING && state != .PAUSED do return

    first_person := view_mode == .FIRST && state != .TITLE
    if first_person {
        cx, cy :: SCREEN_W / 2, SCREEN_H / 2
        rl.DrawCircleLines(cx, cy, 5, rl.Color{255, 255, 255, 90})
    }

    sp_t, has_t := nav_target()
    if !has_t do return
    tp := cell_to_world(sp_t)
    sp := rl.GetWorldToScreen(tp, cam)
    fwd := norm_v3(cam.target - cam.position)
    to_food := tp - cam.position
    behind := to_food.x*fwd.x + to_food.y*fwd.y + to_food.z*fwd.z < 0

    margin :: 70.0
    on_screen := !behind &&
        sp.x > margin && sp.x < SCREEN_W - margin &&
        sp.y > margin && sp.y < SCREEN_H - margin
    if on_screen do return

    cx :: f32(SCREEN_W) / 2
    cy :: f32(SCREEN_H) / 2
    dx := sp.x - cx
    dy := sp.y - cy
    if behind { dx = -dx; dy = -dy }
    if abs(dx) < 0.001 && abs(dy) < 0.001 do dy = 1

    kx := dx != 0 ? (cx - margin) / abs(dx) : 1e9
    ky := dy != 0 ? (cy - margin) / abs(dy) : 1e9
    k := min(kx, ky)
    ex := cx + dx * k
    ey := cy + dy * k

    pulse := 0.7 + 0.3 * math.sin(time_total * 5)
    rl.DrawCircleV({ex, ey}, 9 * pulse, rl.Color{255, 70, 70, 220})
    rl.DrawCircleLines(i32(ex), i32(ey), 14, rl.Color{255, 120, 120, 160})
    draw_text("FOOD", i32(ex) - 20, i32(ey) + 17, 13, rl.Color{255, 120, 120, 230}, true)
}

draw_hud :: proc() {
    draw_text(fmt.ctprintf("SCORE  %d", score), 26, 22, 30, rl.RAYWHITE, true)
    draw_text(fmt.ctprintf("BEST   %d", best), 26, 60, 21, rl.GOLD)
    draw_text(fmt.ctprintf("LENGTH %d", len(snake)), 26, 90, 21, rl.LIME)
    speed := int((START_INTERVAL - move_interval) / SPEED_STEP) + 1
    draw_text(fmt.ctprintf("SPEED  x%d", speed), 26, 120, 21, rl.SKYBLUE)
    draw_text(fmt.ctprintf("HEAD   (%d, %d, %d)", snake[0].x, snake[0].y, snake[0].z),
        26, 150, 18, rl.Color{150, 160, 180, 255})

    if game_mode == .FEEDING {
        draw_text(fmt.ctprintf("FOODS   %d in the cube", len(foods)), 26, 176, 18,
            rl.Color{255, 190, 120, 255})
        draw_text(fmt.ctprintf("投喂实验室 · 发现 %d 种", len(kinds)), 26, 204, 19,
            rl.Color{255, 200, 140, 255}, true)
        // 异常状态指示
        fy: i32 = 234
        if fx_speed_timer > 0 && fx_speed_mult < 1 {
            draw_text(fmt.ctprintf("暴走 %.0fs", fx_speed_timer), 26, fy, 17, {255, 120, 60, 255}, true)
            fy += 22
        }
        if fx_speed_timer > 0 && fx_speed_mult > 1 {
            draw_text(fmt.ctprintf("冰冻 %.0fs", fx_speed_timer), 26, fy, 17, {120, 210, 255, 255}, true)
            fy += 22
        }
        if confuse_timer > 0 {
            draw_text(fmt.ctprintf("眩晕 %.0fs", confuse_timer), 26, fy, 17, {200, 120, 255, 255}, true)
            fy += 22
        }
        if llm_is_cooking() && llm_word != "" {
            pulse := 0.6 + 0.4 * math.sin(time_total * 6)
            draw_text(fmt.ctprintf("AI 烹饪中: %s...", llm_word), 26, fy, 17,
                {255, u8(180 + 40 * pulse), 110, 255}, true)
        }
        draw_text("T: 投喂    1-8: 快捷食物    Tab: 图鉴    C: 复制分享码    粘贴分享码投喂    V: 视角    M: 皮肤    IJKL: 转视角    P/Space: 暂停    R: 重开",
            26, SCREEN_H - 36, 16, rl.Color{160, 165, 180, 255})
        return
    }

    fd := abs(food.x - snake[0].x) + abs(food.y - snake[0].y) + abs(food.z - snake[0].z)
    draw_text(fmt.ctprintf("FOOD    %d cells away", fd), 26, 176, 18, rl.Color{255, 140, 140, 255})
    if autopilot {
        pulse := 0.65 + 0.35 * math.sin(time_total * 5)
        draw_text("AUTOPILOT  (B to take over)", 26, 204, 19,
            rl.Color{255, 200, u8(120 + 80 * pulse), 255}, true)
    }

    draw_text("WASD: steer    IJKL or drag: orbit    U/O or wheel: zoom    -/=: speed    V: view    B: autopilot    M: skin    P/Space: pause    R: restart",
        26, SCREEN_H - 36, 16, rl.Color{160, 165, 180, 255})
}

llm_is_cooking :: proc() -> bool {
    sync.mutex_lock(&llm_mutex)
    s := llm_state == .COOKING
    sync.mutex_unlock(&llm_mutex)
    return s
}

draw_toast :: proc() {
    if toast_t <= 0 || toast == "" do return
    a := u8(235 * clamp(toast_t / 0.5, 0, 1))
    w := measure_text(fmt.ctprintf("%s", toast), 19, true)
    x := (SCREEN_W - w) / 2
    y: i32 = SCREEN_H - 78
    rl.DrawRectangle(x - 14, y - 6, w + 28, 32, {10, 12, 20, u8(f32(a) * 0.8)})
    rl.DrawRectangleLinesEx({f32(x - 14), f32(y - 6), f32(w + 28), 32}, 1, {255, 210, 140, a / 2})
    draw_text(fmt.ctprintf("%s", toast), x, y, 19, {255, 232, 175, a}, true)
}

draw_title :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 0, 0, 130})
    pulse := 0.75 + 0.25 * math.sin(time_total * 3)
    draw_centered("3D  SNAKE", SCREEN_H/2 - 170, 88,
        rl.Color{u8(120 * pulse + 90), 255, u8(140 * pulse + 60), 255}, true)
    draw_centered("True 3D - six directions inside a 12x12x12 cube, with a panoramic overview",
        SCREEN_H/2 - 64, 23, rl.Color{170, 175, 190, 255})
    draw_centered("A / D: screen-left & right      W / S: screen-up & down (relative to your view)",
        SCREEN_H/2 - 18, 20, rl.Color{190, 195, 210, 255})
    draw_centered("J / L: rotate    I / K: tilt    U / O: zoom (or use the mouse)   V: first-person view.",
        SCREEN_H/2 + 14, 18, rl.Color{150, 155, 170, 255})
    draw_centered("Press B anytime to watch the AI play (BFS pathfinding + survival lookahead).",
        SCREEN_H/2 + 38, 18, rl.Color{255, 200, 140, 255})
    draw_centered("Press M to switch between the modern tube skin and the classic cube skin.",
        SCREEN_H/2 + 62, 18, rl.Color{140, 230, 190, 255})
    draw_centered("Pause anytime with P or SPACE to inspect the cube. The dotted line shows where",
        SCREEN_H/2 + 86, 18, rl.Color{150, 155, 170, 255})
    draw_centered("flying straight leads. Mini-map and axis compass share the edge colors.",
        SCREEN_H/2 + 110, 18, rl.Color{150, 155, 170, 255})
    draw_centered("SPACE: classic mode", SCREEN_H/2 + 152, 30, rl.RAYWHITE, true)
    draw_centered("F: 投喂实验室 — AI 蛇自动觅食，你来发明食物 (type any word, T to feed)",
        SCREEN_H/2 + 196, 22, rl.Color{255, 200, 140, 255}, true)
    if best > 0 {
        draw_centered(fmt.ctprintf("Best: %d", best), SCREEN_H/2 + 240, 21, rl.GOLD)
    }
}

draw_game_over :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{20, 0, 0, 150})
    draw_centered("GAME OVER", SCREEN_H/2 - 120, 76, rl.RED, true)
    draw_centered(fmt.ctprintf("Score: %d", score), SCREEN_H/2 - 28, 34, rl.RAYWHITE)
    if score >= best && score > 0 {
        draw_centered("NEW BEST!", SCREEN_H/2 + 16, 25, rl.GOLD, true)
    } else {
        draw_centered(fmt.ctprintf("Best: %d", best), SCREEN_H/2 + 16, 23, rl.GOLD)
    }
    draw_centered("Press ENTER to play again", SCREEN_H/2 + 68, 25, rl.LIGHTGRAY)
}

draw_win :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 20, 0, 150})
    draw_centered("YOU WIN!", SCREEN_H/2 - 120, 76, rl.LIME, true)
    draw_centered(fmt.ctprintf("Final score: %d", score), SCREEN_H/2 - 28, 34, rl.RAYWHITE)
    draw_centered("Press ENTER to play again", SCREEN_H/2 + 30, 25, rl.LIGHTGRAY)
}

draw_paused :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 0, 0, 110})
    draw_centered("PAUSED", SCREEN_H/2 - 46, 64, rl.RAYWHITE, true)
    draw_centered("Drag to orbit and inspect - P or SPACE to resume", SCREEN_H/2 + 32, 23, rl.LIGHTGRAY)
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

update_camera :: proc(dt: f32, alpha: f32) {
    // smoothed head position (shared by both camera modes)
    hp := cell_to_world(snake[0])
    if len(prev_snake) > 0 {
        hp = lerp_v3(cell_to_world(prev_snake[0]), hp, alpha)
    }

    shake_off := rl.Vector3{0, 0, 0}
    if shake_time > 0 {
        shake_time -= dt
        s := shake_time * 0.5
        shake_off = {
            (rand.float32() - 0.5) * s,
            (rand.float32() - 0.5) * s,
            (rand.float32() - 0.5) * s,
        }
    }

    if view_mode == .FIRST && state != .TITLE {
        // first-person: ride on the snake's head, looking along its heading
        f := norm_v3(lerp_v3(v3_of(prev_dir), v3_of(dir), alpha))
        u := norm_v3(lerp_v3(v3_of(prev_up), v3_of(head_up), alpha))
        pos := hp + u * 0.15 + shake_off
        cam.position = pos
        cam.target = hp + f * 4 + shake_off
        cam.up = u
        cam.fovy = 68
        cam.projection = .PERSPECTIVE
        return
    }

    // orbit mode (also used on the title screen) — full free rotation,
    // drag with either mouse button, or use the keyboard
    if rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.LEFT) {
        d := rl.GetMouseDelta()
        cam_yaw   -= d.x * 0.006
        cam_pitch -= d.y * 0.006
    }
    ORBIT_SPEED :: 2.2
    if rl.IsKeyDown(.J) do cam_yaw   += ORBIT_SPEED * dt
    if rl.IsKeyDown(.L) do cam_yaw   -= ORBIT_SPEED * dt
    if rl.IsKeyDown(.I) do cam_pitch += ORBIT_SPEED * dt
    if rl.IsKeyDown(.K) do cam_pitch -= ORBIT_SPEED * dt
    cam_pitch = clamp(cam_pitch, -1.55, 1.55)   // nearly full vertical range
    if rl.IsKeyDown(.U) do cam_dist -= 18 * dt
    if rl.IsKeyDown(.O) do cam_dist += 18 * dt

    wheel := rl.GetMouseWheelMove()
    if wheel != 0 {
        cam_dist *= 1 - wheel * 0.08
    }
    cam_dist = clamp(cam_dist, 14, 48)

    if state == .TITLE {
        cam_yaw += dt * 0.25
    }

    // orbit pivots on the CUBE CENTER: dragging rotates the whole cube
    // (frame, snake, food) as one rigid object on screen
    k := clamp(dt * 4, 0, 1)
    cam_target = lerp_v3(cam_target, {0, 0, 0}, k)

    tgt := cam_target + shake_off
    cp := math.cos(cam_pitch)
    cam.position = tgt + rl.Vector3{math.cos(cam_yaw) * cp, math.sin(cam_pitch), math.sin(cam_yaw) * cp} * cam_dist
    cam.target = tgt
    cam.up = {0, 1, 0}
    cam.fovy = 55
    cam.projection = .PERSPECTIVE
}

// ---------------------------------------------------------------------------
// Frame composition (shared by the window and offscreen captures)
// ---------------------------------------------------------------------------

draw_frame :: proc(alpha: f32) {
    rl.ClearBackground(rl.Color{16, 18, 26, 255})

    rl.BeginMode3D(cam)
    draw_boundaries()
    draw_tether()
    if game_mode == .FEEDING {
        draw_foods()
    } else {
        draw_food()
    }
    first_person := view_mode == .FIRST && state != .TITLE
    if modern_skin {
        draw_snake_modern(alpha, first_person)
    } else {
        draw_snake(alpha, first_person)
    }
    draw_path_hint()
    draw_particles()
    rl.EndMode3D()

    draw_tint()
    draw_hud()
    draw_minimap()
    draw_compass()
    draw_food_indicator()
    draw_guidance()
    draw_food_labels()
    draw_dex()
    draw_input_box()
    draw_toast()
    if state == .PLAYING && !started {
        draw_centered("Steer with A / D / W / S to launch the snake", SCREEN_H - 76, 24,
            rl.Color{u8(200 + 55 * math.sin(time_total * 4)), 220, 120, 255}, true)
    }
    switch state {
    case .TITLE:     draw_title()
    case .PAUSED:    draw_paused()
    case .GAME_OVER: draw_game_over()
    case .WIN:       draw_win()
    case .PLAYING:   // nothing extra
    }
}

// Render one frame into a texture and export it (window-visibility independent)
capture :: proc(filename: cstring, alpha: f32) {
    rt := rl.LoadRenderTexture(SCREEN_W, SCREEN_H)
    rl.BeginTextureMode(rt)
    draw_frame(alpha)
    rl.EndTextureMode()
    img := rl.LoadImageFromTexture(rt.texture)
    rl.ImageFlipVertical(&img)
    rl.ExportImage(img, filename)
    rl.UnloadImage(img)
    rl.UnloadRenderTexture(rt)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    // headless self-test: SNAKE_SELFTEST=1 ./snake3d
    if os.get_env("SNAKE_SELFTEST", context.allocator) == "1" {
        os.exit(self_test() ? 0 : 1)
    }
    if os.get_env("SNAKE_LLMTEST", context.allocator) == "1" {
        os.exit(llm_test() ? 0 : 1)
    }

    llm_init_config() // FEED_LLM_API_KEY / FEED_LLM_BASE_URL / FEED_LLM_MODEL

    rl.SetConfigFlags({.MSAA_4X_HINT})
    rl.InitWindow(SCREEN_W, SCREEN_H, "3D Snake — true 3D (Odin + raylib)")
    rl.SetTargetFPS(60)
    rl.SetExitKey(.KEY_NULL) // ESC 用于取消输入框，不退出游戏

    // modern system fonts, loaded at a large base size for crisp rendering
    font_ui = rl.LoadFontEx("/System/Library/Fonts/SFNS.ttf", 64, nil, 0)
    font_bold = rl.LoadFontEx("/System/Library/Fonts/SFNSRounded.ttf", 96, nil, 0)
    fonts_ok = rl.IsFontValid(font_ui) && rl.IsFontValid(font_bold)
    if fonts_ok {
        rl.SetTextureFilter(font_ui.texture, .BILINEAR)
        rl.SetTextureFilter(font_bold.texture, .BILINEAR)
    }
    // CJK-capable UI font for the Feeding Lab (labels, dex, input box)
    load_cjk_font()

    rl.InitAudioDevice()
    audio_ok = rl.IsAudioDeviceReady()
    if audio_ok {
        snd_eat = gen_tone(880, 0.12)
        snd_die = gen_sweep(420, 90, 0.5)
        snd_win = gen_sweep(520, 1040, 0.6)
    }

    load_best()
    make_presets()
    reset_game()

    // DEBUG: offscreen-render verification mode (SNAKE_SHOT=1)
    shot_mode := os.get_env("SNAKE_SHOT", context.allocator) == "1"
    shots := 0

    for !rl.WindowShouldClose() {
        dt := min(rl.GetFrameTime(), 0.05)
        time_total += dt
        toast_t = max(0, toast_t - dt)
        llm_poll()

        alpha := clamp(move_timer / move_interval, 0, 1)

        switch state {
        case .TITLE:
            if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) {
                game_mode = .CLASSIC
                autopilot = false
                reset_game()
                state = .PLAYING
            }
            if rl.IsKeyPressed(.F) {
                game_mode = .FEEDING
                reset_game()
                state = .PLAYING
            }
        case .PLAYING:
            handle_text_input()
            handle_input()
            if !input_open {
                if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) { state = .PAUSED; break }
                if rl.IsKeyPressed(.R) { reset_game(); break }
            }

            // manual speed control (auto-acceleration on food still applies)
            if game_mode == .CLASSIC {
                if rl.IsKeyPressed(.MINUS) do move_interval = min(0.50, move_interval + 0.02)
                if rl.IsKeyPressed(.EQUAL) do move_interval = max(MIN_INTERVAL, move_interval - 0.02)
            }

            // the snake holds still until the player steers for the first time
            if !started && (len(dir_queue) > 0 || autopilot) do started = true

            if started {
                eff := move_interval * (fx_speed_timer > 0 ? fx_speed_mult : 1)
                move_timer += dt
                for move_timer >= eff && state == .PLAYING {
                    move_timer -= eff
                    step()
                }
            }
            // food-effect timers
            fx_speed_timer = max(0, fx_speed_timer - dt)
            confuse_timer  = max(0, confuse_timer - dt)
            tint_timer     = max(0, tint_timer - dt)
            if game_mode == .FEEDING do update_food_rot(dt)
            alpha = clamp(smoothstep(move_timer / move_interval), 0, 1)
            update_particles(dt)
        case .PAUSED:
            if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) do state = .PLAYING
            if rl.IsKeyPressed(.R) { reset_game(); state = .PLAYING }
            // allow inspecting from the other view while paused
            if rl.IsKeyPressed(.V) {
                view_mode = view_mode == .FIRST ? .ORBIT : .FIRST
            }
            if rl.IsKeyPressed(.M) do modern_skin = !modern_skin
        case .GAME_OVER, .WIN:
            if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.R) {
                reset_game()
                state = .PLAYING
            }
            // autopilot 死亡后自动重开，继续演示
            if autopilot && state == .GAME_OVER {
                restart_timer -= dt
                if restart_timer <= 0 {
                    reset_game()
                    state = .PLAYING
                }
            }
            update_particles(dt)
        }

        update_camera(dt, alpha)

        rl.BeginDrawing()
        draw_frame(alpha)

        // DEBUG: offscreen captures (reliable even when the window is occluded)
        if shot_mode {
            if shots == 0 && time_total > 0.4 {
                capture("shot_title.png", alpha)
                shots = 1
                // 进入投喂模式并投放多种食物
                game_mode = .FEEDING
                reset_game()
                state = .PLAYING
                cast_preset(1) // 辣椒
                cast_preset(3) // 手榴弹
                cast_preset(6) // 星星
                cast_word("laser")
                cast_word("durian")
            } else if shots == 1 && time_total > 2.5 {
                capture("shot_feed.png", alpha)
                shots = 2
                dex_open = true // 图鉴展示
            } else if shots == 2 && time_total > 3.5 {
                capture("shot_dex.png", alpha)
                shots = 3
                dex_open = false
            } else if shots == 3 && time_total > 14.0 {
                capture("shot_late.png", alpha)
                shots = 4
            }
        }

        rl.EndDrawing()
    }

    if fonts_ok {
        rl.UnloadFont(font_ui)
        rl.UnloadFont(font_bold)
        if cjk_ok do rl.UnloadFont(font_cjk)
    }
    if audio_ok {
        rl.UnloadSound(snd_eat)
        rl.UnloadSound(snd_die)
        rl.UnloadSound(snd_win)
        rl.CloseAudioDevice()
    }
    rl.CloseWindow()
}
