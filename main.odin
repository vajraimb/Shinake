package snake3d

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
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
input_buf      : [24]u8
input_len      := 0
dex_open       := false          // Tab: 图鉴面板

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
    k := FoodKind{name = name}
    hue := f32(xnext(&h, 360))
    k.color = hsv_rgb(hue, 0.72, 1.0)
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
    add :: proc(name: string, color: rl.Color, shape: FoodShape, size: f32,
                rarity: int, speed: f32, speed_t: f32, growth: int, score: int,
                shake: f32, tint: rl.Color, confuse: f32, bursts: int) {
        append(&kinds, FoodKind{
            name = strings.clone(name), color = color, shape = shape, size = size,
            spin = 2.0, rarity = rarity, fx_speed = speed, fx_speed_t = speed_t,
            fx_growth = growth, fx_score = score, fx_shake = shake,
            fx_tint = tint, fx_confuse = confuse, fx_bursts = bursts,
        })
        kind_by_name[kinds[len(kinds) - 1].name] = len(kinds) - 1
    }
    add("苹果",   {230, 60, 60, 255},   .SPHERE, 0.30, 0, 0, 0, 1, 10, 0, {}, 0, 1)
    add("辣椒",   {255, 90, 30, 255},   .CONE,   0.30, 1, 0.5, 5, 1, 20, 0, {255, 120, 30, 60}, 0, 2)
    add("冰棍",   {120, 220, 255, 255}, .CUBE,   0.28, 1, 1.7, 4, 1, 15, 0, {120, 200, 255, 60}, 0, 1)
    add("手榴弹", {70, 80, 70, 255},    .SPHERE, 0.30, 1, 0, 0, -4, 0, 0.7, {255, 160, 60, 90}, 0, 4)
    add("便便",   {130, 85, 40, 255},   .GEM,    0.28, 0, 0, 0, -1, -25, 0, {120, 80, 30, 100}, 0, 1)
    add("毒蘑菇", {170, 70, 220, 255},  .CONE,   0.30, 1, 0, 0, 0, 5, 0, {170, 70, 220, 80}, 4, 2)
    add("星星",   {255, 220, 80, 255},  .GEM,    0.30, 2, 0, 0, 2, 80, 0, {255, 220, 80, 60}, 0, 4)
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
    spawn_kind(kind_index(word))
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
        return
    }
    spawn_kind(i)
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
    if rl.IsKeyPressed(.V) {
        view_mode = view_mode == .FIRST ? .ORBIT : .FIRST
    }
    // M: modern / classic snake skin
    if rl.IsKeyPressed(.M) do modern_skin = !modern_skin

    if game_mode == .FEEDING {
        // 投喂模式：蛇永远是 AI 操控，玩家只管投喂
        if rl.IsKeyPressed(.TAB) do dex_open = !dex_open
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
    if rl.IsKeyPressed(.BACKSPACE) && input_len > 0 do input_len -= 1
    if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
        if input_len > 0 {
            cast_word(string(input_buf[:input_len]))
        }
        input_open = false
        input_len = 0
    }
    if rl.IsKeyPressed(.ESCAPE) {
        input_open = false
        input_len = 0
    }
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

// 图鉴: all food kinds discovered so far
draw_dex :: proc() {
    if !dex_open do return
    w: i32 = 340
    x := SCREEN_W - w - 20
    y: i32 = 170
    rows := min(len(kinds), 22)
    h := i32(60 + rows * 26)
    rl.DrawRectangle(x, y, w, h, {12, 14, 24, 225})
    rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 1, {120, 128, 150, 180})
    draw_text(fmt.ctprintf("食物图鉴 · 已发现 %d 种", len(kinds)), x + 16, y + 12, 20,
        rl.RAYWHITE, true)

    buf: [192]u8
    for i in 0..<rows {
        k := kinds[i]
        ry := y + 44 + i32(i) * 26
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
        draw_text(fmt.ctprintf("%s  %s", stars, cstring(raw_data(buf[:]))),
            x + 130, ry + 2, 14, {170, 175, 190, 255})
    }
    if len(kinds) > rows {
        draw_text(fmt.ctprintf("... and %d more", len(kinds) - rows), x + 40, y + 44 + i32(rows) * 26, 14,
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
    typed := string(input_buf[:input_len])
    draw_text(fmt.ctprintf("%s", typed), x + 18, y + 30, 24, rl.RAYWHITE, true)
    if time_total * 2 - math.floor(time_total * 2) < 0.55 {
        w := measure_text(fmt.ctprintf("%s", typed), 24, true)
        draw_text("_", x + 18 + w + 3, y + 30, 24, rl.RAYWHITE, true)
    }
    draw_text("Enter 投放 · Esc 取消", x + w - 190, y + 12, 13, {140, 145, 160, 255})
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
}

load_cjk_font :: proc() {
    runes: [dynamic]rune
    defer delete(runes)
    for c in 32..=126 do append(&runes, rune(c))
    for s in CJK_SOURCE {
        i := 0
        for i < len(s) {
            r, size := utf8.decode_rune_in_string(s[i:])
            if r != utf8.RUNE_ERROR && r > 126 {
                dup := false
                for e in runes do if e == r { dup = true; break }
                if !dup do append(&runes, r)
            }
            i += size
        }
    }
    // 注意：raylib 无法解析 .ttc（会静默回退成内置默认字体），必须用纯 .ttf
    f := rl.LoadFontEx("/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        64, raw_data(runes), i32(len(runes)))
    if rl.IsFontValid(f) && f.baseSize == 64 {
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
        }
        draw_text("T: 投喂    1-8: 快捷食物    Tab: 图鉴    V: 视角    M: 皮肤    IJKL: 转视角    P/Space: 暂停    R: 重开",
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
