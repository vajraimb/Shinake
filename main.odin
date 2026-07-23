package snake3d

import rl "vendor:raylib"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"

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

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

state          := GameState.TITLE
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

font_ui        : rl.Font
font_bold      : rl.Font
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
    started = false
    spawn_food()
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
        apply_dir(ai_choose())
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

    if nh == food {
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

// Take the candidate first move, then walk the food distance field to the
// food while simulating the snake's body; afterwards check the head can
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
        if cur == food do grow += 1
        if grow > 0 {
            grow -= 1
        } else {
            _ = pop(&sim)
        }

        steps += 1
        if cur == food do break
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

    // 1. shortest safe path to the food
    mark_body(snake[:], &ai_blocked)
    bfs(food, &ai_dist, &ai_blocked)
    best_dir := dir
    best_d := i32(1 << 30)
    found := false
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

    // 2. no safe food route — chase our own tail to buy time
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
draw_tether :: proc() {
    if state != .PLAYING && state != .PAUSED do return
    a := cell_to_world(snake[0])
    b := cell_to_world(food)
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

draw_particles :: proc() {
    for p in particles {
        a := p.life / p.max_life
        col := p.color
        col.a = u8(f32(255) * a)
        rl.DrawCubeV(p.pos, {p.size, p.size, p.size}, col)
    }
}

// Font-based text helpers (crisp modern type, falls back to the default font)
draw_text :: proc(text: cstring, x, y: i32, size: i32, color: rl.Color, bold := false) {
    if fonts_ok {
        f := bold ? font_bold : font_ui
        rl.DrawTextEx(f, text, {f32(x), f32(y)}, f32(size), 1, color)
    } else {
        rl.DrawText(text, x, y, size, color)
    }
}

measure_text :: proc(text: cstring, size: i32, bold := false) -> i32 {
    if fonts_ok {
        f := bold ? font_bold : font_ui
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
    fp := cell_to_world(food)

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

    sp := rl.GetWorldToScreen(cell_to_world(food), cam)
    fwd := norm_v3(cam.target - cam.position)
    to_food := cell_to_world(food) - cam.position
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
    fd := abs(food.x - snake[0].x) + abs(food.y - snake[0].y) + abs(food.z - snake[0].z)
    draw_text(fmt.ctprintf("FOOD    %d cells away", fd), 26, 176, 18, rl.Color{255, 140, 140, 255})
    if autopilot {
        pulse := 0.65 + 0.35 * math.sin(time_total * 5)
        draw_text("AUTOPILOT  (B to take over)", 26, 204, 19,
            rl.Color{255, 200, u8(120 + 80 * pulse), 255}, true)
    }

    draw_text("WASD: steer    IJKL or drag: orbit    U/O or wheel: zoom    -/=: speed    V: view    B: autopilot    P/Space: pause    R: restart",
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
    draw_centered("Pause anytime with P or SPACE to inspect the cube. The dotted line shows where",
        SCREEN_H/2 + 62, 18, rl.Color{150, 155, 170, 255})
    draw_centered("flying straight leads. Mini-map and axis compass share the edge colors.",
        SCREEN_H/2 + 86, 18, rl.Color{150, 155, 170, 255})
    draw_centered("Press SPACE to start", SCREEN_H/2 + 120, 32, rl.RAYWHITE, true)
    if best > 0 {
        draw_centered(fmt.ctprintf("Best: %d", best), SCREEN_H/2 + 166, 21, rl.GOLD)
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
    draw_food()
    first_person := view_mode == .FIRST && state != .TITLE
    draw_snake(alpha, first_person)
    draw_path_hint()
    draw_particles()
    rl.EndMode3D()

    draw_hud()
    draw_minimap()
    draw_compass()
    draw_food_indicator()
    draw_guidance()
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

    // modern system fonts, loaded at a large base size for crisp rendering
    font_ui = rl.LoadFontEx("/System/Library/Fonts/SFNS.ttf", 64, nil, 0)
    font_bold = rl.LoadFontEx("/System/Library/Fonts/SFNSRounded.ttf", 96, nil, 0)
    fonts_ok = rl.IsFontValid(font_ui) && rl.IsFontValid(font_bold)
    if fonts_ok {
        rl.SetTextureFilter(font_ui.texture, .BILINEAR)
        rl.SetTextureFilter(font_bold.texture, .BILINEAR)
    }

    rl.InitAudioDevice()
    audio_ok = rl.IsAudioDeviceReady()
    if audio_ok {
        snd_eat = gen_tone(880, 0.12)
        snd_die = gen_sweep(420, 90, 0.5)
        snd_win = gen_sweep(520, 1040, 0.6)
    }

    load_best()
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
                reset_game()
                state = .PLAYING
            }
        case .PLAYING:
            handle_input()
            if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) { state = .PAUSED; break }
            if rl.IsKeyPressed(.R) { reset_game(); break }

            // manual speed control (auto-acceleration on food still applies)
            if rl.IsKeyPressed(.MINUS) do move_interval = min(0.50, move_interval + 0.02)
            if rl.IsKeyPressed(.EQUAL) do move_interval = max(MIN_INTERVAL, move_interval - 0.02)

            // the snake holds still until the player steers for the first time
            if !started && (len(dir_queue) > 0 || autopilot) do started = true

            if started {
                move_timer += dt
                for move_timer >= move_interval && state == .PLAYING {
                    move_timer -= move_interval
                    step()
                }
            }
            alpha = clamp(smoothstep(move_timer / move_interval), 0, 1)
            update_particles(dt)
        case .PAUSED:
            if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) do state = .PLAYING
            if rl.IsKeyPressed(.R) { reset_game(); state = .PLAYING }
            // allow inspecting from the other view while paused
            if rl.IsKeyPressed(.V) {
                view_mode = view_mode == .FIRST ? .ORBIT : .FIRST
            }
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
                state = .PLAYING
                started = true
                autopilot = true // DEBUG: 让 AI 自动驾驶演示
            } else if shots == 1 && time_total > 8.0 {
                capture("shot_play.png", alpha)
                shots = 2
            } else if shots == 2 && time_total > 20.0 {
                capture("shot_late.png", alpha)
                shots = 3
            }
        }

        rl.EndDrawing()
    }

    if fonts_ok {
        rl.UnloadFont(font_ui)
        rl.UnloadFont(font_bold)
    }
    if audio_ok {
        rl.UnloadSound(snd_eat)
        rl.UnloadSound(snd_die)
        rl.UnloadSound(snd_win)
        rl.CloseAudioDevice()
    }
    rl.CloseWindow()
}
