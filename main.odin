package snake3d

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
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

GRID_N :: 12          // 12 x 12 x 12 cubic lattice (spherical play field carved from it)
CELL   :: 1.0

// 球形场地：以原点为球心、半径 WORLD_RADIUS 的球体，与立方体六面相切。
// 网格仍是 12×12×12，但只有球内的格子可玩；四角区域是禁区。
WORLD_RADIUS :: f32(GRID_N) * CELL * 0.5

START_INTERVAL :: 0.27   // seconds per move at start
MIN_INTERVAL   :: 0.08   // fastest
SPEED_STEP     :: 0.007  // interval reduction per food

SCREEN_W :: 1600
SCREEN_H :: 900

TAU :: 6.28318530718

// Consistent axis colors used by the compass, minimap and sphere rings
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
    blueprint:  string,   // 效果蓝图 JSON {"do":[...]} (owned clone, "" = none; supersedes classic fx)
    byline:     string,   // share v2 创作者落款 (owned clone, "" = none)
    retired:    bool,     // 作品库已删除: hidden from dex/quick-cast; kinds[] never reorders (live foods hold indices)
    harm_cache: i8,       // 拒食学习缓存: 0 未评估 / 1 有害 / 2 安全 (lazy, never serialized)
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

view_mode      := ViewMode.ORBIT   // default: panoramic overview of the whole sphere
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
immune_toasted : map[string]bool // 本局已弹过"免疫"提示的食物名（reset_game 清空）
ai_target      := IV3{-1, -1, -1}
ai_has_target  := false
fx_speed_timer : f32 = 0
fx_speed_mult  : f32 = 1
confuse_timer  : f32 = 0
tint_timer     : f32 = 0
tint_color     := rl.Color{0, 0, 0, 0}
input_open     := false
input_buf      : [3072]u8  // share v2 codes carrying blueprints+macros can reach ~1-2 KB
input_len      := 0
dex_open       := false          // Tab: 图鉴面板
dex_sel        := 0              // keyboard selection inside the dex panel
last_cast_kind := -1             // kinds index of the most recently cast food

// --- 创造台 (Creator Workshop) state ---
// edit_kind is a SCRATCH FoodKind (owned name/flavor clones, NOT in kinds[]);
// edit_blueprint is the owned raw JSON, "" = none.
editor_open      := false
editor_sel       := 0
edit_kind        : FoodKind
edit_blueprint   : string
edit_has_blueprint := false     // true: fx sliders hidden, blueprint rules
edit_tint_idx    := 0           // 闪光: 0 = 无, 1..12 = hue (idx-1)*30
edit_target      := Edit_Target.NONE
edit_buf         : [512]u8      // shared text-edit buffer (name/flavor/creative/…)
edit_len         := 0
edit_rep_timer   : f32 = 0      // ←→ key-repeat timer
editor_showcase  := IV3{GRID_N / 2, GRID_N - 2, GRID_N / 2} // live-preview cell
editor_base_name : string       // borrowed dex name when 以此为基础改造 ("" = blank)
pending_save     := false       // a save is waiting on the nickname prompt
pending_copy     := false       // ... and it came from the 复制分享码 row
creator_asked    := false       // nickname prompt already shown this session

// --- toast notifications (bottom-center, ~2.5s) ---
toast          : string          // owned clone
toast_t        : f32 = 0

// --- 战报图 (battle report card) state ---
session_eaten  : map[string]int  // 食物名 -> 本局吃掉次数（战报奇葩菜单用；吃掉投喂系食物就记，与模式无关）
report_tex     : rl.Texture2D    // 最近生成的战报卡（id != 0 时可上屏）
report_ready   := false          // 本局战报已生成过（防止每帧重复生成）
report_open    := false          // 投喂模式 G 键弹出的战报浮层
report_file    : string          // 最近保存的 PNG 文件名（owned clone）

// --- 教练模式 (interactive tutorial) + 演示模式 (attract loop) state ---
tutorial_active    := false
tutorial_step      := 0
tutorial_chapter   := TutorialChapter.FEED
tutorial_mark      := 0      // counter baseline captured at step entry
tutorial_steer_mask  : u32   // distinct steering keys seen (classic ch. step 1)
tutorial_steer_count := 0
// counters the tutorial detectors read (monotonic; detectors compare > mark)
cast_word_total       := 0   // every cast_word() call
preset_cast_total     := 0   // every cast_preset() call
dex_cast_total        := 0   // every 图鉴 Enter cast
view_toggle_total     := 0   // every V flip
autopilot_toggle_total := 0  // every B flip

attract_active   := false
attract_elapsed  : f32 = 0   // seconds since the demo started
attract_cast_idx := 0        // playlist cursor (loops via modulo)
attract_cast_t   : f32 = 0   // time since the last playlist cast
attract_topup_t  : f32 = 0   // anti-starvation top-up clock (demo has no player)
title_idle_t     : f32 = 0   // seconds of no input on the title screen

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
llm_job_mode   := LLM_Job_Mode.RECIPE // mode of the job currently in flight
llm_creative_raw : string        // worker→main handoff of raw creative JSON

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

len_v3 :: proc(v: rl.Vector3) -> f32 {
    return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
}

dot_v3 :: proc(a, b: rl.Vector3) -> f32 {
    return a.x*b.x + a.y*b.y + a.z*b.z
}

norm_v3 :: proc(v: rl.Vector3) -> rl.Vector3 {
    l := len_v3(v)
    if l < 1e-6 do return {0, 0, 0}
    return v / l
}

// 球面线性插值：方向走大圆，半径线性过渡。用于蛇身/路径贴着球面走弧线。
slerp_v3 :: proc(a, b: rl.Vector3, t: f32) -> rl.Vector3 {
    ra, rb := len_v3(a), len_v3(b)
    if ra < 1e-4 || rb < 1e-4 do return lerp_v3(a, b, t)
    da, db := a / ra, b / rb
    d := clamp(dot_v3(da, db), -1, 1)
    if d > 0.9995 || d < -0.9995 do return lerp_v3(a, b, t)
    th := math.acos(d)
    s := math.sin(th)
    w0 := math.sin((1 - t) * th) / s
    w1 := math.sin(t * th) / s
    return norm_v3(da * w0 + db * w1) * (ra + (rb - ra) * t)
}

// Rodrigues: rotate p around unit axis by ang radians
rotate_axis_v3 :: proc(p, axis: rl.Vector3, ang: f32) -> rl.Vector3 {
    c := math.cos(ang)
    s := math.sin(ang)
    return p * c + cross_v3(axis, p) * s + axis * dot_v3(axis, p) * (1 - c)
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

    // 出生在球面赤道（+X 面），朝 +Z 沿大圆绕行，而不是从球心沿轴直飞
    append(&snake, IV3{GRID_N - 1, GRID_N / 2, GRID_N / 2})
    append(&snake, IV3{GRID_N - 1, GRID_N / 2, GRID_N / 2 - 1})
    append(&snake, IV3{GRID_N - 1, GRID_N / 2, GRID_N / 2 - 2})
    for s in snake do append(&prev_snake, s)

    dir = IV3{0, 0, 1}
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
    play_clock = 0
    shield_timer = 0
    score_mult = 1
    score_mult_timer = 0
    clear_sched_queue()
    input_open = false
    input_len = 0
    ai_has_target = false
    clear(&immune_toasted)
    clear(&session_eaten)
    report_clear()

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

// F: 游戏中即时切换 经典 ↔ 投喂。蛇 / 分数 / 地图 / 特效全部保留，战局继续。
// 切到投喂：AI 接管、立即起跑、场上无食时补一个苹果开场；豆豆由模式门自然离场
switch_to_feeding :: proc() {
    game_mode = .FEEDING
    autopilot = true
    started = true
    clear(&dir_queue)
    dex_open = false
    input_open = false
    report_open = false
    if len(foods) == 0 do spawn_kind(0)
}

// 切回经典：交还方向盘、补一颗豆豆；场上剩余投喂食物保留（继续可吃，见 step）
switch_to_classic :: proc() {
    game_mode = .CLASSIC
    autopilot = false
    clear(&dir_queue)
    dex_open = false
    input_open = false
    report_open = false
    spawn_food()
}

// 豆豆与投喂食物不同格（spawn_kind 里 occupied 检查的镜像）
food_cell_free :: proc(c: IV3) -> bool {
    for f in foods do if f.pos == c do return false
    return true
}

spawn_food :: proc() {
    if len(snake) >= map_free_cells() {
        state = .WIN
        play(snd_win)
        return
    }
    // never on the snake, never inside a map wall, not too close to the head,
    // never stacked on a feeding-lab food (both systems coexist after F)
    for _ in 0..<400 {
        f := IV3{
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
            i32(rand.int_max(GRID_N)),
        }
        d := abs(f.x - snake[0].x) + abs(f.y - snake[0].y) + abs(f.z - snake[0].z)
        if !cell_in_world(f) || on_snake(f) || map_solid(f) || d < 4 || !food_cell_free(f) do continue
        food = f
        return
    }
    // crowded board (the old loop could spin forever here): deterministic scan
    for i in 0..<CELLS {
        c := cell3(i)
        if !cell_in_world(c) || on_snake(c) || map_solid(c) || !food_cell_free(c) do continue
        d := abs(c.x - snake[0].x) + abs(c.y - snake[0].y) + abs(c.z - snake[0].z)
        if d >= 4 {
            food = c
            return
        }
    }
    // last resort: any fillable cell at all (snake fills nearly everything)
    for i in 0..<CELLS {
        c := cell3(i)
        if cell_in_world(c) && !on_snake(c) && !map_solid(c) && food_cell_free(c) {
            food = c
            return
        }
    }
    // nothing fillable left — that IS a full board
    state = .WIN
    play(snd_win)
}

queue_dir :: proc(d: IV3) {
    if len(dir_queue) >= 3 do return
    last := len(dir_queue) > 0 ? dir_queue[len(dir_queue) - 1] : dir
    if d == last do return
    if d.x == -last.x && d.y == -last.y && d.z == -last.z do return  // no 180° turns
    append(&dir_queue, d)
}

turn_up_to :: proc(d: IV3) {
    if d == head_up {
        head_up = neg_i(dir)
    } else if d == neg_i(head_up) {
        head_up = dir
    }
}

apply_dir :: proc(d: IV3) {
    if d == dir do return
    if d.x == -dir.x && d.y == -dir.y && d.z == -dir.z do return  // no 180° turns
    turn_up_to(d)
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
    nh, nd, stepped := advance_on_sphere(head, dir)
    if !stepped {
        if shield_timer > 0 do return  // 护盾：无路可走时原地停一拍
        die()
        return
    }
    if nd != dir {
        turn_up_to(nd)
        dir = nd
    }
    // obstacle collision: solid map cells kill like the boundary wall;
    // 护盾 ghosts straight through instead (same as shielded self-bite)
    if map_solid(nh) && shield_timer <= 0 {
        die()
        return
    }
    // self collision (tail cell frees up unless growing)
    body := pending_growth > 0 ? snake[:] : snake[:len(snake) - 1]
    for s in body {
        if s == nh {
            if shield_timer > 0 do break  // 护盾：允许咬到自己，穿身而过
            die()
            return
        }
    }

    inject_at(&snake, 0, nh)

    // 两套食物系统全模式共存（F 即时切换后场上可能同时有投喂食物和豆豆）：
    // 先吃投喂食物（蓝图效果模式无关），豆豆只认经典模式，同拍让到下拍
    ate := false
    for f, i in foods {
        if f.pos == nh {
            eat_food(i)
            ate = true
            break
        }
    }
    if !ate && game_mode == .CLASSIC && nh == food {
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

    if len(snake) >= map_free_cells() {
        state = .WIN
        play(snd_win)
    }
}

die :: proc() {
    state = .GAME_OVER
    view_mode = .ORBIT   // pull out to orbit view so the crash site is visible
    shake_time = 0.5
    restart_timer = 1.5
    death_squawk = true  // the frame loop plays snd_die — keeps die() raylib-free
    burst(cell_to_world(snake[0]))
    clear_sched_queue()  // 死亡即清空蓝图计划动作
}

// 死亡后是否自动重开：仅 attract 演示 或 经典模式自动驾驶（观赏场景）
gameover_auto_restart :: proc() -> bool {
    return attract_active || (game_mode == .CLASSIC && autopilot)
}

// 死亡后是否生成战报卡：投喂（非演示）或 经典手动
gameover_wants_report :: proc() -> bool {
    if attract_active do return false
    return game_mode == .FEEDING || (game_mode == .CLASSIC && !autopilot)
}

// 回标题：保留当前地图选择与 game_mode，重置闲置计时
back_to_title :: proc() {
    state = .TITLE
    title_idle_t = 0
    reset_game()
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

in_grid :: proc(c: IV3) -> bool {
    return c.x >= 0 && c.x < GRID_N && c.y >= 0 && c.y < GRID_N && c.z >= 0 && c.z < GRID_N
}

// 球形场地判定：网格内、且格子中心落在半径 WORLD_RADIUS 的球体内。
cell_in_world :: proc(c: IV3) -> bool {
    if !in_grid(c) do return false
    p := cell_to_world(c)
    return p.x*p.x + p.y*p.y + p.z*p.z <= WORLD_RADIUS * WORLD_RADIUS
}

// 可玩区域 = 球形场地。AI 寻路、食物生成、撞墙判定都以此为准。
in_bounds :: proc(c: IV3) -> bool {
    return cell_in_world(c)
}

// 先走「头 + 朝向」——和 AI 的六向 BFS 同一张图，自动驾驶才不会算一套、走一套。
// 只有这一格已经出球时才贴着球面滑到最近的合法邻格（玩家顶着边界会绕，而不是秒死）。
advance_on_sphere :: proc(head, d: IV3) -> (next, new_dir: IV3, ok: bool) {
    n := IV3{head.x + d.x, head.y + d.y, head.z + d.z}
    if cell_in_world(n) do return n, d, true

    p := cell_to_world(head)
    pr := len_v3(p)
    if pr < 0.9 do return n, d, false
    radial := p / pr
    tan := v3_of(d)
    tan -= radial * dot_v3(tan, radial)
    tl := len_v3(tan)
    if tl < 1e-5 {
        n := IV3{head.x + d.x, head.y + d.y, head.z + d.z}
        return n, d, cell_in_world(n)
    }
    tan /= tl
    axis := cross_v3(radial, tan)
    al := len_v3(axis)
    if al < 1e-5 {
        n := IV3{head.x + d.x, head.y + d.y, head.z + d.z}
        return n, d, cell_in_world(n)
    }
    axis /= al
    target := rotate_axis_v3(p, axis, CELL / pr)
    tn := len_v3(target)
    if tn > 1e-5 do target = target * (pr / tn)

    best := IV3{-1, -1, -1}
    best_off := d
    best_s := f32(1e9)
    found := false
    for off in DIRS6 {
        if off.x == -d.x && off.y == -d.y && off.z == -d.z do continue
        c := IV3{head.x + off.x, head.y + off.y, head.z + off.z}
        if !cell_in_world(c) do continue
        w := cell_to_world(c)
        // 距离大圆落点 + 轻微偏向外侧，避免贴格时一格格往球心掉
        s := dist_v3(w, target) - 0.35 * (len_v3(w) - pr)
        if s < best_s {
            best_s = s
            best = c
            best_off = off
            found = true
        }
    }
    return best, best_off, found
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
            stepped: bool
            next, _, stepped = advance_on_sphere(cur, first)
            if !stepped || !in_bounds(next) || ai_dist[idx3(next)] < 0 do return false
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
    mark_map(&sim_blocked) // 障碍在生存模拟里是永久的墙
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
        mark_map(&ai_blocked)
        bfs(ai_target, &ai_dist, &ai_blocked)
        for off in DIRS6 {
            n, _, ok := advance_on_sphere(head, off)
            if !ok || !in_bounds(n) || ai_blocked[idx3(n)] do continue
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
    mark_map(&ai_blocked)
    bfs(tip, &ai_dist, &ai_blocked)
    best_d = 1 << 30
    for off in DIRS6 {
        n, _, ok := advance_on_sphere(head, off)
        if !ok || !in_bounds(n) || ai_blocked[idx3(n)] do continue
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
        n, _, ok := advance_on_sphere(head, off)
        if ok && in_bounds(n) && !ai_blocked[idx3(n)] do return off
    }
    return dir
}

// ---------------------------------------------------------------------------
// 障碍地图 (obstacle maps, v3.0): a 1728-cell bitmask of solid cells.
// Solids kill like the boundary wall; the AI's blocked-cell model, every
// free-cell picker, the minimap and the HUD all read the same bits.
// ---------------------------------------------------------------------------

MAP_CELLS :: GRID_N * GRID_N * GRID_N // 1728
MAP_WORDS :: (MAP_CELLS + 63) / 64    // 27 u64 words

MapData :: struct {
    name:   string,
    byline: string,   // "" for built-ins
    bits:   [MAP_WORDS]u64,  // bitmask over idx3 order; 1 = solid
}

current_map  : MapData
map_has_walls := false   // fast path: false = 虚空, callers skip all checks

MapID :: enum { VOID, PILLARS, CROSS, HIVE, CAVE }

map_id   := MapID.VOID
map_seed : u32 = 41      // 随机洞穴: N 每次进入都 +1，所以第一张洞穴是 #42
cave_name_buf: [40]u8

map_bit :: proc(i: int) -> bool {
    return current_map.bits[i >> 6] & (u64(1) << u64(i & 63)) != 0
}

map_solid :: proc(c: IV3) -> bool {
    if !map_has_walls || !in_grid(c) do return false
    return map_bit(idx3(c))
}

// note: setting a bit raises map_has_walls; clearing bits does NOT lower it
// again (stale-true is harmless — it only disables the fast path). Bulk
// edits end with map_finalize() or map_clear() to keep the flag exact.
map_set :: proc(c: IV3, solid: bool) {
    if !in_grid(c) do return
    i := idx3(c)
    mask := u64(1) << u64(i & 63)
    if solid {
        current_map.bits[i >> 6] |= mask
        map_has_walls = true
    } else {
        current_map.bits[i >> 6] &= ~mask
    }
}

map_clear :: proc() {
    for i in 0..<MAP_WORDS do current_map.bits[i] = 0
    map_has_walls = false
}

map_solid_count :: proc() -> int {
    n := 0
    for w in current_map.bits {
        v := w
        for v != 0 {  // Kernighan popcount: ≤ a few hundred set bits
            v &= v - 1
            n += 1
        }
    }
    return n
}

map_finalize :: proc() {
    map_has_walls = map_solid_count() > 0
}

// the snake can only ever fill non-solid cells inside the sphere — WIN triggers there
map_free_cells :: proc() -> int {
    n := 0
    for i in 0..<CELLS {
        c := cell3(i)
        if cell_in_world(c) && !map_bit(i) do n += 1
    }
    return n
}

// 球形场地内的格子总数（自测与 HUD 用）
sphere_cell_count :: proc() -> int {
    n := 0
    for i in 0..<CELLS do if cell_in_world(cell3(i)) do n += 1
    return n
}

// OR solid cells into an AI blocked array (call right after mark_body)
mark_map :: proc(blocked: ^[CELLS]bool) {
    if !map_has_walls do return
    for i in 0..<CELLS {
        if map_bit(i) do blocked[i] = true
    }
}

// 出生区留空: nothing solid within Manhattan distance 3 of the sphere center
map_clear_center :: proc() {
    c :: GRID_N / 2
    for z in 0..<GRID_N do for y in 0..<GRID_N do for x in 0..<GRID_N {
        if abs(x - c) + abs(y - c) + abs(z - c) <= 3 {
            i := x + GRID_N * (y + GRID_N * z)
            current_map.bits[i >> 6] &= ~(u64(1) << u64(i & 63))
        }
    }
}

// fraction of in-sphere free cells reachable from the first such cell (BFS)
map_free_reach_ratio :: proc() -> f32 {
    free := 0
    start := -1
    for i in 0..<CELLS {
        c := cell3(i)
        if !cell_in_world(c) do continue
        if !map_bit(i) {
            free += 1
            if start < 0 do start = i
        }
    }
    if free == 0 do return 0
    blocked: [CELLS]bool
    dist:    [CELLS]i32
    for i in 0..<CELLS do blocked[i] = map_bit(i)
    bfs(cell3(start), &dist, &blocked)
    reached := 0
    for i in 0..<CELLS do if dist[i] >= 0 do reached += 1
    return f32(reached) / f32(free)
}

// --- the 5 built-in maps ---

map_build_void :: proc() {
    map_clear()
    current_map.name = "虚空"
    current_map.byline = ""
}

map_build_pillars :: proc() {  // 4 根立柱 (x,z)∈{(3,3),(3,8),(8,3),(8,8)}, y 2..9 → 32
    map_clear()
    PILLAR_XZ :: [2]i32{3, 8}
    for px in PILLAR_XZ do for pz in PILLAR_XZ {
        for y in 2..=9 do map_set({px, i32(y), pz}, true)
    }
    current_map.name = "石柱林"
    current_map.byline = ""
    map_finalize()
}

map_build_cross :: proc() {
    // 两堵垂直整墙 x=6 / z=6，各开一扇 2 格门，高度错开：
    // x 墙低门 z=3 (y 4-5)，z 墙高门 x=3 (y 7-8) → 144+144-12-4 = 272
    map_clear()
    MID :: GRID_N / 2
    for y in 0..<GRID_N do for z in 0..<GRID_N do map_set({MID, i32(y), i32(z)}, true)
    for y in 0..<GRID_N do for x in 0..<GRID_N do map_set({i32(x), i32(y), MID}, true)
    map_set({MID, 4, 3}, false)
    map_set({MID, 5, 3}, false)
    map_set({3, 7, MID}, false)
    map_set({3, 8, MID}, false)
    current_map.name = "十字回廊"
    current_map.byline = ""
    map_finalize()
}

map_build_hive :: proc() {
    // 2×2×2 砖块摆在 (3,3,3)+4n 每个格点（轴向 span {2,3}/{6,7}/{10,11}），
    // 任何一格距中心 ≤3 的整块跳过 → 23 块 × 8 = 184
    map_clear()
    CENTERS :: [3]i32{3, 7, 11}
    c :: GRID_N / 2
    for cz in CENTERS do for cy in CENTERS do for cx in CENTERS {
        keep := true
        for dz in 0..<2 do for dy in 0..<2 do for dx in 0..<2 {
            cell := IV3{cx - 1 + i32(dx), cy - 1 + i32(dy), cz - 1 + i32(dz)}
            if abs(cell.x - c) + abs(cell.y - c) + abs(cell.z - c) <= 3 {
                keep = false
                break
            }
        }
        if !keep do continue
        for dz in 0..<2 do for dy in 0..<2 do for dx in 0..<2 {
            map_set({cx - 1 + i32(dx), cy - 1 + i32(dy), cz - 1 + i32(dz)}, true)
        }
    }
    current_map.name = "蜂巢"
    current_map.byline = ""
    map_finalize()
}

map_build_cave :: proc(seed: u32) {
    // xorshift 从 seed 逐格 p=0.055 填充；连通自由格 <85% 就确定性地换
    // seed+1 重试（给定 N 永远生成同一张图；中心 3 格内永远畅通）
    s := seed
    for _ in 0..<100 {
        map_clear()
        h := s != 0 ? s : 0x9E3779B9
        for i in 0..<MAP_CELLS {
            if xnext(&h, 1000) < 55 {
                current_map.bits[i >> 6] |= u64(1) << u64(i & 63)
            }
        }
        map_clear_center()
        map_finalize()
        if map_free_reach_ratio() >= 0.85 do break
        s += 1
    }
    current_map.name = fmt.bprintf(cave_name_buf[:], "随机洞穴 #%d", seed)
    current_map.byline = ""
}

map_apply :: proc(id: MapID) {
    map_id = id
    switch id {
    case .VOID:    map_build_void()
    case .PILLARS: map_build_pillars()
    case .CROSS:   map_build_cross()
    case .HIVE:    map_build_hive()
    case .CAVE:    map_build_cave(map_seed)
    }
}

// 标题界面 N：虚空→石柱林→十字回廊→蜂巢→随机洞穴→虚空…
// 每次进入随机洞穴都换一个新种子
map_cycle :: proc() {
    next := MapID((int(map_id) + 1) % len(MapID))
    if next == .CAVE do map_seed += 1
    map_apply(next)
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

// 净收益：生长×2 + 分数/10 − 眩晕×1.5。带副作用但大补的食物不会被拒食。
kind_net_value :: proc(k: FoodKind) -> f32 {
    return 2.0 * f32(k.fx_growth) + f32(k.fx_score) / 10.0 - 1.5 * k.fx_confuse
}

// 蓝图食物的有害评估：把蓝图编译成 ScheduledAction 后按同一权重求和
// （growth → 2.0×n，score → n/10.0，confuse → −1.5×secs，其余节点 0）。
// chance 节点在编译时已经掷过骰子 —— 本次编译结果就是这一掷的结论
// （一次性不确定性，随后被 harm_cache 冻结）。编译失败 → 蓝图按中性处理。
bp_harm_value :: proc(json_text: string) -> (f32, bool) {
    actions, ok := bp_compile(json_text)
    if !ok do return 0, false
    defer bp_free_actions(&actions)
    total := f32(0)
    for a in actions {
        switch a.prim.name {
        case "growth":  total += 2.0 * f32(a.args.i1)
        case "score":   total += f32(a.args.i1) / 10.0
        case "confuse": total -= 1.5 * a.args.f1
        }
    }
    return total, true
}

// 有害 ⇔ 净收益 < 0。结果懒缓存进 FoodKind.harm_cache（0 未知/1 有害/2 安全），
// 覆盖所有注册路径（预设/生成/创意/导入/作品库），无需各处改动。
kind_harmful :: proc(k: ^FoodKind) -> bool {
    if k.harm_cache == 0 {
        net := kind_net_value(k^)
        if k.blueprint != "" {
            if bp_net, ok := bp_harm_value(k.blueprint); ok {
                net += bp_net
            }
        }
        k.harm_cache = net < 0 ? 1 : 2
    }
    return k.harm_cache == 1
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
        if !cell_in_world(f) || on_snake(f) || map_solid(f) || d < 4 do continue
        occupied := false
        for of in foods do if of.pos == f { occupied = true; break }
        if occupied do continue
        append(&foods, Food{kind = kind_idx, pos = f, spin = rand.float32() * 360})
        return
    }
}

cast_word :: proc(word: string) {
    if len(word) == 0 do return
    cast_word_total += 1
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
    preset_cast_total += 1
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

// 数字键分发：普通 = 预设 1-8；⇧ = 作品库快捷投放（仅当图鉴关闭时）
feed_digit :: proc(i: int, shift: bool) {
    if shift {
        if !dex_open do cast_creation(i)
    } else {
        cast_preset(i)
    }
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
// Share codes: export a kind as "SNAKE3D1.<base64url(json)>", import it back.
// Wire format v2 (always exported): {"v":2,"name","hue","shape","rarity",
// "flavor","fx":{...}(as v1), optional "blueprint":{...}, optional
// "macros":{"name":{blueprint},...}(every macro the blueprint references),
// optional "by":"creator"}. v1 payloads ({"v":1,...}) still import unchanged.
// ---------------------------------------------------------------------------

// the v2 recipe JSON object shared by share codes and creations.json.
// bundle_macros: share codes embed every macro the blueprint references so
// codes are self-contained; creations.json relies on the local macros.json.
write_recipe_v2 :: proc(sb: ^strings.Builder, k: FoodKind, bundle_macros: bool) {
    strings.write_string(sb, `{"v":2,"name":`)
    write_json_string(sb, k.name)
    fmt.sbprintf(sb, `,"hue":%d,"shape":%d,"rarity":%d,"flavor":`, k.hue, int(k.shape), k.rarity)
    write_json_string(sb, k.flavor)
    tint: Maybe([3]int)
    if k.fx_tint.a > 0 {
        tint = [3]int{int(k.fx_tint.r), int(k.fx_tint.g), int(k.fx_tint.b)}
    }
    fx := Recipe_FX{
        speed_mult = k.fx_speed, speed_secs = k.fx_speed_t,
        growth = k.fx_growth, score = k.fx_score, shake = k.fx_shake,
        confuse = k.fx_confuse, bursts = k.fx_bursts, tint = tint,
    }
    fxj, merr := json.marshal(fx, allocator = context.temp_allocator)
    if merr == nil {
        strings.write_string(sb, `,"fx":`)
        strings.write_string(sb, string(fxj))
    }
    if k.blueprint != "" {
        strings.write_string(sb, `,"blueprint":`)
        strings.write_string(sb, k.blueprint)
        if bundle_macros {
            bundle := collect_macro_bundle(k.blueprint)
            if len(bundle) > 0 {
                strings.write_string(sb, `,"macros":{`)
                first := true
                for mname, mtext in bundle {
                    if !first do strings.write_string(sb, ",")
                    first = false
                    write_json_string(sb, mname)
                    strings.write_string(sb, ":")
                    strings.write_string(sb, mtext)
                }
                strings.write_string(sb, "}")
            }
        }
    }
    byline := k.byline != "" ? k.byline : creator_byline
    if byline != "" {
        strings.write_string(sb, `,"by":`)
        write_json_string(sb, byline)
    }
    strings.write_string(sb, "}")
}

export_share_code :: proc(idx: int, allocator := context.temp_allocator) -> string {
    sb := strings.builder_make(context.temp_allocator)
    write_recipe_v2(&sb, kinds[idx], true)
    raw := strings.to_string(sb)
    b64, berr := base64.encode(transmute([]u8)raw, base64.ENC_URL_TABLE, allocator)
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
    // peek at the version: v1 keeps the legacy typed decode, v2 walks the tree
    root, perr := json.parse(data, .JSON, true, context.temp_allocator)
    if perr != nil do return -1, false
    obj, ok := root.(json.Object)
    if !ok do return -1, false
    switch int(jnum(obj, "v", -1)) {
    case 1: return import_share_v1(data)
    case 2: return import_share_v2(obj)
    }
    return -1, false
}

import_share_v1 :: proc(data: []u8) -> (int, bool) {
    sr: Share_Recipe
    if json.unmarshal(data, &sr, allocator = context.temp_allocator) != nil do return -1, false
    if sr.v != 1 || sr.name == "" do return -1, false
    r := Recipe{hue = sr.hue, shape = sr.shape, rarity = sr.rarity,
                flavor = strings.clone(sr.flavor), fx = sr.fx}
    clamp_recipe(&r)
    return register_shared_kind(sr.name, r, "", "")
}

// a parsed v2 recipe object (share code payload / creations.json entry).
// name/byline alias the temp-allocated JSON tree; r.flavor is an OWNED clone;
// bp_text/bundled are compact re-serializations in temp_allocator.
V2_Parsed :: struct {
    name:    string,
    r:       Recipe,
    bp_text: string,              // "" = no blueprint (NOT yet test-compiled)
    byline:  string,
    bundled: map[string]string,   // optional "macros" field
}

// shared v2 recipe-object parser (share codes AND creations.json entries)
parse_recipe_v2 :: proc(obj: json.Object) -> (V2_Parsed, bool) {
    p: V2_Parsed
    p.name = jstr_or(obj, "name", "")
    if p.name == "" do return p, false
    fxv, fok := obj["fx"]
    fx, fxok := fxv.(json.Object)
    if !fok || !fxok do return p, false
    p.r = Recipe{
        hue = int(jnum(obj, "hue", 0)), shape = int(jnum(obj, "shape", 0)),
        rarity = int(jnum(obj, "rarity", 0)), flavor = strings.clone(jstr_or(obj, "flavor", "")),
        fx = {
            speed_mult = f32(jnum(fx, "speed_mult", 1)),
            speed_secs = f32(jnum(fx, "speed_secs", 0)),
            growth     = int(jnum(fx, "growth", 0)),
            score      = int(jnum(fx, "score", 0)),
            shake      = f32(jnum(fx, "shake", 0)),
            confuse    = f32(jnum(fx, "confuse", 0)),
            bursts     = int(jnum(fx, "bursts", 1)),
        },
    }
    if tv, tok := fx["tint"]; tok {
        if arr, aok := tv.(json.Array); aok && len(arr) == 3 {
            p.r.fx.tint = [3]int{int(jnumv(arr[0], 0)), int(jnumv(arr[1], 0)), int(jnumv(arr[2], 0))}
        }
    }

    // bundled macros (re-serialized compactly for local storage)
    p.bundled = make(map[string]string, allocator = context.temp_allocator)
    if mv, mok := obj["macros"]; mok {
        mo, mook := mv.(json.Object)
        if !mook do return p, false
        for mname, mval in mo {
            msb := strings.builder_make(context.temp_allocator)
            jwrite(&msb, mval)
            p.bundled[strings.clone(mname, context.temp_allocator)] =
                strings.clone(strings.to_string(msb), context.temp_allocator)
        }
    }

    // optional blueprint, re-serialized compactly (caller test-compiles it)
    if bv, bok := obj["blueprint"]; bok {
        bsb := strings.builder_make(context.temp_allocator)
        jwrite(&bsb, bv)
        p.bp_text = strings.to_string(bsb)
    }

    clamp_recipe(&p.r)
    p.byline = jstr_or(obj, "by", "")
    return p, true
}

import_share_v2 :: proc(obj: json.Object) -> (int, bool) {
    p, ok := parse_recipe_v2(obj)
    if !ok do return -1, false

    // optional blueprint: must test-compile with bundled + local macros available
    if p.bp_text != "" {
        actions, cok := bp_compile(p.bp_text, &p.bundled)
        if !cok do return -1, false   // 蓝图无效 → 整码拒绝（分享码无效）
        bp_free_actions(&actions)
    }

    // register bundled macros locally — never overwrite same-named local macros
    changed := false
    for mname, mtext in p.bundled {
        if _, taken := macros[mname]; !taken {
            macros[strings.clone(mname)] = strings.clone(mtext)
            changed = true
        }
    }
    if changed do save_macros()

    return register_shared_kind(p.name, p.r, p.bp_text, p.byline)
}

// shared tail of both import versions: unique-name suffixing + kind registration
register_shared_kind :: proc(base_name: string, r: Recipe, bp_text: string, byline: string, author := "分享") -> (int, bool) {
    name := base_name
    suffix := 1
    for {
        if _, taken := kind_by_name[name]; !taken do break
        suffix += 1
        name = fmt.tprintf("%s~%d", base_name, suffix)
    }
    k := gen_kind(strings.clone(name), 0) // base gives persistent name + size/spin
    apply_recipe_to_kind(&k, r, author)
    if bp_text != "" do k.blueprint = strings.clone(bp_text)
    if byline != "" do k.byline = strings.clone(byline)
    append(&kinds, k)
    idx := len(kinds) - 1
    kind_by_name[k.name] = idx
    return idx, true
}

// ---------------------------------------------------------------------------
// 作品库 (creations.json): the local library of 自创 works. Every 保存并投放
// upserts the creation here; startup loads it back into the dex. Entries are
// the same v2 recipe objects used by share codes (macros NOT bundled — the
// local macros.json owns them). Retired kinds (dex X) are dropped on rewrite.
// ---------------------------------------------------------------------------

CREATIONS_FILE :: "creations.json"
CREATIONS_MAX  :: 64

// number of library creations currently in memory (自创 and not retired)
creations_count :: proc() -> int {
    n := 0
    for k in kinds do if k.author == "自创" && !k.retired { n += 1 }
    return n
}

// nth newest non-retired 自创 creation (0 = newest), -1 when absent
creation_at :: proc(n: int) -> int {
    seen := 0
    for i := len(kinds) - 1; i >= 0; i -= 1 {
        if kinds[i].author != "自创" || kinds[i].retired do continue
        if seen == n do return i
        seen += 1
    }
    return -1
}

// ⇧1..⇧8: cast the nth newest creation from the library
cast_creation :: proc(n: int) {
    idx := creation_at(n)
    if idx < 0 do return
    spawn_kind(idx)
    last_cast_kind = idx
    set_toast(fmt.tprintf("已投喂: %s", kinds[idx].name))
}

// rewrite the whole library file from memory (capped at CREATIONS_MAX entries)
save_creations :: proc() {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, `{"creations":[`)
    first := true
    written := 0
    for k in kinds {
        if k.author != "自创" || k.retired do continue
        if written >= CREATIONS_MAX do break
        if !first do strings.write_string(&sb, ",")
        first = false
        write_recipe_v2(&sb, k, false)
        written += 1
    }
    strings.write_string(&sb, "]}")
    _ = os.write_entire_file(CREATIONS_FILE, transmute([]u8)strings.to_string(sb))
}

// after a new 自创 kind entered kinds[]: refresh the library file unless full
// (the in-session kind is kept either way; false = 作品库已满)
creation_persist :: proc() -> bool {
    if creations_count() > CREATIONS_MAX do return false
    save_creations()
    return true
}

// startup (after load_macros + make_presets): re-register the library into
// the dex. Invalid entries are skipped silently (stdout log), never crash;
// nothing is spawned and last_cast_kind is untouched.
load_creations :: proc() {
    data, err := os.read_entire_file(CREATIONS_FILE, context.temp_allocator)
    if err != nil do return
    root, perr := json.parse(data, .JSON, true, context.temp_allocator)
    if perr != nil do return
    obj, ok := root.(json.Object)
    if !ok do return
    cv, cok := obj["creations"]
    arr, aok := cv.(json.Array)
    if !cok || !aok do return
    loaded := 0
    for entry in arr {
        if loaded >= CREATIONS_MAX do break
        eo, eok := entry.(json.Object)
        if !eok {
            fmt.println("creations.json: skipped a non-object entry")
            continue
        }
        p, pok := parse_recipe_v2(eo)
        if !pok {
            fmt.println("creations.json: skipped an invalid entry")
            continue
        }
        // blueprint: structural check that tolerates `use` of macros deleted
        // since saving (eat-time strict-compiles and falls back to the classic
        // fx with the 蓝图无效 toast); bundled macros are ignored — macros.json owns them
        if p.bp_text != "" && !bp_validate_lenient(p.bp_text) {
            fmt.println("creations.json: skipped entry with invalid blueprint:", p.name)
            continue
        }
        if _, rok := register_shared_kind(p.name, p.r, p.bp_text, p.byline, "自创"); !rok {
            fmt.println("creations.json: skipped entry:", p.name)
            continue
        }
        loaded += 1
    }
}

// dex X: retire a 自创 kind — hidden from the dex & quick-cast list and removed
// from the library file. kinds[] itself never moves (live foods hold indices).
dex_retire_kind :: proc(idx: int) {
    if idx < 0 || idx >= len(kinds) do return
    if kinds[idx].author != "自创" {
        set_toast("只能删除自创作品")
        return
    }
    if kinds[idx].retired do return
    kinds[idx].retired = true
    save_creations()
    set_toast(fmt.tprintf("已从作品库删除: %s", kinds[idx].name))
}

// ---------------------------------------------------------------------------
// Effect Blueprints （效果蓝图）: a JSON tree {"do":[<node>...]} compiled at
// eat-time into timed primitive actions. Each node is an object with exactly
// one key. Action primitives: speed/growth/score/shake/confuse/flash/burst/
// spawn_food/shield/reverse/score_mult. Flow nodes (compiler-handled):
// delay/repeat/chance/use.
//
// DISCIPLINE: primitive run() procs NEVER call raylib — they only mutate game
// data (die() defers its sound via death_squawk), keeping headless tests live.
// ---------------------------------------------------------------------------

BP_MAX_ACTIONS :: 32   // total action emissions per compile
BP_MAX_DEPTH   :: 4    // macro (use) expansion depth
BP_MAX_DELAY   :: 30.0 // seconds per delay node
BP_MAX_REPEAT  :: 5    // repeat unroll factor

PrimArgs :: struct {
    f1, f2: f32,      // mult/secs, shake strength, ...
    i1:     int,      // growth/score/burst/spawn counts
    s1:     string,   // kind name (owned clone; the queue frees it), "" otherwise
    col:    rl.Color, // flash color (alpha fixed 90)
}

Primitive :: struct {
    name:     string,
    run:      proc(args: PrimArgs),                      // NEVER calls raylib
    describe: proc(args: PrimArgs, buf: []u8) -> string, // one-line Chinese summary
}

ScheduledAction :: struct {
    at:   f32, // absolute play_clock time once enqueued
    prim: ^Primitive,
    args: PrimArgs,
}

primitives : map[string]Primitive
macros     : map[string]string   // 自创新原语: name -> owned {"do":[...]} JSON text

play_clock       : f32 = 0  // accumulates dt only while state == .PLAYING
sched_queue      : [dynamic]ScheduledAction
shield_timer     : f32 = 0  // > 0: 无敌 — 撞墙停一拍不死，咬到身体穿身而过
score_mult       : f32 = 1
score_mult_timer : f32 = 0
death_squawk     := false   // die() 的音效请求，主循环播放
creator_byline   : string   // share v2 "by" 落款（env SNAKE_CREATOR；Run 2 编辑器会写它）

register_primitive :: proc(p: Primitive) {
    primitives[p.name] = p
}

// --- shared eat-effect helpers (classic fx path AND blueprint primitives) ---

// score gains respect score_mult; losses always apply raw
add_score :: proc(n: int) {
    d := n
    if d > 0 && score_mult > 1 {
        d = int(math.round(f32(d) * score_mult))
    }
    score = max(0, score + d)
}

// returns true when the tail-blast killed the snake
apply_growth_fx :: proc(n: int) -> bool {
    if n > 0 {
        pending_growth += n
    } else if n < 0 {
        // 炸掉尾巴，太短就炸死了
        if len(snake) - 2 < -n {
            die()
            return true
        }
        for _ in 0..<-n do _ = pop(&snake)
    }
    return false
}

// 掉头反转：头尾互换，方向取 新头−新次节（轴单位向量），清空转向队列
reverse_snake :: proc() {
    n := len(snake)
    if n < 2 do return
    for i in 0..<n / 2 {
        snake[i], snake[n - 1 - i] = snake[n - 1 - i], snake[i]
    }
    // prev_snake mirrors the same reversal so interpolation stays consistent
    m := len(prev_snake)
    for i in 0..<m / 2 {
        prev_snake[i], prev_snake[m - 1 - i] = prev_snake[m - 1 - i], prev_snake[i]
    }
    nd := IV3{snake[0].x - snake[1].x, snake[0].y - snake[1].y, snake[0].z - snake[1].z}
    if nd == (IV3{0, 0, 0}) do nd = neg_i(dir) // 护盾重叠等异常布局的兜底
    dir = nd
    prev_dir = dir // keep the first-person camera from swinging 180°
    clear(&dir_queue)
}

// --- the 11 registered action primitives (data-only, no raylib) ---

prim_run_speed :: proc(a: PrimArgs) {
    if a.f2 > 0 {
        fx_speed_timer = a.f2
        fx_speed_mult = a.f1
    }
}
prim_run_growth :: proc(a: PrimArgs) {
    _ = apply_growth_fx(a.i1)
}
prim_run_score :: proc(a: PrimArgs) {
    add_score(a.i1)
}
prim_run_shake :: proc(a: PrimArgs) {
    shake_time = max(shake_time, a.f1)
}
prim_run_confuse :: proc(a: PrimArgs) {
    confuse_timer = max(confuse_timer, a.f1)
}
prim_run_flash :: proc(a: PrimArgs) {
    tint_timer = 0.7
    tint_color = a.col
}
prim_run_burst :: proc(a: PrimArgs) {
    if len(snake) == 0 do return
    for _ in 0..<a.i1 do burst_col(cell_to_world(snake[0]), {255, 220, 120, 255}, 24)
}
prim_run_spawn_food :: proc(a: PrimArgs) {
    if a.s1 == "" || len(snake) == 0 do return
    idx := kind_index(a.s1) // 未知名称：现场生成一个本地配方
    for _ in 0..<a.i1 do spawn_kind(idx)
}
prim_run_shield :: proc(a: PrimArgs) {
    shield_timer = max(shield_timer, a.f1)
}
prim_run_reverse :: proc(a: PrimArgs) {
    reverse_snake()
}
prim_run_score_mult :: proc(a: PrimArgs) {
    if a.f2 > 0 {
        score_mult = a.f1
        score_mult_timer = a.f2
    }
}

// --- describe(): one-line Chinese summaries for the editor UI (Run 2) ---

fmt_secs :: proc(t: f32) -> string { // "3秒" / "3.5秒" (temp allocator)
    if t == math.floor(t) do return fmt.tprintf("%d秒", int(t))
    return fmt.tprintf("%.1f秒", t)
}

describe_speed :: proc(a: PrimArgs, buf: []u8) -> string {
    if abs(a.f1 - 1) < 0.05 do return fmt.bprintf(buf, "速度不变")
    return fmt.bprintf(buf, "%s ×%.2f 持续%s", a.f1 < 1 ? "加速" : "减速", a.f1, fmt_secs(a.f2))
}
describe_growth :: proc(a: PrimArgs, buf: []u8) -> string {
    if a.i1 > 0 do return fmt.bprintf(buf, "长%d节", a.i1)
    if a.i1 < 0 do return fmt.bprintf(buf, "炸掉%d节尾巴", -a.i1)
    return fmt.bprintf(buf, "长度不变")
}
describe_score :: proc(a: PrimArgs, buf: []u8) -> string {
    if a.i1 >= 0 do return fmt.bprintf(buf, "分数+%d", a.i1)
    return fmt.bprintf(buf, "分数%d", a.i1)
}
describe_shake :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "震屏 %.1f", a.f1)
}
describe_confuse :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "眩晕 %s", fmt_secs(a.f1))
}
describe_flash :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "全屏闪光（%d,%d,%d）", a.col.r, a.col.g, a.col.b)
}
describe_burst :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "粒子烟花 ×%d", a.i1)
}
describe_spawn_food :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "下%d个蛋（%s）", a.i1, a.s1)
}
describe_shield :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "无敌护盾 %s", fmt_secs(a.f1))
}
describe_reverse :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "掉头反转")
}
describe_score_mult :: proc(a: PrimArgs, buf: []u8) -> string {
    return fmt.bprintf(buf, "得分 ×%.1f 持续%s", a.f1, fmt_secs(a.f2))
}

init_primitives :: proc() {
    register_primitive({"speed",      prim_run_speed,      describe_speed})
    register_primitive({"growth",     prim_run_growth,     describe_growth})
    register_primitive({"score",      prim_run_score,      describe_score})
    register_primitive({"shake",      prim_run_shake,      describe_shake})
    register_primitive({"confuse",    prim_run_confuse,    describe_confuse})
    register_primitive({"flash",      prim_run_flash,      describe_flash})
    register_primitive({"burst",      prim_run_burst,      describe_burst})
    register_primitive({"spawn_food", prim_run_spawn_food, describe_spawn_food})
    register_primitive({"shield",     prim_run_shield,     describe_shield})
    register_primitive({"reverse",    prim_run_reverse,    describe_reverse})
    register_primitive({"score_mult", prim_run_score_mult, describe_score_mult})
}

// --- generic JSON tree helpers ---

jnumv :: proc(v: json.Value, def: f64) -> f64 {
    #partial switch x in v {
    case json.Integer: return f64(x)
    case json.Float:   return x
    case json.Boolean: return x ? 1 : 0
    }
    return def
}

jnum :: proc(obj: json.Object, key: string, def: f64) -> f64 {
    v, ok := obj[key]
    if !ok do return def
    return jnumv(v, def)
}

jstr :: proc(obj: json.Object, key: string) -> (string, bool) {
    v, ok := obj[key]
    if !ok do return "", false
    s, sok := v.(json.String)
    if !sok do return "", false
    return s, true
}

jstr_or :: proc(obj: json.Object, key: string, def: string) -> string {
    s, ok := jstr(obj, key)
    return ok ? s : def
}

write_json_string :: proc(sb: ^strings.Builder, s: string) {
    esc, err := json.marshal(s, allocator = context.temp_allocator)
    if err != nil {
        strings.write_string(sb, `""`)
        return
    }
    strings.write_string(sb, string(esc))
}

// compact re-serializer for parsed subtrees (json.marshal pads floats to 16
// decimals, which would bloat share codes); object key order is normalized
// away — comparisons should use blueprint_summary, not string equality
jwrite :: proc(sb: ^strings.Builder, v: json.Value) {
    switch x in v {
    case json.Null:    strings.write_string(sb, "null")
    case json.Boolean: strings.write_string(sb, x ? "true" : "false")
    case json.Integer: fmt.sbprintf(sb, "%d", x)
    case json.Float:   fmt.sbprintf(sb, "%g", x)
    case json.String:  write_json_string(sb, x)
    case json.Array:
        strings.write_string(sb, "[")
        for e, i in x {
            if i > 0 do strings.write_string(sb, ",")
            jwrite(sb, e)
        }
        strings.write_string(sb, "]")
    case json.Object:
        strings.write_string(sb, "{")
        first := true
        for k, e in x {
            if !first do strings.write_string(sb, ",")
            first = false
            write_json_string(sb, k)
            strings.write_string(sb, ":")
            jwrite(sb, e)
        }
        strings.write_string(sb, "}")
    }
}

// --- compiler: blueprint JSON tree -> []ScheduledAction (relative times) ---

Bp_Ctx :: struct {
    actions: [dynamic]ScheduledAction,
    extra:   ^map[string]string, // bundled macros available during validation
    depth:   int,                // current macro expansion depth
    failed:  bool,
    allow_missing_use: bool,     // creations.json load: `use` of a deleted macro is skipped, not fatal
}

// single-key node destructuring; every blueprint node has exactly one key
bp_node_kv :: proc(node: json.Value) -> (string, json.Value, bool) {
    obj, ok := node.(json.Object)
    if !ok || len(obj) != 1 do return "", nil, false
    for k, v in obj do return k, v, true
    return "", nil, false
}

macro_lookup :: proc(name: string, extra: ^map[string]string) -> (string, bool) {
    if src, ok := macros[name]; ok do return src, true // local macros win
    if extra != nil {
        if src, ok := extra^[name]; ok do return src, true
    }
    return "", false
}

// per-primitive argument extraction + clamping (ranges mirror clamp_recipe).
// Adding a primitive = one register_primitive call + one case here.
bp_parse_args :: proc(prim_name: string, val: json.Value) -> (PrimArgs, bool) {
    o, ok := val.(json.Object)
    if !ok do return {}, false
    args: PrimArgs
    switch prim_name {
    case "speed":
        args.f1 = clamp(f32(jnum(o, "mult", 1)), 0.45, 2.0)
        args.f2 = clamp(f32(jnum(o, "secs", 0)), 0, 8)
    case "growth":
        args.i1 = clamp(int(jnum(o, "n", 0)), -6, 6)
    case "score":
        args.i1 = clamp(int(jnum(o, "n", 0)), -50, 100)
    case "shake":
        args.f1 = clamp(f32(jnum(o, "s", 0)), 0, 1)
    case "confuse":
        args.f1 = clamp(f32(jnum(o, "secs", 0)), 0, 6)
    case "flash":
        args.col = {u8(clamp(int(jnum(o, "r", 255)), 0, 255)),
                    u8(clamp(int(jnum(o, "g", 255)), 0, 255)),
                    u8(clamp(int(jnum(o, "b", 255)), 0, 255)), 90}
    case "burst":
        args.i1 = clamp(int(jnum(o, "n", 1)), 1, 4)
    case "spawn_food":
        kind, sok := jstr(o, "kind")
        if !sok || kind == "" do return {}, false
        args.s1 = strings.clone(kind) // owned; the queue frees it after the run
        args.i1 = clamp(int(jnum(o, "count", 1)), 1, 4)
    case "shield":
        args.f1 = clamp(f32(jnum(o, "secs", 0)), 0, 10)
    case "reverse":
        // no args
    case "score_mult":
        args.f1 = clamp(f32(jnum(o, "mult", 1)), 1, 4)
        args.f2 = clamp(f32(jnum(o, "secs", 0)), 0, 15)
    case:
        return {}, false
    }
    return args, true
}

bp_walk_list :: proc(list: json.Array, t: ^f32, ctx: ^Bp_Ctx) {
    for node in list {
        if ctx.failed do return
        bp_walk_node(node, t, ctx)
    }
}

bp_walk_node :: proc(node: json.Value, t: ^f32, ctx: ^Bp_Ctx) {
    key, val, ok := bp_node_kv(node)
    if !ok { ctx.failed = true; return }
    switch key {
    case "delay": // shifts the schedule time of all FOLLOWING siblings
        a, aok := val.(json.Object)
        if !aok { ctx.failed = true; return }
        secs := f32(jnum(a, "secs", 0))
        if secs > BP_MAX_DELAY { ctx.failed = true; return }
        t^ += max(secs, 0)
    case "repeat": // unroll children n times at compile time
        a, aok := val.(json.Object)
        if !aok { ctx.failed = true; return }
        n := int(jnum(a, "n", 0))
        if n < 1 || n > BP_MAX_REPEAT { ctx.failed = true; return }
        dv, dok := a["do"]
        arr, arrok := dv.(json.Array)
        if !dok || !arrok { ctx.failed = true; return }
        for _ in 0..<n {
            bp_walk_list(arr, t, ctx)
            if ctx.failed do return
        }
    case "chance": // roll once at compile (eat) time
        a, aok := val.(json.Object)
        if !aok { ctx.failed = true; return }
        p := clamp(f32(jnum(a, "p", 0)), 0, 1)
        dv, dok := a["do"]
        arr, arrok := dv.(json.Array)
        if !dok || !arrok { ctx.failed = true; return }
        if rand.float32() < p do bp_walk_list(arr, t, ctx)
    case "use": // inline a user macro's blueprint tree
        a, aok := val.(json.Object)
        if !aok { ctx.failed = true; return }
        name, sok := jstr(a, "name")
        if !sok || name == "" { ctx.failed = true; return }
        if ctx.depth >= BP_MAX_DEPTH { ctx.failed = true; return } // cycles die here
        src, found := macro_lookup(name, ctx.extra)
        if !found {
            if ctx.allow_missing_use do return // 作品库加载：容忍已被删除的原语引用
            ctx.failed = true
            return
        }
        sub, perr := json.parse(transmute([]u8)src, .JSON, true, context.allocator)
        if perr != nil { ctx.failed = true; return }
        defer json.destroy_value(sub, context.allocator)
        sk, sv, sok2 := bp_node_kv(sub)
        sarr, saok := sv.(json.Array)
        if !sok2 || sk != "do" || !saok { ctx.failed = true; return }
        ctx.depth += 1
        bp_walk_list(sarr, t, ctx)
        ctx.depth -= 1
    case: // action primitives live in the registry
        if _, pok := primitives[key]; !pok { ctx.failed = true; return } // unknown node
        args, aok := bp_parse_args(key, val)
        if !aok { ctx.failed = true; return }
        if len(ctx.actions) >= BP_MAX_ACTIONS { ctx.failed = true; return }
        append(&ctx.actions, ScheduledAction{at = t^, prim = &primitives[key], args = args})
    }
}

// bp_compile: blueprint JSON -> scheduled actions (times relative to now).
// Any structural violation or unknown node key fails the whole compile;
// the caller then falls back to the kind's classic fx fields.
bp_compile :: proc(json_text: string, extra: ^map[string]string = nil) -> ([dynamic]ScheduledAction, bool) {
    return bp_compile_flags(json_text, extra, false)
}

bp_compile_flags :: proc(json_text: string, extra: ^map[string]string, allow_missing_use: bool) -> ([dynamic]ScheduledAction, bool) {
    root, err := json.parse(transmute([]u8)json_text, .JSON, true, context.allocator)
    if err != nil do return nil, false
    defer json.destroy_value(root, context.allocator)
    key, val, ok := bp_node_kv(root)
    arr, aok := val.(json.Array)
    if !ok || key != "do" || !aok do return nil, false
    ctx := Bp_Ctx{extra = extra, allow_missing_use = allow_missing_use}
    ctx.actions = make([dynamic]ScheduledAction, 0, 8)
    t := f32(0)
    bp_walk_list(arr, &t, &ctx)
    if ctx.failed {
        bp_free_actions(&ctx.actions)
        return nil, false
    }
    return ctx.actions, true
}

// creations.json load: structural validation that skips `use` nodes whose
// macro no longer exists (eat-time strict compile falls back with 蓝图无效)
bp_validate_lenient :: proc(json_text: string) -> bool {
    actions, ok := bp_compile_flags(json_text, nil, true)
    if !ok do return false
    bp_free_actions(&actions)
    return true
}

bp_free_actions :: proc(actions: ^[dynamic]ScheduledAction) {
    for a in actions^ {
        if a.args.s1 != "" do delete(a.args.s1)
    }
    delete(actions^)
    actions^ = nil
}

// --- runtime scheduler (play_clock-relative queue) ---

clear_sched_queue :: proc() {
    for a in sched_queue {
        if a.args.s1 != "" do delete(a.args.s1)
    }
    clear(&sched_queue)
}

enqueue_actions :: proc(actions: []ScheduledAction) {
    for a in actions {
        act := a
        act.at += play_clock
        append(&sched_queue, act)
    }
}

// pop and run everything due; earliest first, queue order breaks ties
run_scheduled :: proc() {
    for {
        idx := -1
        for a, i in sched_queue {
            if a.at <= play_clock && (idx < 0 || a.at < sched_queue[idx].at) {
                idx = i
            }
        }
        if idx < 0 do break
        a := sched_queue[idx]
        ordered_remove(&sched_queue, idx) // out of the queue BEFORE running
        a.prim.run(a.args)
        if a.args.s1 != "" do delete(a.args.s1)
        if state != .PLAYING do break // an action may have killed the snake
    }
}

// --- user macros （自创新原语 v0): name -> blueprint tree, persisted ---

MACROS_FILE :: "macros.json"

macro_define :: proc(name: string, blueprint_json: string) -> bool {
    if name == "" do return false
    // validate by test-compiling (depth guard catches cycles at use time)
    actions, ok := bp_compile(blueprint_json)
    if !ok do return false
    bp_free_actions(&actions)
    if old, has := macros[name]; has {
        delete(old) // existing key pointer is kept on update
        macros[name] = strings.clone(blueprint_json)
    } else {
        macros[strings.clone(name)] = strings.clone(blueprint_json)
    }
    save_macros()
    return true
}

macro_delete :: proc(name: string) -> bool {
    if _, ok := macros[name]; !ok do return false
    k, v := delete_key(&macros, name)
    delete(k)
    delete(v)
    save_macros()
    return true
}

save_macros :: proc() {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, `{"macros":{`)
    first := true
    for name, text in macros {
        if !first do strings.write_string(&sb, ",")
        first = false
        write_json_string(&sb, name)
        strings.write_string(&sb, ":")
        strings.write_string(&sb, text)
    }
    strings.write_string(&sb, "}}")
    _ = os.write_entire_file(MACROS_FILE, transmute([]u8)strings.to_string(sb))
}

load_macros :: proc() {
    data, err := os.read_entire_file(MACROS_FILE, context.temp_allocator)
    if err != nil do return
    root, perr := json.parse(data, .JSON, true, context.temp_allocator)
    if perr != nil do return
    obj, ok := root.(json.Object)
    if !ok do return
    mv, mok := obj["macros"]
    mo, mook := mv.(json.Object)
    if !mok || !mook do return
    // pass 1: load everything raw (order-independent for cross-references)
    for name, val in mo {
        if _, has := macros[name]; has do continue
        sb := strings.builder_make(context.temp_allocator)
        jwrite(&sb, val)
        macros[strings.clone(name)] = strings.clone(strings.to_string(sb))
    }
    // pass 2: drop anything that no longer compiles (broken/cyclic leftovers)
    stale: [dynamic]string
    for name, text in macros {
        actions, cok := bp_compile(text)
        if cok {
            bp_free_actions(&actions)
        } else {
            append(&stale, name)
        }
    }
    for name in stale do _ = macro_delete(name)
    if len(stale) > 0 {
        delete(stale)
        save_macros()
    }
}

// every macro name a blueprint (transitively) references — for share export
collect_macro_bundle :: proc(bp_text: string, allocator := context.temp_allocator) -> map[string]string {
    out := make(map[string]string, allocator = allocator)
    visited := make(map[string]bool, allocator = context.temp_allocator)
    bundle_walk_text(bp_text, &out, &visited, 0, allocator)
    return out
}

bundle_walk_text :: proc(text: string, out: ^map[string]string, visited: ^map[string]bool, depth: int, allocator: mem.Allocator) {
    if depth > BP_MAX_DEPTH + 1 do return
    root, err := json.parse(transmute([]u8)text, .JSON, true, context.temp_allocator)
    if err != nil do return
    bundle_walk_value(root, out, visited, depth, allocator)
}

bundle_walk_value :: proc(v: json.Value, out: ^map[string]string, visited: ^map[string]bool, depth: int, allocator: mem.Allocator) {
    #partial switch x in v {
    case json.Array:
        for e in x do bundle_walk_value(e, out, visited, depth, allocator)
    case json.Object:
        if len(x) == 1 {
            if uv, ok := x["use"]; ok {
                if uo, uok := uv.(json.Object); uok {
                    if name, sok := jstr(uo, "name"); sok && !visited^[name] {
                        visited^[name] = true
                        if src, has := macros[name]; has {
                            out^[strings.clone(name, allocator)] = strings.clone(src, allocator)
                            bundle_walk_text(src, out, visited, depth + 1, allocator)
                        }
                    }
                }
            }
        }
        for _, e in x do bundle_walk_value(e, out, visited, depth, allocator)
    }
}

// --- blueprint_summary: readable Chinese lines for the editor UI (Run 2) ---

// owned strings, caller keeps them
blueprint_summary :: proc(json_text: string) -> [dynamic]string {
    lines := make([dynamic]string, 0, 8, context.allocator)
    root, err := json.parse(transmute([]u8)json_text, .JSON, true, context.temp_allocator)
    if err != nil do return lines
    key, val, ok := bp_node_kv(root)
    arr, aok := val.(json.Array)
    if !ok || key != "do" || !aok do return lines
    t := f32(0)
    prefixes := make([dynamic]string, 0, 4, context.temp_allocator)
    summary_walk(arr, &t, &prefixes, &lines, 0)
    return lines
}

summary_walk :: proc(list: json.Array, t: ^f32, prefixes: ^[dynamic]string, lines: ^[dynamic]string, depth: int) {
    if depth > BP_MAX_DEPTH do return
    for node in list {
        key, val, ok := bp_node_kv(node)
        if !ok do continue
        switch key {
        case "delay":
            if a, aok := val.(json.Object); aok {
                t^ += clamp(f32(jnum(a, "secs", 0)), 0, BP_MAX_DELAY)
            }
        case "repeat":
            a, aok := val.(json.Object)
            if !aok do continue
            n := clamp(int(jnum(a, "n", 1)), 1, BP_MAX_REPEAT)
            dv, dok := a["do"]
            arr, arrok := dv.(json.Array)
            if !dok || !arrok do continue
            append(prefixes, fmt.tprintf("重复%d次 › ", n))
            summary_walk(arr, t, prefixes, lines, depth)
            _ = pop(prefixes)
        case "chance":
            a, aok := val.(json.Object)
            if !aok do continue
            p := clamp(f32(jnum(a, "p", 0)), 0, 1)
            dv, dok := a["do"]
            arr, arrok := dv.(json.Array)
            if !dok || !arrok do continue
            append(prefixes, fmt.tprintf("%d%%概率 › ", int(math.round(p * 100))))
            summary_walk(arr, t, prefixes, lines, depth)
            _ = pop(prefixes)
        case "use":
            a, aok := val.(json.Object)
            if !aok do continue
            name, sok := jstr(a, "name")
            if !sok do continue
            src, found := macro_lookup(name, nil)
            if !found {
                append(lines, strings.clone(fmt.tprintf("宏「%s」（未定义）", name)))
                continue
            }
            sub, perr := json.parse(transmute([]u8)src, .JSON, true, context.temp_allocator)
            if perr != nil do continue
            sk, sv, sok2 := bp_node_kv(sub)
            sarr, saok := sv.(json.Array)
            if sok2 && sk == "do" && saok {
                append(prefixes, fmt.tprintf("宏「%s」 › ", name))
                summary_walk(sarr, t, prefixes, lines, depth + 1)
                _ = pop(prefixes)
            }
        case:
            p, pok := primitives[key]
            if !pok do continue
            args, aok := bp_parse_args(key, val)
            if !aok do continue
            buf: [160]u8
            desc := p.describe(args, buf[:])
            if args.s1 != "" do delete(args.s1)
            sb := strings.builder_make(context.temp_allocator)
            for px in prefixes^ do strings.write_string(&sb, px)
            strings.write_string(&sb, t^ <= 0 ? "立刻：" : fmt.tprintf("%s后：", fmt_secs(t^)))
            strings.write_string(&sb, desc)
            append(lines, strings.clone(strings.to_string(sb), context.allocator))
        }
    }
}

// ---------------------------------------------------------------------------
// LLM recipe generation: worker thread + curl via a config file, so neither
// the API key nor the word ever appear on the command line.
// ---------------------------------------------------------------------------

LLM_SYSTEM_PROMPT :: `你在为一个3D贪吃蛇游戏设计食物。玩家给出食物名称，你只输出一个JSON对象，不要输出任何其他文字。字段：hue(0-359整数,符合该食物直觉颜色的色相), shape(0球1方块2圆锥3宝石,选最像的), rarity(0常见1稀有2传说,日常食物0,稀奇或离谱的1-2), flavor(不超过16字的中文幽默点评), fx对象:{speed_mult(0.45-2.0,小于1=加速,大于1=减速,1=无速度效果), speed_secs(0-8), growth(-6到6整数,正=长身体,负=炸掉尾巴), score(-50到100整数), shake(0-1,爆炸震屏), confuse(0-6,AI眩晕秒数), bursts(1-4,粒子烟花数), tint(全屏闪光颜色[r,g,b]各0-255,无闪光则null)}。要贴合食物真实特性:辣椒加速,冰棍减速,手榴弹炸尾,便便扣分,毒蘑菇眩晕;普通食物给温和正面效果;有害效果(负growth/负score/confuse大于0)必须有合理理由。`

// 创造台 ✨ 描述创意: the model translates a natural-language description into
// a full food design, blueprint included. Single-line prompts; json.marshal of
// the request escapes them. The currently defined macro names get baked in
// between HEAD and TAIL so the model can `use` them.
LLM_CREATIVE_PROMPT_HEAD :: `你在为一个3D贪吃蛇游戏设计一种创意食物。玩家描述想要的效果，你把它翻译成食物设计，只输出一个JSON对象，不要输出任何其他文字或markdown代码块。格式：{"name":"食物名(不超过8个汉字)","hue":0-359整数(符合直觉的色相),"shape":0-3整数(0球1方块2圆锥3宝石),"rarity":0-2整数(0常见1稀有2传说),"flavor":"不超过16字的中文幽默点评","blueprint":{"do":[节点列表]}}。blueprint的每个节点是只含一个键的对象。动作原语：{"speed":{"mult":0.45到2.0,"secs":0到8}}移速倍率，小于1=加速大于1=减速；{"growth":{"n":-6到6整数}}正=长身体负=炸掉尾巴；{"score":{"n":-50到100整数}}分数；{"shake":{"s":0到1}}震屏；{"confuse":{"secs":0到6}}AI眩晕秒数；{"flash":{"r":0到255,"g":0到255,"b":0到255}}全屏闪光；{"burst":{"n":1到4}}粒子烟花；{"spawn_food":{"kind":"食物名","count":1到4}}在场上生出新食物（下蛋）;{"shield":{"secs":0到10}}无敌金身；{"reverse":{}}蛇头尾掉头反转；{"score_mult":{"mult":1到4,"secs":0到15}}得分倍率。流程节点：{"delay":{"secs":0到30}}让其后的节点延迟执行；{"repeat":{"n":1到5,"do":[节点列表]}}重复；{"chance":{"p":0到1,"do":[节点列表]}}概率触发；{"use":{"name":"原语名"}}引用玩家自创原语。当前已定义的玩家原语：`

LLM_CREATIVE_PROMPT_TAIL :: `。限制：动作节点总数不超过32个，delay单次不超过30秒，repeat不超过5次，use嵌套不超过4层。设计要贴合玩家的描述，有戏剧性和节奏感，善用delay制造"先……然后……"的层次，强度可以大胆但不要完全无解。示例1，玩家说"下蛋"：{"name":"老母鸡","hue":40,"shape":0,"rarity":1,"flavor":"咯咯哒，新鲜出炉","blueprint":{"do":[{"spawn_food":{"kind":"神秘蛋","count":2}},{"score":{"n":10}}]}}。示例2，玩家说"火箭辣椒"：{"name":"火箭辣椒","hue":10,"shape":2,"rarity":2,"flavor":"先上天，再坠毁","blueprint":{"do":[{"speed":{"mult":0.5,"secs":4}},{"delay":{"secs":4}},{"growth":{"n":-2}},{"shake":{"s":0.6}},{"burst":{"n":3}}]}}。`

// built on the main thread (reads the macros map)
creative_system_prompt :: proc(allocator := context.temp_allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_string(&sb, LLM_CREATIVE_PROMPT_HEAD)
    first := true
    for name in macros {
        if !first do strings.write_string(&sb, "、")
        first = false
        fmt.sbprintf(&sb, "「%s」", name)
    }
    if first do strings.write_string(&sb, "无")
    strings.write_string(&sb, LLM_CREATIVE_PROMPT_TAIL)
    return strings.to_string(sb)
}

Creative_Result :: struct {
    name:      string, // owned clone
    hue:       int,
    shape:     int,
    rarity:    int,
    flavor:    string, // owned clone, may be ""
    blueprint: string, // owned clone, compact re-serialized
}

// pure function (headless-testable): parse the model's creative reply, clamp
// the scalar fields through the same ranges as clamp_recipe, and test-compile
// the blueprint with local macros. Any structural problem rejects the design.
creative_parse :: proc(content: string) -> (Creative_Result, bool) {
    res: Creative_Result
    c := strip_json_fences(content)
    if c == "" do return res, false
    root, err := json.parse(transmute([]u8)c, .JSON, true, context.temp_allocator)
    if err != nil do return res, false
    obj, ok := root.(json.Object)
    if !ok do return res, false
    bv, bok := obj["blueprint"]
    if !bok do return res, false // blueprint 必须存在
    bp: string
    #partial switch bvv in bv {
    case json.Object:
        sb := strings.builder_make(context.temp_allocator)
        jwrite(&sb, bv)
        bp = strings.to_string(sb)
    case json.String:
        bp = bvv // 模型偶尔会把蓝图再包一层字符串
    case:
        return res, false
    }
    acts, cok := bp_compile(bp) // 本地宏也参与校验
    if !cok do return res, false
    bp_free_actions(&acts)
    name := strings.trim_space(jstr_or(obj, "name", ""))
    res.name = strings.clone(name != "" ? name : "我的食物")
    res.flavor = strings.clone(jstr_or(obj, "flavor", ""))
    res.blueprint = strings.clone(bp)
    res.hue = int(jnum(obj, "hue", 0)) %% 360
    res.shape = clamp(int(jnum(obj, "shape", 0)), 0, 3)
    res.rarity = clamp(int(jnum(obj, "rarity", 0)), 0, 2)
    return res, true
}

creative_free :: proc(res: ^Creative_Result) {
    if res.name != "" do delete(res.name)
    if res.flavor != "" do delete(res.flavor)
    if res.blueprint != "" do delete(res.blueprint)
    res^ = {}
}

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

LLM_Job_Mode :: enum { RECIPE, CREATIVE } // RECIPE = word cast; CREATIVE = 创造台创意描述

LLM_Job :: struct {
    word:   string,      // heap clone owned by the worker, freed when done
    mode:   LLM_Job_Mode,
    system: string,      // CREATIVE only: prompt with macro names baked in (main thread built)
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
    job.mode = .RECIPE
    job.system = ""
    sync.mutex_lock(&llm_mutex)
    llm_state = .COOKING
    llm_job_mode = .RECIPE
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

// 创造台 ✨ 描述创意: a second job class through the same worker infra.
// Only one job of any kind may be in flight; returns false when busy.
llm_start_creative :: proc(desc: string) -> bool {
    if !llm_enabled do return false
    sync.mutex_lock(&llm_mutex)
    busy := llm_state == .COOKING
    sync.mutex_unlock(&llm_mutex)
    if busy do return false
    job := new(LLM_Job)
    job.word = strings.clone(desc)
    job.mode = .CREATIVE
    // the system prompt must be built on the main thread: it reads the
    // macros map, which the worker must never touch
    job.system = strings.clone(creative_system_prompt(), context.allocator)
    sync.mutex_lock(&llm_mutex)
    llm_state = .COOKING
    llm_job_mode = .CREATIVE
    sync.mutex_unlock(&llm_mutex)
    if thread.create_and_start_with_data(job, llm_worker, nil, .Normal, true) == nil {
        llm_state = .IDLE
        llm_job_mode = .RECIPE
        delete(job.word)
        delete(job.system)
        free(job)
        return false
    }
    return true
}

llm_worker :: proc(data: rawptr) {
    // NOTE: runs off the main thread — never call raylib here
    job := cast(^LLM_Job)data
    recipe: Recipe
    creative: string // raw model output handed to the main thread on success
    ok := false
    defer {
        sync.mutex_lock(&llm_mutex)
        if ok {
            if job.mode == .CREATIVE {
                llm_creative_raw = creative
            } else {
                llm_recipe = recipe
            }
        }
        llm_state = ok ? LLM_State.READY : LLM_State.FAILED
        sync.mutex_unlock(&llm_mutex)
        delete(job.word)
        if job.system != "" do delete(job.system)
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
    sys_prompt := job.mode == .CREATIVE ? job.system : LLM_SYSTEM_PROMPT
    req := LLM_Chat_Request{
        model = llm_model, temperature = 0.9,
        messages = {
            {role = "system", content = sys_prompt},
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
    if job.mode == .CREATIVE {
        // parsing lives on the main thread (creative_parse is pure + tested)
        creative = strings.clone(content)
        ok = true
        return
    }
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
    mode := llm_job_mode
    raw := llm_creative_raw
    llm_creative_raw = ""
    if st != .COOKING do llm_state = .IDLE
    sync.mutex_unlock(&llm_mutex)

    if mode == .CREATIVE {
        // 创造台 ✨ 描述创意: parse here on the main thread; if the editor was
        // closed in the meantime the design is simply discarded
        llm_job_mode = .RECIPE
        if raw != "" {
            defer delete(raw)
            if st == .READY {
                res, cok := creative_parse(raw)
                if !cok {
                    if editor_open do set_toast("AI 设计无效，请换个说法")
                } else if editor_open {
                    editor_apply_creative(&res)
                    set_toast("AI 设计完成")
                } else {
                    creative_free(&res)
                }
            }
        }
        if st == .FAILED && editor_open {
            set_toast("AI 设计失败，请重试或手动设计")
        }
        if llm_word != "" {
            delete(llm_word)
            llm_word = ""
        }
        llm_kind_idx = -1
        return
    }

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

// --- self-test helpers: inspect creations.json without touching memory ---

// how many entries creations.json currently holds (-1 = unreadable/invalid)
creations_file_count :: proc() -> int {
    data, err := os.read_entire_file(CREATIONS_FILE, context.temp_allocator)
    if err != nil do return -1
    root, perr := json.parse(data, .JSON, true, context.temp_allocator)
    if perr != nil do return -1
    obj, ok := root.(json.Object)
    if !ok do return -1
    cv, cok := obj["creations"]
    arr, aok := cv.(json.Array)
    if !cok || !aok do return -1
    return len(arr)
}

// does creations.json contain an entry with this name?
creations_file_has :: proc(name: string) -> bool {
    data, err := os.read_entire_file(CREATIONS_FILE, context.temp_allocator)
    if err != nil do return false
    root, perr := json.parse(data, .JSON, true, context.temp_allocator)
    if perr != nil do return false
    obj, ok := root.(json.Object)
    if !ok do return false
    cv, cok := obj["creations"]
    arr, aok := cv.(json.Array)
    if !cok || !aok do return false
    for e in arr {
        eo, eok := e.(json.Object)
        if eok && jstr_or(eo, "name", "") == name do return true
    }
    return false
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
        "SNAKE3D1.eyJ2IjoyfQ",       // {"v":2} without name/fx — invalid v2
    }
    for bad in bads {
        if _, ok4 := import_share_code(bad); ok4 {
            fmt.println("SELFTEST FAIL: bad code accepted:", bad)
            return false
        }
    }

    fmt.println("roundtrip+clamp+reject: PASS")

    // ================= Phase 2: blueprint engine + share v2 =================
    // snapshot macros.json so the self-test never clobbers a real user file
    orig_macros: []u8
    orig_macros_exists := false
    if d, err := os.read_entire_file(MACROS_FILE, context.allocator); err == nil {
        orig_macros = d
        orig_macros_exists = true
    }
    // same for creator.txt (T13 exercises the nickname persistence)
    orig_creator: []u8
    orig_creator_exists := false
    if d, err := os.read_entire_file(CREATOR_FILE, context.allocator); err == nil {
        orig_creator = d
        orig_creator_exists = true
    }

    // --- T1: v1 share codes still decode (backward compat) ---
    v1 := Share_Recipe{v = 1, name = "古典苹果", hue = 5, shape = 0, rarity = 0,
        flavor = "来自v1", fx = {speed_mult = 1, speed_secs = 0, growth = 1,
        score = 10, shake = 0, confuse = 0, bursts = 1}}
    v1raw, _ := json.marshal(v1, allocator = context.temp_allocator)
    v1b64, _ := base64.encode(v1raw, base64.ENC_URL_TABLE, context.temp_allocator)
    v1code := strings.concatenate({SHARE_PREFIX, strings.trim_right(v1b64, "=")}, context.temp_allocator)
    v1idx, v1ok := import_share_code(v1code)
    if !v1ok || kinds[v1idx].name != "古典苹果" || kinds[v1idx].blueprint != "" ||
       kinds[v1idx].fx_score != 10 || kinds[v1idx].flavor != "来自v1" {
        fmt.println("SELFTEST FAIL: v1 share code decode")
        return false
    }
    fmt.println("v1 compat: PASS")

    // --- T2: v2 roundtrip with blueprint + macro bundle + byline ---
    if !macro_define("自测宏", `{"do":[{"growth":{"n":1}}]}`) {
        fmt.println("SELFTEST FAIL: macro_define 自测宏")
        return false
    }
    bp_src := `{"do":[{"growth":{"n":2}},{"use":{"name":"自测宏"}},{"delay":{"secs":1}},{"spawn_food":{"kind":"神秘蛋","count":2}}]}`
    append(&kinds, FoodKind{
        name = strings.clone("蓝图果"), author = "本地", flavor = strings.clone("自作蓝图"),
        hue = 100, color = hsv_rgb(100, 0.72, 1.0), shape = .GEM, size = 0.3, spin = 2,
        rarity = 2, fx_growth = 1, fx_score = 10, fx_bursts = 2,
        blueprint = strings.clone(bp_src), byline = strings.clone("测试员"),
    })
    kind_by_name["蓝图果"] = len(kinds) - 1
    bp_code := export_share_code(len(kinds) - 1, context.allocator)
    {   // inspect the wire payload itself
        payload := bp_code[len(SHARE_PREFIX):]
        padded := payload
        switch len(payload) % 4 {
        case 2: padded = strings.concatenate({payload, "=="}, context.temp_allocator)
        case 3: padded = strings.concatenate({payload, "="}, context.temp_allocator)
        }
        raw, derr := base64.decode(padded, base64.DEC_URL_TABLE, allocator = context.temp_allocator)
        wroot, werr := json.parse(raw, .JSON, true, context.temp_allocator)
        wire_ok := derr == nil && werr == nil
        if wire_ok {
            wobj, wok := wroot.(json.Object)
            _, has_bp := wobj["blueprint"]
            mv, has_m := wobj["macros"]
            mo, mok := mv.(json.Object)
            _, has_zc := mo["自测宏"]
            wire_ok = wok && int(jnum(wobj, "v", 0)) == 2 && has_bp && has_m && mok &&
                      has_zc && jstr_or(wobj, "by", "") == "测试员"
        }
        if !wire_ok {
            fmt.println("SELFTEST FAIL: v2 wire payload missing v/blueprint/macros/by")
            return false
        }
    }
    bp_idx, bp_ok := import_share_code(bp_code)
    if !bp_ok {
        fmt.println("SELFTEST FAIL: v2 import rejected own export")
        return false
    }
    nk := kinds[bp_idx]
    same_v2 := nk.name == "蓝图果~2" && nk.hue == 100 && nk.shape == .GEM &&
        nk.rarity == 2 && nk.flavor == "自作蓝图" && nk.fx_growth == 1 &&
        nk.fx_score == 10 && nk.byline == "测试员" && nk.blueprint != ""
    if !same_v2 {
        fmt.println("SELFTEST FAIL: v2 field mismatch:", nk.name, nk.byline, nk.blueprint)
        return false
    }
    // blueprint survived the wire: summary lines must match exactly
    sum1 := blueprint_summary(bp_src)
    sum2 := blueprint_summary(nk.blueprint)
    if len(sum1) == 0 || len(sum1) != len(sum2) {
        fmt.println("SELFTEST FAIL: v2 blueprint summary length mismatch")
        return false
    }
    for l, li in sum1 {
        if l != sum2[li] {
            fmt.println("SELFTEST FAIL: v2 blueprint summary mismatch:", l, "vs", sum2[li])
            return false
        }
    }
    { // decoded blueprint test-compiles; local 自测宏 was NOT overwritten
        dacts, dok := bp_compile(nk.blueprint)
        if !dok {
            fmt.println("SELFTEST FAIL: v2 decoded blueprint does not compile")
            return false
        }
        bp_free_actions(&dacts)
        if macros["自测宏"] != `{"do":[{"growth":{"n":1}}]}` {
            fmt.println("SELFTEST FAIL: bundled macro overwrote a local macro")
            return false
        }
    }
    fmt.println("v2 roundtrip: PASS")

    // --- T3: compile + schedule with delay ---
    game_mode = .FEEDING
    reset_game()
    state = .PLAYING
    clear(&foods)
    start_len := len(snake)
    acts, cok := bp_compile(`{"do":[{"growth":{"n":2}},{"delay":{"secs":3}},{"growth":{"n":-1}}]}`)
    if !cok || len(acts) != 2 || acts[0].at != 0 || acts[1].at != 3 {
        fmt.println("SELFTEST FAIL: delay compile", len(acts), cok)
        return false
    }
    enqueue_actions(acts[:])
    delete(acts)
    run_scheduled() // play_clock == 0: +2 pending growth
    if pending_growth != 2 || len(snake) != start_len {
        fmt.println("SELFTEST FAIL: schedule t=0")
        return false
    }
    play_clock = 3.0
    run_scheduled() // t=3: blast 1 tail segment
    if len(snake) != start_len - 1 || pending_growth != 2 {
        fmt.println("SELFTEST FAIL: schedule t=3 (net +1 segment expected)")
        return false
    }
    fmt.println("compile+schedule: PASS")

    // --- T4: chance + repeat ---
    ch0, ch0ok := bp_compile(`{"do":[{"chance":{"p":0,"do":[{"growth":{"n":1}}]}}]}`)
    if !ch0ok || len(ch0) != 0 {
        fmt.println("SELFTEST FAIL: chance p=0 emitted", len(ch0))
        return false
    }
    delete(ch0)
    ch1, ch1ok := bp_compile(`{"do":[{"chance":{"p":1,"do":[{"growth":{"n":1}}]}}]}`)
    if !ch1ok || len(ch1) != 1 {
        fmt.println("SELFTEST FAIL: chance p=1 emitted", len(ch1))
        return false
    }
    bp_free_actions(&ch1)
    rp, rpok := bp_compile(`{"do":[{"repeat":{"n":3,"do":[{"growth":{"n":1}}]}}]}`)
    if !rpok || len(rp) != 3 {
        fmt.println("SELFTEST FAIL: repeat n=3 emitted", len(rp))
        return false
    }
    bp_free_actions(&rp)
    fmt.println("chance/repeat: PASS")

    // --- T5: spawn_food grows the foods array ---
    clear(&foods)
    sp, spok := bp_compile(`{"do":[{"spawn_food":{"kind":"神秘蛋","count":2}}]}`)
    if !spok || len(sp) != 1 {
        fmt.println("SELFTEST FAIL: spawn_food compile")
        return false
    }
    enqueue_actions(sp[:])
    delete(sp)
    run_scheduled()
    if len(foods) != 2 {
        fmt.println("SELFTEST FAIL: spawn_food spawned", len(foods))
        return false
    }
    fmt.println("spawn_food: PASS")

    // --- T6: reverse flips snake + dir ---
    reset_game()
    state = .PLAYING
    rv, rvok := bp_compile(`{"do":[{"reverse":{}}]}`)
    if !rvok || len(rv) != 1 {
        fmt.println("SELFTEST FAIL: reverse compile")
        return false
    }
    enqueue_actions(rv[:])
    delete(rv)
    run_scheduled()
    if snake[0] != (IV3{GRID_N - 1, GRID_N / 2, GRID_N / 2 - 2}) ||
       snake[len(snake) - 1] != (IV3{GRID_N - 1, GRID_N / 2, GRID_N / 2}) ||
       dir != (IV3{0, 0, -1}) {
        fmt.println("SELFTEST FAIL: reverse", snake[0], snake[len(snake) - 1], dir)
        return false
    }
    fmt.println("reverse: PASS")

    // --- T7: score_mult multiplies the scoring path ---
    reset_game()
    state = .PLAYING
    score = 0
    sm, smok := bp_compile(`{"do":[{"score_mult":{"mult":2,"secs":10}},{"score":{"n":25}}]}`)
    if !smok || len(sm) != 2 {
        fmt.println("SELFTEST FAIL: score_mult compile")
        return false
    }
    enqueue_actions(sm[:])
    delete(sm)
    run_scheduled()
    if score != 50 || score_mult != 2 {
        fmt.println("SELFTEST FAIL: score_mult blueprint path", score, score_mult)
        return false
    }
    add_score(10) // classic fx path goes through the multiplier too
    if score != 70 {
        fmt.println("SELFTEST FAIL: score_mult classic path", score)
        return false
    }
    score_mult = 1
    score_mult_timer = 0
    fmt.println("score_mult: PASS")

    // --- T8: shield survives lethal collisions ---
    map_clear()
    reset_game()
    state = .PLAYING
    wall8, _, ok8 := advance_on_sphere(snake[0], dir)
    if !ok8 {
        fmt.println("SELFTEST FAIL: shield setup, no geodesic step")
        return false
    }
    map_set(wall8, true)
    map_finalize()
    autopilot = false
    shield_timer = 5
    step() // 金身穿墙：头进入实心格，不死
    if state != .PLAYING || snake[0] != wall8 {
        fmt.println("SELFTEST FAIL: shield wall hit", state, snake[0])
        return false
    }
    shield_timer = 0
    // 头还在墙里：把所有六邻焊死，无护盾再走必须撞死
    for off in DIRS6 {
        c := IV3{snake[0].x + off.x, snake[0].y + off.y, snake[0].z + off.z}
        if cell_in_world(c) do map_set(c, true)
    }
    map_finalize()
    step()
    if state != .GAME_OVER {
        fmt.println("SELFTEST FAIL: unshielded wall hit did not kill")
        return false
    }
    death_squawk = false // headless: nobody will consume the sound request
    fmt.println("shield: PASS")

    // --- T9: structural violations fail compilation ---
    macros[strings.clone("链1")] = strings.clone(`{"do":[{"use":{"name":"链2"}}]}`)
    macros[strings.clone("链2")] = strings.clone(`{"do":[{"use":{"name":"链3"}}]}`)
    macros[strings.clone("链3")] = strings.clone(`{"do":[{"use":{"name":"链4"}}]}`)
    macros[strings.clone("链4")] = strings.clone(`{"do":[{"use":{"name":"链5"}}]}`)
    macros[strings.clone("链5")] = strings.clone(`{"do":[{"growth":{"n":1}}]}`)
    if _, dbok := bp_compile(`{"do":[{"use":{"name":"链1"}}]}`); dbok {
        fmt.println("SELFTEST FAIL: 5-deep use-chain compiled")
        return false
    }
    chain_names := [?]string{"链1", "链2", "链3", "链4", "链5"}
    for cn in chain_names {
        ck, cv := delete_key(&macros, cn)
        delete(ck)
        delete(cv)
    }
    if _, unok := bp_compile(`{"do":[{"teleport":{}}]}`); unok {
        fmt.println("SELFTEST FAIL: unknown node compiled")
        return false
    }
    if _, ovok := bp_compile(`{"do":[{"repeat":{"n":5,"do":[{"growth":{"n":1}},{"growth":{"n":1}},{"growth":{"n":1}},{"growth":{"n":1}},{"growth":{"n":1}},{"growth":{"n":1}},{"growth":{"n":1}}]}}]}`); ovok {
        fmt.println("SELFTEST FAIL: 35 emissions compiled (budget 32)")
        return false
    }
    fmt.println("compile failures: PASS")

    // --- T10: macros define/use/persist/cyclic/delete ---
    if !macro_define("测试烟花", `{"do":[{"burst":{"n":2}}]}`) {
        fmt.println("SELFTEST FAIL: macro_define 测试烟花")
        return false
    }
    fw, fwok := bp_compile(`{"do":[{"use":{"name":"测试烟花"}}]}`)
    if !fwok || len(fw) != 1 {
        fmt.println("SELFTEST FAIL: use-macro compile")
        return false
    }
    {
        n_part := len(particles)
        enqueue_actions(fw[:])
        delete(fw)
        run_scheduled()
        if len(particles) <= n_part {
            fmt.println("SELFTEST FAIL: macro burst emitted no particles")
            return false
        }
    }
    {   // macros.json persisted with both macros
        mdata, merr := os.read_entire_file(MACROS_FILE, context.temp_allocator)
        mroot, mperr := json.parse(mdata, .JSON, true, context.temp_allocator)
        mobj, mok2 := mroot.(json.Object)
        mmv, _ := mobj["macros"]
        mmo, mmok := mmv.(json.Object)
        _, has_fw := mmo["测试烟花"]
        _, has_zc := mmo["自测宏"]
        if merr != nil || mperr != nil || !mok2 || !mmok || !has_fw || !has_zc {
            fmt.println("SELFTEST FAIL: macros.json persistence")
            return false
        }
    }
    if macro_define("循环", `{"do":[{"use":{"name":"循环"}}]}`) {
        fmt.println("SELFTEST FAIL: cyclic macro accepted")
        return false
    }
    if !macro_delete("测试烟花") {
        fmt.println("SELFTEST FAIL: macro_delete")
        return false
    }
    if _, has := macros["测试烟花"]; has {
        fmt.println("SELFTEST FAIL: macro still present after delete")
        return false
    }
    fmt.println("macros: PASS")

    // --- T11: blueprint_summary produces readable Chinese lines ---
    sl := blueprint_summary(`{"do":[{"growth":{"n":2}},{"delay":{"secs":3}},{"spawn_food":{"kind":"神秘蛋","count":2}}]}`)
    if len(sl) != 2 || !strings.contains(sl[0], "立刻") ||
       !strings.contains(sl[1], "3秒后") || !strings.contains(sl[1], "神秘蛋") {
        fmt.println("SELFTEST FAIL: blueprint_summary", sl)
        return false
    }
    sl2 := blueprint_summary(`{"do":[{"chance":{"p":0.5,"do":[{"score":{"n":25}}]}}]}`)
    if len(sl2) != 1 || !strings.contains(sl2[0], "50%概率") || !strings.contains(sl2[0], "分数+25") {
        fmt.println("SELFTEST FAIL: blueprint_summary chance", sl2)
        return false
    }
    fmt.println("summary: PASS")

    // --- T12: creative-description response parsing (创造台 ✨ LLM mode) ---
    {   // canned valid response → fields clamped + blueprint compiles
        cr, crok := creative_parse(`{"name":"火箭辣椒","hue":10,"shape":2,"rarity":2,"flavor":"先上天，再坠毁","blueprint":{"do":[{"speed":{"mult":0.5,"secs":4}},{"delay":{"secs":4}},{"growth":{"n":-2}},{"shake":{"s":0.6}},{"burst":{"n":3}}]}}`)
        if !crok || cr.name != "火箭辣椒" || cr.hue != 10 || cr.shape != 2 ||
           cr.rarity != 2 || cr.flavor != "先上天，再坠毁" || cr.blueprint == "" {
            fmt.println("SELFTEST FAIL: creative parse valid response", crok, cr.name)
            return false
        }
        cracts, craok := bp_compile(cr.blueprint)
        if !craok || len(cracts) != 4 || cracts[0].at != 0 || cracts[1].at != 4 {
            fmt.println("SELFTEST FAIL: creative blueprint schedule", len(cracts), craok)
            return false
        }
        bp_free_actions(&cracts)
        creative_free(&cr)
    }
    {   // out-of-range scalars clamp like clamp_recipe
        cr2, cr2ok := creative_parse(`{"name":"辣翅","hue":725,"shape":9,"rarity":7,"flavor":"","blueprint":{"do":[{"growth":{"n":1}}]}}`)
        if !cr2ok || cr2.hue != 5 || cr2.shape != 3 || cr2.rarity != 2 {
            fmt.println("SELFTEST FAIL: creative clamp", cr2)
            return false
        }
        creative_free(&cr2)
    }
    {   // ```json fences are tolerated
        cr3, cr3ok := creative_parse("```json\n{\"name\":\"蛋\",\"hue\":40,\"shape\":0,\"rarity\":1,\"flavor\":\"\",\"blueprint\":{\"do\":[{\"burst\":{\"n\":1}}]}}\n```")
        if !cr3ok || cr3.name != "蛋" || cr3.blueprint == "" {
            fmt.println("SELFTEST FAIL: creative fenced response")
            return false
        }
        creative_free(&cr3)
    }
    // blueprint with an unknown node → rejected
    if _, uok := creative_parse(`{"name":"x","hue":1,"shape":0,"rarity":0,"flavor":"","blueprint":{"do":[{"teleport":{}}]}}`); uok {
        fmt.println("SELFTEST FAIL: creative accepted unknown node")
        return false
    }
    // response missing blueprint → rejected
    if _, mok := creative_parse(`{"name":"x","hue":1,"shape":0,"rarity":0,"flavor":""}`); mok {
        fmt.println("SELFTEST FAIL: creative accepted missing blueprint")
        return false
    }
    fmt.println("creative parse: PASS")

    // restore the user's macros.json exactly as found
    if orig_macros_exists {
        _ = os.write_entire_file(MACROS_FILE, orig_macros)
        delete(orig_macros)
    } else {
        _ = os.remove(MACROS_FILE)
    }

    // --- T13: creator nickname persistence (creator.txt, snapshot-restored) ---
    if creator_byline != "" { delete(creator_byline); creator_byline = "" }
    save_creator("测试创作者")
    if creator_byline != "测试创作者" {
        fmt.println("SELFTEST FAIL: save_creator byline")
        return false
    }
    cdata, cerr := os.read_entire_file(CREATOR_FILE, context.temp_allocator)
    if cerr != nil || strings.trim_space(string(cdata)) != "测试创作者" {
        fmt.println("SELFTEST FAIL: creator.txt write")
        return false
    }
    delete(creator_byline)
    creator_byline = ""
    load_creator()
    if creator_byline != "测试创作者" {
        fmt.println("SELFTEST FAIL: creator.txt reload")
        return false
    }
    delete(creator_byline)
    creator_byline = ""
    // restore creator.txt exactly as found
    if orig_creator_exists {
        _ = os.write_entire_file(CREATOR_FILE, orig_creator)
        delete(orig_creator)
    } else {
        _ = os.remove(CREATOR_FILE)
    }
    fmt.println("creator: PASS")

    // ================= Phase 3: 作品库 (creations.json) =================
    // snapshot creations.json so the suite never clobbers a real user file
    orig_creations: []u8
    orig_creations_exists := false
    if d, err := os.read_entire_file(CREATIONS_FILE, context.allocator); err == nil {
        orig_creations = d
        orig_creations_exists = true
    }
    // clean slate for the library tests (the process exits after the suite, so
    // in-memory kinds/foods are not restored — the files always are)
    clear(&kinds)
    clear(&kind_by_name)
    clear(&foods)

    // --- T14: save → load roundtrip (one creation with blueprint + byline) ---
    creator_byline = strings.clone("测试创作者")
    free_edit_kind()
    edit_kind = FoodKind{
        name = strings.clone("测试白菜"), author = "自创", flavor = strings.clone("清甜爽口"),
        hue = 90, color = hsv_rgb(90, 0.72, 1.0), shape = .SPHERE, size = 0.3, spin = 2,
        rarity = 0, fx_speed = 1, fx_growth = 1, fx_score = 10, fx_bursts = 1,
    }
    edit_has_blueprint = false
    editor_save_kind()
    free_edit_kind()
    edit_kind = FoodKind{
        name = strings.clone("测试闪电莓"), author = "自创", flavor = "",
        hue = 280, color = hsv_rgb(280, 0.72, 1.0), shape = .GEM, size = 0.3, spin = 2,
        rarity = 2, fx_speed = 1, fx_growth = 1, fx_score = 10, fx_bursts = 2,
    }
    edit_blueprint = strings.clone(`{"do":[{"growth":{"n":2}},{"delay":{"secs":1}},{"score":{"n":20}}]}`)
    edit_has_blueprint = true
    editor_save_kind()
    free_edit_kind()
    delete(creator_byline)
    creator_byline = ""
    if creations_count() != 2 {
        fmt.println("SELFTEST FAIL: creations count after saves:", creations_count())
        return false
    }
    // wipe the in-memory registry, then reload purely from the file
    clear(&kinds)
    clear(&kind_by_name)
    clear(&foods)
    load_creations()
    idx_a, has_a := kind_by_name["测试白菜"]
    idx_b, has_b := kind_by_name["测试闪电莓"]
    if !has_a || !has_b || len(kinds) != 2 {
        fmt.println("SELFTEST FAIL: creations reload", len(kinds), has_a, has_b)
        return false
    }
    ka14, kb14 := kinds[idx_a], kinds[idx_b]
    if ka14.author != "自创" || kb14.author != "自创" ||
       ka14.byline != "测试创作者" || ka14.flavor != "清甜爽口" ||
       ka14.fx_score != 10 || ka14.hue != 90 {
        fmt.println("SELFTEST FAIL: creations roundtrip fields", ka14.author, ka14.byline)
        return false
    }
    if kb14.byline != "测试创作者" || kb14.blueprint == "" {
        fmt.println("SELFTEST FAIL: creations blueprint/byline lost:", kb14.byline)
        return false
    }
    acts14, ok14 := bp_compile(kb14.blueprint)
    if !ok14 || len(acts14) != 2 || acts14[0].at != 0 || acts14[1].at != 1 {
        fmt.println("SELFTEST FAIL: reloaded blueprint does not compile", ok14, len(acts14))
        return false
    }
    bp_free_actions(&acts14)
    fmt.println("creations roundtrip: PASS")

    // --- T15: 64-entry cap — a 65th save is refused (file keeps 64) ---
    for i in 0..<62 {
        nk := gen_kind(strings.clone(fmt.tprintf("占位%d", i)), 0)
        nk.author = "自创"
        append(&kinds, nk)
        kind_by_name[nk.name] = len(kinds) - 1
    }
    if creations_count() != CREATIONS_MAX {
        fmt.println("SELFTEST FAIL: expected 64 creations:", creations_count())
        return false
    }
    save_creations()
    if creations_file_count() != CREATIONS_MAX {
        fmt.println("SELFTEST FAIL: creations file should hold 64:", creations_file_count())
        return false
    }
    over := gen_kind(strings.clone("溢出"), 0)
    over.author = "自创"
    append(&kinds, over)
    kind_by_name[over.name] = len(kinds) - 1
    if creation_persist() {
        fmt.println("SELFTEST FAIL: 65th creation save was not refused")
        return false
    }
    if creations_file_count() != CREATIONS_MAX || creations_file_has("溢出") {
        fmt.println("SELFTEST FAIL: refused save still touched the file")
        return false
    }
    fmt.println("creations cap: PASS")

    // --- T16: quick-list order — newest first, retired skipped ---
    na := gen_kind(strings.clone("新甲"), 0)
    na.author = "自创"
    append(&kinds, na)
    kind_by_name[na.name] = len(kinds) - 1
    nb := gen_kind(strings.clone("新乙"), 0)
    nb.author = "自创"
    append(&kinds, nb)
    kind_by_name[nb.name] = len(kinds) - 1
    if creation_at(0) != kind_by_name["新乙"] || creation_at(1) != kind_by_name["新甲"] {
        fmt.println("SELFTEST FAIL: quick list order", creation_at(0), creation_at(1))
        return false
    }
    kinds[kind_by_name["新乙"]].retired = true
    if creation_at(0) != kind_by_name["新甲"] {
        fmt.println("SELFTEST FAIL: retired kind not skipped")
        return false
    }
    fmt.println("quick list: PASS")

    // --- T17: retire — removed from file & quick list, kinds[] untouched ---
    n0 := len(kinds)
    victim := kind_by_name["占位0"]
    cnt0 := creations_count()
    dex_retire_kind(victim)
    if len(kinds) != n0 || creations_count() != cnt0 - 1 {
        fmt.println("SELFTEST FAIL: retire moved kinds[] or miscounted", len(kinds), creations_count())
        return false
    }
    if !kinds[victim].retired {
        fmt.println("SELFTEST FAIL: retire flag not set")
        return false
    }
    for i in 0..<8 {
        if creation_at(i) == victim {
            fmt.println("SELFTEST FAIL: retired kind still in quick list")
            return false
        }
    }
    if creations_file_has("占位0") || creations_file_count() != CREATIONS_MAX {
        fmt.println("SELFTEST FAIL: retired kind still in file:", creations_file_count())
        return false
    }
    // X on a non-自创 row must be refused
    pk := gen_kind(strings.clone("预设替身"), 0)
    pk.author = "预设"
    append(&kinds, pk)
    kind_by_name[pk.name] = len(kinds) - 1
    dex_retire_kind(kind_by_name["预设替身"])
    if kinds[kind_by_name["预设替身"]].retired {
        fmt.println("SELFTEST FAIL: non-自创 kind was retired")
        return false
    }
    fmt.println("retire: PASS")

    // restore creations.json exactly as found
    if orig_creations_exists {
        _ = os.write_entire_file(CREATIONS_FILE, orig_creations)
        delete(orig_creations)
    } else {
        _ = os.remove(CREATIONS_FILE)
    }
    fmt.println("creations: ALL PASS")

    // ================= Phase 4: 拒食学习（净收益判定 + 免疫提示） =================

    // --- T18: net-value classification of classic fx (生长×2 + 分数/10 − 眩晕×1.5) ---
    {
        apple    := FoodKind{fx_growth = 1, fx_score = 10}       // 苹果
        chili    := FoodKind{fx_growth = 1, fx_score = 20}       // 辣椒
        popsicle := FoodKind{fx_growth = 1, fx_score = 15}       // 冰棍
        grenade  := FoodKind{fx_growth = -4}                     // 手榴弹
        poop     := FoodKind{fx_growth = -1, fx_score = -25}     // 便便
        shroom   := FoodKind{fx_score = 5, fx_confuse = 4}       // 毒蘑菇
        star     := FoodKind{fx_growth = 2, fx_score = 80}       // 星星
        // 用户的 "liulian"：大补但有副作用 —— 旧逻辑会因 confuse>0 判有害
        liulian  := FoodKind{fx_growth = 6, fx_score = 30, fx_confuse = 2,
                             fx_speed = 2.0, fx_speed_t = 2, fx_shake = 1.0, fx_bursts = 4}
        fmt.printf("net values: 苹果=%.1f 辣椒=%.1f 冰棍=%.1f 手榴弹=%.1f 便便=%.1f 毒蘑菇=%.1f 星星=%.1f liulian=%.1f\n",
            kind_net_value(apple), kind_net_value(chili), kind_net_value(popsicle),
            kind_net_value(grenade), kind_net_value(poop), kind_net_value(shroom),
            kind_net_value(star), kind_net_value(liulian))
        if kind_net_value(grenade) != -8 || kind_net_value(poop) != -4.5 ||
           kind_net_value(shroom) != -5.5 || kind_net_value(apple) != 3 ||
           kind_net_value(star) != 12 || kind_net_value(liulian) != 12 {
            fmt.println("SELFTEST FAIL: net-value weights")
            return false
        }
        if !kind_harmful(&grenade) || !kind_harmful(&poop) || !kind_harmful(&shroom) {
            fmt.println("SELFTEST FAIL: 手榴弹/便便/毒蘑菇 must stay harmful")
            return false
        }
        if kind_harmful(&apple) || kind_harmful(&star) || kind_harmful(&liulian) {
            fmt.println("SELFTEST FAIL: 苹果/星星/liulian must be safe")
            return false
        }
    }
    fmt.println("net classification: PASS")

    // --- T19: blueprint harm evaluation (compiled actions) + lazy cache ---
    {
        bad_bp := FoodKind{blueprint = `{"do":[{"growth":{"n":-3}}]}`}
        if !kind_harmful(&bad_bp) || bad_bp.harm_cache != 1 {
            fmt.println("SELFTEST FAIL: tail-blast blueprint must be harmful")
            return false
        }
        good_bp := FoodKind{blueprint = `{"do":[{"spawn_food":{"kind":"苹果","count":1}},{"score":{"n":10}}]}`}
        if kind_harmful(&good_bp) || good_bp.harm_cache != 2 {
            fmt.println("SELFTEST FAIL: egg+score blueprint must be safe")
            return false
        }
        // second calls must be cache hits (harm_cache != 0, no recompile, same verdict)
        if !kind_harmful(&bad_bp) || kind_harmful(&good_bp) {
            fmt.println("SELFTEST FAIL: cached harm verdicts changed")
            return false
        }
        // fx 与蓝图按同一权重相加：+2 (fx 生长) − 6 (蓝图炸尾) = −4 → 有害
        mixed := FoodKind{fx_growth = 1, blueprint = `{"do":[{"growth":{"n":-3}}]}`}
        if !kind_harmful(&mixed) {
            fmt.println("SELFTEST FAIL: fx+blueprint net values must add up")
            return false
        }
        // 编译失败 → 蓝图按中性处理，只看 fx
        broken := FoodKind{fx_growth = 1, fx_score = 10, blueprint = `{oops`}
        if kind_harmful(&broken) || broken.harm_cache != 2 {
            fmt.println("SELFTEST FAIL: invalid blueprint must be fx-only neutral")
            return false
        }
    }
    fmt.println("blueprint harm: PASS")

    // --- T20: immune-toast dedupe (每种食物每局只弹一次) ---
    game_mode = .FEEDING
    reset_game() // 清空 immune_toasted
    state = .PLAYING
    if !toast_immune_once("自测毒果") {
        fmt.println("SELFTEST FAIL: first immune toast suppressed")
        return false
    }
    if toast_immune_once("自测毒果") {
        fmt.println("SELFTEST FAIL: immune toast repeated for the same name")
        return false
    }
    {   // 同名两个食物同时开始腐烂 —— 仍然只弹一次
        hk := FoodKind{name = strings.clone("自测毒果2"), author = "本地",
                       hue = 280, color = hsv_rgb(280, 0.72, 1.0), shape = .CONE,
                       size = 0.3, spin = 2, fx_growth = -2, fx_bursts = 1}
        append(&kinds, hk)
        kind_by_name[hk.name] = len(kinds) - 1
        snake_memory["自测毒果2"] = 2
        clear(&foods)
        append(&foods, Food{kind = kind_by_name[hk.name], pos = IV3{9, 6, 6}})
        append(&foods, Food{kind = kind_by_name[hk.name], pos = IV3{3, 3, 3}})
        update_food_rot(0)
        both_rot := foods[0].rot == 10 && foods[1].rot == 10
        update_food_rot(0) // rot 已标记：f.rot==0 的守卫必须挡住重复提示
        if !both_rot || len(immune_toasted) != 2 || !strings.contains(toast, "自测毒果2") {
            fmt.println("SELFTEST FAIL: rot-marking toast dedupe", len(immune_toasted), toast)
            return false
        }
        if toast_immune_once("自测毒果2") {
            fmt.println("SELFTEST FAIL: toast repeated after rot marking")
            return false
        }
    }
    fmt.println("immune toast: PASS")

    // --- T21: liulian regression —— 大补但带眩晕的食物不再被拒食/免疫 ---
    {
        lk := FoodKind{name = strings.clone("榴莲回归"), author = "AI",
                       hue = 40, color = hsv_rgb(40, 0.72, 1.0), shape = .SPHERE,
                       size = 0.3, spin = 2, rarity = 1,
                       fx_speed = 2.0, fx_speed_t = 2, fx_growth = 6, fx_score = 30,
                       fx_shake = 1.0, fx_confuse = 2.0, fx_bursts = 4}
        append(&kinds, lk)
        lidx := len(kinds) - 1
        kind_by_name[lk.name] = lidx
        if kind_harmful(&kinds[lidx]) {
            fmt.println("SELFTEST FAIL: liulian classified harmful (the reported bug)")
            return false
        }
        reset_game()
        state = .PLAYING
        clear(&foods)
        append(&foods, Food{kind = lidx, pos = IV3{9, 6, 6}})
        select_target()
        if !ai_has_target || ai_target != (IV3{9, 6, 6}) {
            fmt.println("SELFTEST FAIL: liulian not targeted", ai_has_target, ai_target)
            return false
        }
        // 旧 bug 的触发条件：记忆满 2 次 —— 净收益为正的食物永远不学坏
        snake_memory["榴莲回归"] = 2
        select_target()
        if !ai_has_target || ai_target != (IV3{9, 6, 6}) || willing_food_count() != 1 {
            fmt.println("SELFTEST FAIL: liulian refused at memory 2 (old bug)")
            return false
        }
        _, _ = delete_key(&snake_memory, "榴莲回归")
    }
    fmt.println("liulian regression: PASS")

    fmt.println("harm learning: ALL PASS")

    // ================= Phase 5: 教练模式 + 演示模式 =================
    // snapshot tutorial.txt so the suite never clobbers a real user file
    orig_tut: []u8
    orig_tut_exists := false
    if d, err := os.read_entire_file(TUTORIAL_FILE, context.allocator); err == nil {
        orig_tut = d
        orig_tut_exists = true
    }
    _ = os.remove(TUTORIAL_FILE)

    // --- T22: tutorial machine — FEED chapter walks 1→8 by state flags ---
    game_mode = .FEEDING
    reset_game()
    state = .PLAYING
    if tutorial_seen() {
        fmt.println("SELFTEST FAIL: tutorial.txt present after remove")
        return false
    }
    tutorial_start(.FEED)
    if !tutorial_active || tutorial_step != 0 {
        fmt.println("SELFTEST FAIL: tutorial_start", tutorial_active, tutorial_step)
        return false
    }
    tutorial_step_logic(false, false) // info step needs a key — must not advance
    if tutorial_step != 0 {
        fmt.println("SELFTEST FAIL: info step advanced without a key")
        return false
    }
    tutorial_step_logic(true, false) // step 0 (info) → 1
    if tutorial_step != 1 || !tutorial_active {
        fmt.println("SELFTEST FAIL: step 0→1")
        return false
    }
    input_open = true // T pressed (same flag the game sets)
    tutorial_step_logic(false, false)
    if tutorial_step != 2 {
        fmt.println("SELFTEST FAIL: step 1→2 (input_open detector)")
        return false
    }
    input_open = false
    cast_word("教程试词") // word cast (watch cast_word_total)
    tutorial_step_logic(false, false)
    if tutorial_step != 3 {
        fmt.println("SELFTEST FAIL: step 2→3 (cast_word detector)")
        return false
    }
    cast_preset(0) // preset cast
    tutorial_step_logic(false, false)
    if tutorial_step != 4 {
        fmt.println("SELFTEST FAIL: step 3→4 (cast_preset detector)")
        return false
    }
    dex_open = true
    dex_enter_cast(0) // 图鉴 Enter cast
    tutorial_step_logic(false, false)
    if tutorial_step != 5 {
        fmt.println("SELFTEST FAIL: step 4→5 (dex cast detector)")
        return false
    }
    dex_open = false
    editor_open = true // E pressed
    tutorial_step_logic(false, false)
    if tutorial_step != 6 {
        fmt.println("SELFTEST FAIL: step 5→6 (editor detector)")
        return false
    }
    editor_open = false
    {   // 创造台保存：注册一个 自创 kind（creations_count 增加，不写文件）
        ck := gen_kind(strings.clone("教程测试果"), 0)
        ck.author = "自创"
        append(&kinds, ck)
        kind_by_name[ck.name] = len(kinds) - 1
    }
    tutorial_step_logic(false, false)
    if tutorial_step != 7 {
        fmt.println("SELFTEST FAIL: step 6→7 (creation-saved detector)")
        return false
    }
    tutorial_step_logic(true, false) // step 7 (info) → finish
    if tutorial_active || tutorial_step != 8 {
        fmt.println("SELFTEST FAIL: tutorial did not finish at step 8")
        return false
    }
    if !tutorial_seen() {
        fmt.println("SELFTEST FAIL: finishing did not write tutorial.txt")
        return false
    }
    // Esc path: skipping mid-chapter deactivates and writes the flag
    _ = os.remove(TUTORIAL_FILE)
    tutorial_start(.CLASSIC)
    tutorial_step_logic(false, true)
    if tutorial_active || !tutorial_seen() {
        fmt.println("SELFTEST FAIL: Esc skip did not deactivate+flag")
        return false
    }
    // CLASSIC chapter detectors: 4 distinct steer keys, V flip, B flip
    tutorial_start(.CLASSIC)
    tut_note_steer(1 << 0)
    tut_note_steer(1 << 1)
    tut_note_steer(1 << 2)
    tut_note_steer(1 << 0) // dup: still 3 distinct
    tutorial_step_logic(false, false)
    if tutorial_step != 0 {
        fmt.println("SELFTEST FAIL: steer detector fired at 3 distinct keys")
        return false
    }
    tut_note_steer(1 << 3) // 4 distinct
    tutorial_step_logic(false, false)
    if tutorial_step != 1 {
        fmt.println("SELFTEST FAIL: classic step 0→1 (steer detector)")
        return false
    }
    toggle_view() // V pressed
    tutorial_step_logic(false, false)
    if tutorial_step != 2 {
        fmt.println("SELFTEST FAIL: classic step 1→2 (view detector)")
        return false
    }
    autopilot_toggle_total += 1 // B pressed
    tutorial_step_logic(false, false)
    if tutorial_active {
        fmt.println("SELFTEST FAIL: classic chapter did not finish at step 3")
        return false
    }
    fmt.println("tutorial: PASS")

    // --- T23: attract playlist timeline + any-key exit + idle trigger ---
    pre_w := cast_word_total
    pre_p := preset_cast_total
    attract_begin()
    if !attract_active || state != .PLAYING {
        fmt.println("SELFTEST FAIL: attract_begin", attract_active, state)
        return false
    }
    attract_update(0.05) // first playlist cast fires immediately: preset 苹果
    if preset_cast_total != pre_p + 1 || cast_word_total != pre_w {
        fmt.println("SELFTEST FAIL: attract cast @0s", preset_cast_total - pre_p, cast_word_total - pre_w)
        return false
    }
    if attract_caption_index() != 0 {
        fmt.println("SELFTEST FAIL: caption @0s", attract_caption_index())
        return false
    }
    for _ in 0..<121 do attract_update(0.05) // ≈ 6.1 s → cast 火箭辣椒 (word)
    if cast_word_total != pre_w + 1 || preset_cast_total != pre_p + 1 {
        fmt.println("SELFTEST FAIL: attract cast @6s", cast_word_total - pre_w)
        return false
    }
    if attract_caption_index() != 1 {
        fmt.println("SELFTEST FAIL: caption @6s", attract_caption_index())
        return false
    }
    for _ in 0..<120 do attract_update(0.05) // ≈ 12.1 s → cast 星星 (preset)
    if preset_cast_total != pre_p + 2 || cast_word_total != pre_w + 1 {
        fmt.println("SELFTEST FAIL: attract cast @12s", preset_cast_total - pre_p)
        return false
    }
    if attract_caption_index() != 2 {
        fmt.println("SELFTEST FAIL: caption @12s", attract_caption_index())
        return false
    }
    attract_exit() // any-key exit: back to title, game reset, idle clock cleared
    if attract_active || state != .TITLE || title_idle_t != 0 {
        fmt.println("SELFTEST FAIL: attract_exit", attract_active, state, title_idle_t)
        return false
    }
    title_idle_t = 0
    if attract_idle_tick(0.1, true) || title_idle_t != 0 {
        fmt.println("SELFTEST FAIL: input did not reset the idle clock")
        return false
    }
    fired := -1
    for i in 1..=310 {
        if attract_idle_tick(0.1, false) { fired = i; break }
    }
    if fired < 299 || fired > 301 {
        fmt.println("SELFTEST FAIL: idle attract did not fire at ~30 s:", fired)
        return false
    }
    title_idle_t = 0
    fmt.println("attract: PASS")

    // ================= Phase 6: 战报图 (battle report) =================
    // --- T24: 段位 thresholds — classic by score, feeding by eaten ---
    {
        ok24 := true
        check24 :: proc(ok: ^bool, got: string, want: string) {
            if got != want {
                fmt.println("SELFTEST FAIL: rank mismatch, got", got, "want", want)
                ok^ = false
            }
        }
        t, _ := rank_classic(0);   check24(&ok24, t, "蛇界萌新")
        t, _  = rank_classic(49);  check24(&ok24, t, "蛇界萌新")
        t, _  = rank_classic(50);  check24(&ok24, t, "初出茅庐")
        t, _  = rank_classic(149); check24(&ok24, t, "初出茅庐")
        t, _  = rank_classic(150); check24(&ok24, t, "老练机长")
        t, _  = rank_classic(299); check24(&ok24, t, "老练机长")
        t, _  = rank_classic(300); check24(&ok24, t, "球形传说")
        t, _  = rank_classic(499); check24(&ok24, t, "球形传说")
        t, _  = rank_classic(500); check24(&ok24, t, "三维之神")
        t, _  = rank_feeding(0);   check24(&ok24, t, "新手饲养员")
        t, _  = rank_feeding(9);   check24(&ok24, t, "新手饲养员")
        t, _  = rank_feeding(10);  check24(&ok24, t, "资深饲养员")
        t, _  = rank_feeding(24);  check24(&ok24, t, "资深饲养员")
        t, _  = rank_feeding(25);  check24(&ok24, t, "黑暗料理大师")
        t, _  = rank_feeding(49);  check24(&ok24, t, "黑暗料理大师")
        t, _  = rank_feeding(50);  check24(&ok24, t, "食神下凡")
        if !ok24 do return false
        fmt.println("report ranks: PASS")
    }

    // --- T25: session_eaten accounting — two eats of one kind, reset clears ---
    {
        game_mode = .FEEDING
        reset_game()
        if len(session_eaten) != 0 {
            fmt.println("SELFTEST FAIL: session_eaten not empty after reset")
            return false
        }
        // benign kind: no tail-blast, no confusion — deterministic eat path
        tk := FoodKind{
            name = strings.clone("自测榴莲"), author = "AI",
            hue = 45, color = hsv_rgb(45, 0.72, 1.0), shape = .SPHERE,
            rarity = 1, fx_growth = 1, fx_score = 10, fx_bursts = 1,
        }
        append(&kinds, tk)
        kind_by_name[tk.name] = len(kinds) - 1
        clear(&foods)
        append(&foods, Food{kind = len(kinds) - 1, pos = {1, 2, 3}})
        eat_food(0)
        append(&foods, Food{kind = len(kinds) - 1, pos = {4, 5, 6}})
        eat_food(0)
        if session_eaten["自测榴莲"] != 2 || eaten != 2 {
            fmt.println("SELFTEST FAIL: session_eaten count:",
                session_eaten["自测榴莲"], "eaten:", eaten)
            return false
        }
        reset_game()
        if len(session_eaten) != 0 {
            fmt.println("SELFTEST FAIL: reset_game did not clear session_eaten")
            return false
        }
        fmt.println("report session accounting: PASS")
    }

    // --- T26: report_text — feeding content, classic no-menu, menu cap <=8 ---
    {
        ob := best
        game_mode = .FEEDING
        reset_game()
        score = 320
        best = 670
        eaten = 28
        play_clock = 754
        // 榴莲×3 必须排第一；再注册 11 种各 ×1，菜单行最多列 8 条
        duri := kind_index("榴莲")
        session_eaten[kinds[duri].name] = 3
        extras := [?]string{"彩虹糖", "虚空布丁", "闪电莓", "老干妈", "香菜",
            "螺蛳粉", "臭豆腐", "仰望星空", "鲱鱼罐头", "蓝纹奶酪", "豆汁儿"}
        for n in extras {
            idx := kind_index(n)
            session_eaten[kinds[idx].name] = 1
        }
        t := report_text()
        must := [?]string{"得分 320", "投喂 28 个", "榴莲×3", "奇葩菜单：",
            "段位：黑暗料理大师", "github.com/vajraimb/Shinake"}
        for m in must {
            if !strings.contains(t, m) {
                fmt.println("SELFTEST FAIL: feeding report_text missing:", m)
                return false
            }
        }
        // menu line caps at 8 entries even with 12 kinds eaten
        menu_start := strings.index(t, "奇葩菜单：")
        menu_rest := t[menu_start:]
        menu_end := strings.index(menu_rest, "\n")
        menu_line := menu_rest[:menu_end]
        if strings.count(menu_line, "×") != 8 {
            fmt.println("SELFTEST FAIL: menu line entries != 8:", menu_line)
            return false
        }
        if !strings.has_prefix(menu_line, "奇葩菜单：榴莲×3") {
            fmt.println("SELFTEST FAIL: menu not sorted by count desc:", menu_line)
            return false
        }
        // classic variant: no menu line, has rank + duration
        game_mode = .CLASSIC
        score = 40
        tc := report_text()
        if strings.contains(tc, "奇葩菜单") {
            fmt.println("SELFTEST FAIL: classic report_text has a menu line")
            return false
        }
        mustc := [?]string{"经典模式", "得分 40", "时长 12:34", "段位：蛇界萌新"}
        for m in mustc {
            if !strings.contains(tc, m) {
                fmt.println("SELFTEST FAIL: classic report_text missing:", m)
                return false
            }
        }
        reset_game()
        best = ob
        game_mode = .CLASSIC
        state = .TITLE
        fmt.println("report text: PASS")
    }

    // ================= Phase 7: 障碍地图 (obstacle maps, v3.0) =================
    // snapshot the map state so the suite leaves zero residue
    st_map   := current_map
    st_id    := map_id
    st_seed  := map_seed
    st_walls := map_has_walls

    // --- T26b: 球形场地 + 大圆迈步（贴球面绕行，不再沿轴直穿）---
    {
        sc := sphere_cell_count()
        if cell_in_world({0, 0, 0}) || cell_in_world({11, 11, 11}) ||
           !cell_in_world({6, 6, 6}) || !cell_in_world({6, 11, 6}) ||
           !cell_in_world({0, 6, 6}) || cell_in_world({0, 2, 6}) ||
           sc != 912 || sc >= CELLS {
            fmt.println("SELFTEST FAIL: spherical world", sc, CELLS)
            return false
        }
        map_clear()
        reset_game()
        state = .PLAYING
        autopilot = false
        start_dir := dir
        curved := false
        for _ in 0..<8 {
            step()
            if state != .PLAYING || !cell_in_world(snake[0]) {
                fmt.println("SELFTEST FAIL: great-circle step left the sphere", state, snake[0])
                return false
            }
            if dir != start_dir do curved = true
        }
        if !curved {
            fmt.println("SELFTEST FAIL: great-circle did not turn (still a straight axis)")
            return false
        }
        death_squawk = false
        reset_game()
        fmt.println("sphere world: PASS")
    }

    // --- T27: bitmask set/get/clear/count + bounds guards ---
    map_clear()
    if map_has_walls || map_solid_count() != 0 || map_free_cells() != sphere_cell_count() {
        fmt.println("SELFTEST FAIL: map_clear", map_has_walls, map_solid_count())
        return false
    }
    map_set({3, 4, 5}, true)
    map_set({0, 0, 0}, true)
    map_set({GRID_N - 1, GRID_N - 1, GRID_N - 1}, true)
    if !map_solid({3, 4, 5}) || !map_solid({0, 0, 0}) || !map_solid({11, 11, 11}) ||
       map_solid({3, 4, 6}) || map_solid_count() != 3 || !map_has_walls ||
       map_free_cells() != sphere_cell_count() - 1 { // 只有 {3,4,5} 在球内；两个角在球外不占用
        fmt.println("SELFTEST FAIL: map set/get", map_solid_count())
        return false
    }
    map_set({3, 4, 5}, false)
    if map_solid({3, 4, 5}) || map_solid_count() != 2 {
        fmt.println("SELFTEST FAIL: map unset", map_solid_count())
        return false
    }
    map_set({-1, 0, 0}, true)
    map_set({GRID_N, 0, 0}, true) // out of bounds: no-ops
    if map_solid_count() != 2 || map_solid({-1, 0, 0}) || map_solid({GRID_N, 0, 0}) {
        fmt.println("SELFTEST FAIL: map bounds guard", map_solid_count())
        return false
    }
    map_clear()
    if map_has_walls || map_solid_count() != 0 {
        fmt.println("SELFTEST FAIL: map_clear after edits")
        return false
    }
    fmt.println("map bitmask: PASS")

    // --- T28: a wall ahead kills like the boundary; 护盾 ghosts through ---
    game_mode = .CLASSIC
    map_clear()
    reset_game()
    wall28, _, ok28 := advance_on_sphere(snake[0], dir)
    if !ok28 {
        fmt.println("SELFTEST FAIL: map collision setup")
        return false
    }
    map_set(wall28, true) // 挡在大圆下一步上
    map_finalize()
    autopilot = false
    reset_game()
    state = .PLAYING
    step()
    if state != .GAME_OVER {
        fmt.println("SELFTEST FAIL: map wall did not kill", state, snake[0])
        return false
    }
    death_squawk = false
    reset_game()
    state = .PLAYING
    if !map_solid(wall28) {
        fmt.println("SELFTEST FAIL: reset_game cleared the map")
        return false
    }
    shield_timer = 5
    step() // 金身穿墙：头进入实心格，不死
    if state != .PLAYING || snake[0] != wall28 {
        fmt.println("SELFTEST FAIL: shield ghost through wall", state, snake[0])
        return false
    }
    shield_timer = 0
    death_squawk = false
    fmt.println("map collision: PASS")

    // --- T29: AI routes around walls; enclosed food falls back, no crash ---
    map_clear()
    reset_game()
    wall29, _, ok29 := advance_on_sphere(snake[0], dir)
    if !ok29 {
        fmt.println("SELFTEST FAIL: map AI setup")
        return false
    }
    map_set(wall29, true) // 挡在大圆下一步上
    map_finalize()
    state = .PLAYING
    food = IV3{GRID_N / 2, GRID_N / 2, GRID_N / 2}
    ai_target = food
    ai_has_target = true
    d_ai := ai_choose()
    n_ai, _, ok_ai := advance_on_sphere(snake[0], d_ai)
    if !ok_ai || map_solid(n_ai) {
        fmt.println("SELFTEST FAIL: AI picked a lethal cell", d_ai, n_ai)
        return false
    }
    // 把食物六面焊死：BFS 找不到路，必须安全退回追尾/保命
    for off in DIRS6 {
        c := IV3{food.x + off.x, food.y + off.y, food.z + off.z}
        if in_bounds(c) && !on_snake(c) do map_set(c, true)
    }
    map_finalize()
    d_ai2 := ai_choose()
    n_ai2, _, ok_ai2 := advance_on_sphere(snake[0], d_ai2)
    if !ok_ai2 || map_solid(n_ai2) {
        fmt.println("SELFTEST FAIL: enclosed-food fallback is lethal", d_ai2, n_ai2)
        return false
    }
    fmt.println("map AI: PASS")

    // --- T30: spawn_kind / spawn_food never pick solid cells ---
    map_clear()
    for z in 0..<GRID_N do for y in 0..<GRID_N do map_set({0, i32(y), i32(z)}, true)
    map_finalize()
    game_mode = .FEEDING
    reset_game()
    clear(&foods)
    for _ in 0..<200 do spawn_kind(0)
    if len(foods) != 200 {
        fmt.println("SELFTEST FAIL: spawn_kind starved with walls", len(foods))
        return false
    }
    for f in foods {
        if !cell_in_world(f.pos) || map_solid(f.pos) || on_snake(f.pos) {
            fmt.println("SELFTEST FAIL: spawn_kind picked a blocked cell", f.pos)
            return false
        }
    }
    game_mode = .CLASSIC
    reset_game()
    for _ in 0..<50 {
        spawn_food()
        if state != .PLAYING || !cell_in_world(food) || map_solid(food) || on_snake(food) {
            fmt.println("SELFTEST FAIL: classic spawn picked a blocked cell", food)
            return false
        }
    }
    fmt.println("map spawn: PASS")

    // --- T31: preset geometry, counts, determinism, connectivity ---
    map_apply(.VOID)
    if map_solid_count() != 0 || map_has_walls || current_map.name != "虚空" {
        fmt.println("SELFTEST FAIL: 虚空", map_solid_count(), current_map.name)
        return false
    }
    map_apply(.PILLARS)
    if map_solid_count() != 32 || current_map.name != "石柱林" ||
       !map_solid({3, 2, 3}) || !map_solid({3, 9, 3}) || !map_solid({8, 5, 8}) ||
       map_solid({3, 1, 3}) || map_solid({3, 10, 3}) {
        fmt.println("SELFTEST FAIL: 石柱林", map_solid_count())
        return false
    }
    map_apply(.CROSS)
    if map_solid_count() != 272 || current_map.name != "十字回廊" ||
       !map_solid({6, 0, 0}) || !map_solid({0, 0, 6}) || !map_solid({6, 6, 6}) ||
       map_solid({6, 4, 3}) || map_solid({6, 5, 3}) || // x 墙的低门
       map_solid({3, 7, 6}) || map_solid({3, 8, 6}) {  // z 墙的高门
        fmt.println("SELFTEST FAIL: 十字回廊", map_solid_count())
        return false
    }
    map_apply(.HIVE)
    hive_center_ok := true
    for z in 0..<GRID_N do for y in 0..<GRID_N do for x in 0..<GRID_N {
        if abs(x - 6) + abs(y - 6) + abs(z - 6) <= 3 &&
           map_solid({i32(x), i32(y), i32(z)}) {
            hive_center_ok = false
        }
    }
    if map_solid_count() != 184 || current_map.name != "蜂巢" || !hive_center_ok ||
       !map_solid({2, 2, 2}) || !map_solid({10, 10, 10}) || map_solid({6, 6, 6}) {
        fmt.println("SELFTEST FAIL: 蜂巢", map_solid_count(), hive_center_ok)
        return false
    }
    map_seed = 42
    map_apply(.CAVE)
    cave_bits := current_map.bits
    cave_count := map_solid_count()
    cave_name := strings.clone(current_map.name, context.temp_allocator)
    map_apply(.CAVE) // 同种子 → 完全相同的比特
    if current_map.bits != cave_bits || current_map.name != cave_name {
        fmt.println("SELFTEST FAIL: 随机洞穴 #42 not deterministic")
        return false
    }
    if cave_count < 20 || cave_count > 300 {
        fmt.println("SELFTEST FAIL: 随机洞穴 density out of range", cave_count)
        return false
    }
    if map_free_reach_ratio() < 0.85 {
        fmt.println("SELFTEST FAIL: 随机洞穴 connectivity", map_free_reach_ratio())
        return false
    }
    cave_center_ok := true
    for z in 0..<GRID_N do for y in 0..<GRID_N do for x in 0..<GRID_N {
        if abs(x - 6) + abs(y - 6) + abs(z - 6) <= 3 &&
           map_solid({i32(x), i32(y), i32(z)}) {
            cave_center_ok = false
        }
    }
    if !cave_center_ok {
        fmt.println("SELFTEST FAIL: 随机洞穴 center not 3-clear")
        return false
    }
    map_seed = 43
    map_apply(.CAVE)
    if current_map.bits == cave_bits {
        fmt.println("SELFTEST FAIL: 随机洞穴 seed made no difference")
        return false
    }
    fmt.println("map presets: PASS")

    // --- T32: reset_game keeps the selected map (R 重开不换图) ---
    map_apply(.HIVE)
    keep_bits := current_map.bits
    game_mode = .CLASSIC
    reset_game()
    if map_id != .HIVE || current_map.bits != keep_bits || map_solid_count() != 184 {
        fmt.println("SELFTEST FAIL: reset_game dropped the map (classic)")
        return false
    }
    game_mode = .FEEDING
    reset_game()
    if map_id != .HIVE || current_map.bits != keep_bits {
        fmt.println("SELFTEST FAIL: reset_game dropped the map (feeding)")
        return false
    }
    fmt.println("map persistence: PASS")

    // --- T33: gameover_auto_restart / gameover_wants_report 判定矩阵 ---
    {
        // 投喂（非演示）：停屏 + 出战报
        attract_active = false
        game_mode = .FEEDING
        autopilot = true
        m33 := !gameover_auto_restart() && gameover_wants_report()
        // 经典手动：停屏 + 出战报
        game_mode = .CLASSIC
        autopilot = false
        m33 = m33 && !gameover_auto_restart() && gameover_wants_report()
        // 经典自动驾驶（观赏）：自动重开 + 不出战报
        game_mode = .CLASSIC
        autopilot = true
        m33 = m33 && gameover_auto_restart() && !gameover_wants_report()
        if !m33 {
            fmt.println("SELFTEST FAIL: gameover decision matrix (non-attract)")
            return false
        }
        // attract 演示（投喂 + autopilot）：自动重开 + 不出战报
        attract_begin()
        m33 = attract_active && gameover_auto_restart() && !gameover_wants_report()
        attract_exit() // 还原 attract_active / 地图 / state，不污染后续测试
        if !m33 || attract_active {
            fmt.println("SELFTEST FAIL: gameover decision matrix (attract)")
            return false
        }
        fmt.println("gameover decision matrix: PASS")
    }

    // --- T34: back_to_title — 停到标题、地图不换、战局清零 ---
    {
        map_apply(.PILLARS)
        game_mode = .CLASSIC
        autopilot = false
        reset_game()
        score = 42
        title_idle_t = 12.3
        state = .GAME_OVER
        back_to_title()
        if state != .TITLE || map_id != .PILLARS || score != 0 ||
           len(snake) != 3 || title_idle_t != 0 {
            fmt.println("SELFTEST FAIL: back_to_title", state, map_id, score,
                len(snake), title_idle_t)
            return false
        }
        fmt.println("back_to_title: PASS")
    }

    // --- T35: switch_to_feeding — 战局保留，AI 接管立即起跑，空场补食 ---
    {
        map_apply(.VOID)
        game_mode = .CLASSIC
        autopilot = false
        reset_game()
        state = .PLAYING
        started = true
        // 吃一颗豆豆再跑两拍，制造一局"进行中"的经典战局
        food, _, _ = advance_on_sphere(snake[0], dir)
        step() // +10 分
        food = IV3{0, 0, 0} // 钉死豆豆，后两拍 deterministic
        for _ in 0..<2 do step()
        snap_score, snap_eaten, snap_len := score, eaten, len(snake)
        snap_head := snake[0]
        switch_to_feeding()
        ok35 := game_mode == .FEEDING && autopilot && started &&
            score == snap_score && eaten == snap_eaten && len(snake) == snap_len &&
            snake[0] == snap_head && len(dir_queue) == 0 &&
            !dex_open && !input_open && !report_open
        // 经典局 foods 为空 → 切入时补一个 kinds[0] 开场
        ok35 = ok35 && len(foods) == 1 && foods[0].kind == 0
        // 清空 foods 后再切入（经典兜一圈回来）同样要补
        clear(&foods)
        switch_to_classic()
        switch_to_feeding()
        ok35 = ok35 && len(foods) == 1 && foods[0].kind == 0 &&
            score == snap_score && len(snake) == snap_len
        if !ok35 || snap_score == 0 {
            fmt.println("SELFTEST FAIL: switch_to_feeding",
                game_mode, autopilot, score, len(snake), len(foods))
            return false
        }
        fmt.println("switch to feeding: PASS")
    }

    // --- T36: switch_to_classic — 交还方向盘，豆豆避蛇避墙避 foods 阵列 ---
    {
        map_apply(.VOID)
        game_mode = .FEEDING
        reset_game()
        state = .PLAYING
        // 故意铺几个 foods，豆豆不得与它们叠格
        append(&foods, Food{kind = 0, pos = {0, 0, 0}})
        append(&foods, Food{kind = 0, pos = {GRID_N - 1, GRID_N - 1, GRID_N - 1}})
        append(&foods, Food{kind = 0, pos = {0, GRID_N - 1, 0}})
        n_foods := len(foods)
        snap_score, snap_len := score, len(snake)
        switch_to_classic()
        ok36 := game_mode == .CLASSIC && !autopilot && len(dir_queue) == 0 &&
            score == snap_score && len(snake) == snap_len && len(foods) == n_foods &&
            !on_snake(food) && !map_solid(food)
        for f in foods do if f.pos == food { ok36 = false; break }
        if !ok36 {
            fmt.println("SELFTEST FAIL: switch_to_classic", food, autopilot, len(foods))
            return false
        }
        fmt.println("switch to classic: PASS")
    }

    // --- T37: 双系统同场 — 经典模式先吃效果食物，下一拍再吃豆豆 ---
    {
        map_apply(.VOID)
        game_mode = .CLASSIC
        autopilot = false
        reset_game()
        state = .PLAYING
        started = true
        // 辣椒式暴走食物（自测环境不注册预设，内联一个同款）
        ck := FoodKind{
            name = strings.clone("自测辣椒"), author = "本地",
            hue = 14, color = hsv_rgb(14, 0.72, 1.0), shape = .CONE,
            rarity = 1, fx_speed = 0.5, fx_speed_t = 5, fx_score = 20, fx_bursts = 1,
        }
        append(&kinds, ck)
        kind_by_name[ck.name] = len(kinds) - 1
        h := snake[0]
        step1, d1, _ := advance_on_sphere(h, dir)
        step2, _, _ := advance_on_sphere(step1, d1)
        append(&foods, Food{kind = len(kinds) - 1, pos = step1})
        food = step2 // 豆豆在再前一格（沿大圆）
        sc0 := score
        step() // 踩到效果食物：暴走生效，模式无关；豆豆留到下拍
        ok37 := state == .PLAYING && fx_speed_timer > 0 && fx_speed_mult == 0.5 &&
            score == sc0 + 20 && len(foods) == 0
        step() // 吃到豆豆 +10
        ok37 = ok37 && state == .PLAYING && score == sc0 + 30
        if !ok37 {
            fmt.println("SELFTEST FAIL: dual food systems", score, sc0, fx_speed_timer, len(foods))
            return false
        }
        fmt.println("dual food systems: PASS")
    }

    // --- T38: 往返切换 — 经典→投喂→经典，蛇长 / 分数 / eaten 全程不变 ---
    {
        map_apply(.VOID)
        game_mode = .CLASSIC
        autopilot = false
        reset_game()
        state = .PLAYING
        started = true
        food, _, _ = advance_on_sphere(snake[0], dir)
        step() // 吃一颗豆
        snap_score, snap_eaten, snap_len := score, eaten, len(snake)
        switch_to_feeding()
        step() // 投喂 AI 飞一拍（新补的食物 ≥4 格远，当拍吃不到）
        switch_to_classic()
        if game_mode != .CLASSIC || autopilot || state != .PLAYING ||
           score != snap_score || eaten != snap_eaten || len(snake) != snap_len {
            fmt.println("SELFTEST FAIL: mode round trip",
                game_mode, autopilot, score, eaten, len(snake))
            return false
        }
        fmt.println("mode round trip: PASS")
    }

    // restore the map state + game shell exactly as found
    current_map = st_map
    map_id = st_id
    map_seed = st_seed
    map_has_walls = st_walls
    game_mode = .CLASSIC
    autopilot = false
    shield_timer = 0
    death_squawk = false
    state = .TITLE

    // restore tutorial.txt exactly as found
    if orig_tut_exists {
        _ = os.write_entire_file(TUTORIAL_FILE, orig_tut)
        delete(orig_tut)
    } else {
        _ = os.remove(TUTORIAL_FILE)
    }

    fmt.println("blueprint engine: ALL PASS")
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
    if !ok do return false

    // 创造台 ✨ 描述创意: the mock answers the creative prompt with a blueprint
    if !llm_start_creative("我想要一个会下蛋的食物") {
        fmt.println("LLMTEST FAIL: creative job did not start")
        return false
    }
    for i := 0; i < 600 && llm_state == .COOKING; i += 1 {
        time.sleep(50 * time.Millisecond)
    }
    if llm_state == .COOKING {
        fmt.println("LLMTEST FAIL: creative worker timed out")
        return false
    }
    // peek at the raw handoff before llm_poll consumes it (editor is closed
    // here, so poll parses + discards — exactly the production fallback)
    sync.mutex_lock(&llm_mutex)
    craw := strings.clone(llm_creative_raw)
    sync.mutex_unlock(&llm_mutex)
    llm_poll()
    cr, cok := creative_parse(craw)
    delete(craw)
    cpass := cok && cr.name != "" && cr.blueprint != ""
    if cpass {
        sacts, sok := bp_compile(cr.blueprint)
        cpass = sok && len(sacts) == 2
        if sok do bp_free_actions(&sacts)
    }
    fmt.println("creative desc: 我想要一个会下蛋的食物")
    fmt.printf("creative: name=%s hue=%d shape=%d rarity=%d flavor=%s\n",
        cr.name, cr.hue, cr.shape, cr.rarity, cr.flavor)
    fmt.println("creative roundtrip:", cpass ? "PASS" : "FAIL")
    creative_free(&cr)
    return cpass
}

// nearest food the snake is willing to eat (not rotting, not immune-refused)
select_target :: proc() {
    ai_has_target = false
    best_d := i32(1 << 30)
    for f in foods {
        k := &kinds[f.kind]
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

// 场上蛇还愿意吃的食物数量（未腐烂 + 未免疫）—— 用于"没东西吃"提示
willing_food_count :: proc() -> int {
    n := 0
    for f in foods {
        if f.rot > 0 do continue
        k := &kinds[f.kind]
        if kind_harmful(k) && snake_memory[k.name] >= 2 do continue
        n += 1
    }
    return n
}

// 免疫提示去重：每种食物每局只在蛇开始拒食的那一刻弹一次。
// 返回 true 表示这次真的弹了（供自测断言）。
toast_immune_once :: proc(name: string) -> bool {
    if immune_toasted[name] do return false
    immune_toasted[name] = true
    set_toast(fmt.tprintf("蛇吃够了 %s 的亏，免疫了！", name))
    return true
}

// mark foods the snake now refuses as rotting; remove fully rotten ones
update_food_rot :: proc(dt: f32) {
    for i := len(foods) - 1; i >= 0; i -= 1 {
        f := &foods[i]
        k := &kinds[f.kind]
        if f.rot == 0 && kind_harmful(k) && snake_memory[k.name] >= 2 {
            f.rot = 10 // 蛇不肯吃，开始腐烂
            toast_immune_once(k.name) // 每种食物每局只解释一次
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

// classic fx fields applied directly — also the fallback for invalid blueprints.
// returns true when the fx killed the snake (tail-blast on a too-short snake)
apply_classic_fx :: proc(k: FoodKind, pos: IV3) -> bool {
    add_score(k.fx_score)
    if apply_growth_fx(k.fx_growth) do return true
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
    for _ in 0..<max(k.fx_bursts, 1) do burst_col(cell_to_world(pos), k.color, 24)
    return false
}

eat_food :: proc(i: int) {
    f := foods[i]
    k := &kinds[f.kind]
    eaten += 1
    session_eaten[k.name] += 1 // 战报奇葩菜单用（kinds[].name 常驻，引用安全）
    blueprint_ok := false
    if k.blueprint != "" {
        actions, ok := bp_compile(k.blueprint)
        if ok {
            enqueue_actions(actions[:]) // blueprint supersedes the classic fx fields
            delete(actions)
            blueprint_ok = true
        }
    }
    if blueprint_ok {
        if k.flavor != "" {
            set_toast(fmt.tprintf("AI 点评: %s", k.flavor))
        }
    } else {
        if apply_classic_fx(k^, f.pos) {
            ordered_remove(&foods, i)
            return
        }
        if k.blueprint != "" {
            if k.flavor != "" {
                set_toast(fmt.tprintf("蓝图无效，使用基础效果 · AI 点评: %s", k.flavor))
            } else {
                set_toast("蓝图无效，使用基础效果")
            }
        } else if k.flavor != "" {
            set_toast(fmt.tprintf("AI 点评: %s", k.flavor))
        }
    }
    if kind_harmful(k) {
        snake_memory[k.name] += 1 // 蛇会记住这次伤害
    }
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
        n, _, ok := advance_on_sphere(head, off)
        if !ok || !in_bounds(n) do continue
        if map_solid(n) do continue
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
    R := WORLD_RADIUS - 0.05
    for i := len(particles) - 1; i >= 0; i -= 1 {
        p := &particles[i]
        p.life -= dt
        if p.life <= 0 {
            unordered_remove(&particles, i)
            continue
        }
        p.vel.y -= 14 * dt
        p.pos += p.vel * dt
        r2 := p.pos.x*p.pos.x + p.pos.y*p.pos.y + p.pos.z*p.pos.z
        if r2 > R * R {
            n := norm_v3(p.pos)
            p.pos = n * R
            vn := p.vel.x*n.x + p.vel.y*n.y + p.vel.z*n.z
            if vn > 0 do p.vel -= n * vn * 1.4
        }
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
    if rl.IsKeyPressed(.V) && !input_open do toggle_view()
    // M: modern / classic snake skin
    if rl.IsKeyPressed(.M) do modern_skin = !modern_skin

    // F: 游戏中即时切换 经典 ↔ 投喂（战局保留；投喂框打字 / 演示 / 教程中不响应）
    if rl.IsKeyPressed(.F) && !input_open && !attract_active {
        if tutorial_active {
            set_toast("教程进行中——完成或 Esc 跳过后再切换")
        } else if game_mode == .FEEDING {
            switch_to_classic()
            set_toast("已切换经典模式 · 方向盘交还你")
        } else {
            switch_to_feeding()
            set_toast("已切换投喂模式 · AI 接管")
        }
    }

    if game_mode == .FEEDING {
        // 投喂模式：默认 AI 开蛇、玩家只管投喂；B 可收回方向盘手动驾驶（hardcore 彩蛋）
        if rl.IsKeyPressed(.TAB) {
            dex_open = !dex_open
            dex_sel = 0
        }
        if rl.IsKeyPressed(.T) {
            input_open = true
            input_len = 0
        }
        if !input_open {
            if rl.IsKeyPressed(.E) {
                // 创造台：图鉴打开时克隆选中行（以此为基础改造），否则空白模板
                rows := dex_visible_rows()
                if dex_open && rows > 0 {
                    editor_open_from(dex_kind_at(min(dex_sel, rows - 1)))
                } else {
                    editor_open_blank()
                }
            }
            // G: 战报图 — 生成战绩卡 PNG + 复制文字版 + 浮层展示至任意键
            if rl.IsKeyPressed(.G) {
                name := report_generate()
                report_copy_text(false) // toast 统一在下面发
                report_open = report_tex.id != 0
                set_toast(name != "" ? fmt.tprintf("战报已保存并复制: %s", name) : "战报生成失败")
            }
            // 1-8 预设；⇧1-8 作品库快捷投放（新的在前；图鉴打开时 ⇧ 无效）
            shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
            if rl.IsKeyPressed(.ONE)   do feed_digit(0, shift)
            if rl.IsKeyPressed(.TWO)   do feed_digit(1, shift)
            if rl.IsKeyPressed(.THREE) do feed_digit(2, shift)
            if rl.IsKeyPressed(.FOUR)  do feed_digit(3, shift)
            if rl.IsKeyPressed(.FIVE)  do feed_digit(4, shift)
            if rl.IsKeyPressed(.SIX)   do feed_digit(5, shift)
            if rl.IsKeyPressed(.SEVEN) do feed_digit(6, shift)
            if rl.IsKeyPressed(.EIGHT) do feed_digit(7, shift)
            if dex_open {
                rows := dex_visible_rows()
                if rl.IsKeyPressed(.UP)   do dex_sel = max(0, dex_sel - 1)
                if rl.IsKeyPressed(.DOWN) && rows > 0 do dex_sel = min(rows - 1, dex_sel + 1)
                if rl.IsKeyPressed(.C) && rows > 0 {
                    copy_share_code(dex_kind_at(min(dex_sel, rows - 1)))
                }
                if (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) && rows > 0 {
                    // Enter: 立即投喂选中的食物（图鉴保持打开）
                    idx := dex_kind_at(min(dex_sel, rows - 1))
                    if idx >= 0 do dex_enter_cast(idx)
                }
                if rl.IsKeyPressed(.X) && rows > 0 {
                    // X: 从作品库删除选中的自创作品
                    dex_retire_kind(dex_kind_at(min(dex_sel, rows - 1)))
                }
            } else if rl.IsKeyPressed(.C) && last_cast_kind >= 0 && last_cast_kind < len(kinds) {
                copy_share_code(last_cast_kind)
            }
        }
    }

    // B: toggle AI autopilot（经典 + 投喂通用；投喂框打字时 B 是字母）
    if rl.IsKeyPressed(.B) && !input_open {
        autopilot = !autopilot
        autopilot_toggle_total += 1
        if autopilot do clear(&dir_queue) // AI 接管前清空玩家排队的方向
    }
    // AI 操控时忽略方向键；投喂框输入时 WASD 是打字
    if autopilot || input_open do return

    // 投喂图鉴打开时方向键归图鉴翻页（WASD 仍可转向）
    arrows_to_dex := game_mode == .FEEDING && dex_open
    go_left  := rl.IsKeyPressed(.A) || (rl.IsKeyPressed(.LEFT)  && !arrows_to_dex)
    go_right := rl.IsKeyPressed(.D) || (rl.IsKeyPressed(.RIGHT) && !arrows_to_dex)
    go_up    := rl.IsKeyPressed(.W) || (rl.IsKeyPressed(.UP)    && !arrows_to_dex)
    go_down  := rl.IsKeyPressed(.S) || (rl.IsKeyPressed(.DOWN)  && !arrows_to_dex)

    // 教练模式（经典章第 1 步）统计按过的方向键种类——只观察，不拦截
    if rl.IsKeyPressed(.A)     do tut_note_steer(1 << 0)
    if rl.IsKeyPressed(.LEFT)  do tut_note_steer(1 << 1)
    if rl.IsKeyPressed(.D)     do tut_note_steer(1 << 2)
    if rl.IsKeyPressed(.RIGHT) do tut_note_steer(1 << 3)
    if rl.IsKeyPressed(.W)     do tut_note_steer(1 << 4)
    if rl.IsKeyPressed(.UP)    do tut_note_steer(1 << 5)
    if rl.IsKeyPressed(.S)     do tut_note_steer(1 << 6)
    if rl.IsKeyPressed(.DOWN)  do tut_note_steer(1 << 7)

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
// 教练模式 (Coach): a learn-by-doing tutorial that runs INSIDE the real game.
// The overlay teaches one key at a time; the taught keys keep working
// normally — steps complete by observing state changes (pure detectors),
// never by intercepting input. Steps are plain data: add a line to the
// chapter's step array (+ a small detector proc) to extend the tutorial.
// ---------------------------------------------------------------------------

TutorialChapter :: enum { FEED, CLASSIC }

// screen region left bright while the rest of the screen dims (~55%)
TutRegion :: enum { NONE, BOTTOM_BAR, FEED_BOX, DEX_PANEL, EDITOR_PANEL }

TutStep :: struct {
    text:     string,
    region:   TutRegion,
    baseline: proc() -> int,   // counter snapshot taken on step entry (nil = flag/info step)
    detector: proc() -> bool,  // nil = info step (any key advances)
}

TUTORIAL_FILE :: "tutorial.txt" // written on finish OR skip → never auto-starts again

tutorial_seen :: proc() -> bool {
    _, err := os.read_entire_file(TUTORIAL_FILE, context.temp_allocator)
    return err == nil
}

tutorial_write_flag :: proc() {
    _ = os.write_entire_file(TUTORIAL_FILE, string(TUTORIAL_NOTE))
}
TUTORIAL_NOTE :: "done\n"

// --- detector support: tiny pure procs reading game state ---

tut_note_steer :: proc(bit: u32) {
    if tutorial_steer_mask & bit == 0 {
        tutorial_steer_mask |= bit
        tutorial_steer_count += 1
    }
}

// 图鉴 Enter 投喂（唯一会推进 dex_cast_total 的路径）
dex_enter_cast :: proc(idx: int) {
    spawn_kind(idx)
    last_cast_kind = idx
    dex_cast_total += 1
    set_toast(fmt.tprintf("已投喂: %s", kinds[idx].name))
}

// V: single flip point so the tutorial can count view changes
toggle_view :: proc() {
    view_mode = view_mode == .FIRST ? .ORBIT : .FIRST
    view_toggle_total += 1
}

tut_bl_cast_word  :: proc() -> int { return cast_word_total }
tut_bl_preset     :: proc() -> int { return preset_cast_total }
tut_bl_dex        :: proc() -> int { return dex_cast_total }
tut_bl_creations  :: proc() -> int { return creations_count() }
tut_bl_view       :: proc() -> int { return view_toggle_total }
tut_bl_autopilot  :: proc() -> int { return autopilot_toggle_total }

tut_det_input_open :: proc() -> bool { return input_open }
tut_det_cast_word  :: proc() -> bool { return cast_word_total > tutorial_mark }
tut_det_preset     :: proc() -> bool { return preset_cast_total > tutorial_mark }
tut_det_dex        :: proc() -> bool { return dex_cast_total > tutorial_mark }
tut_det_editor     :: proc() -> bool { return editor_open }
tut_det_creations  :: proc() -> bool { return creations_count() > tutorial_mark }
tut_det_steer      :: proc() -> bool { return tutorial_steer_count >= 4 }
tut_det_view       :: proc() -> bool { return view_toggle_total > tutorial_mark }
tut_det_autopilot  :: proc() -> bool { return autopilot_toggle_total > tutorial_mark }

// --- the step lists (data!) ---

TUTORIAL_FEED_STEPS := [?]TutStep{
    {text = "这条蛇是 AI 开的——你的工作是喂它！", region = .NONE},
    {text = "按 T 打开投喂框", region = .BOTTOM_BAR,
     detector = tut_det_input_open},
    {text = "输入任意词，回车投放", region = .FEED_BOX,
     baseline = tut_bl_cast_word, detector = tut_det_cast_word},
    {text = "按 1-8 试试预设食物", region = .BOTTOM_BAR,
     baseline = tut_bl_preset, detector = tut_det_preset},
    {text = "按 Tab 打开图鉴，↑↓ 翻页，Enter 再投一个", region = .DEX_PANEL,
     baseline = tut_bl_dex, detector = tut_det_dex},
    {text = "按 E 打开创造台", region = .BOTTOM_BAR,
     detector = tut_det_editor},
    {text = "←→ 调整任意数值，然后「保存并投放」", region = .EDITOR_PANEL,
     baseline = tut_bl_creations, detector = tut_det_creations},
    {text = "毕业！按 C 复制分享码发给朋友。蛇归你了！", region = .NONE},
}

TUTORIAL_CLASSIC_STEPS := [?]TutStep{
    {text = "A/D/W/S 转向（屏幕方向）", region = .NONE,
     detector = tut_det_steer},
    {text = "按 V 切换第一人称/环绕视角", region = .BOTTOM_BAR,
     baseline = tut_bl_view, detector = tut_det_view},
    {text = "按 B 可以随时让 AI 救场", region = .BOTTOM_BAR,
     baseline = tut_bl_autopilot, detector = tut_det_autopilot},
}

tutorial_steps :: proc() -> []TutStep {
    if tutorial_chapter == .FEED do return TUTORIAL_FEED_STEPS[:]
    return TUTORIAL_CLASSIC_STEPS[:]
}

tutorial_start :: proc(chapter: TutorialChapter) {
    tutorial_active = true
    tutorial_chapter = chapter
    tutorial_step = 0
    tutorial_mark = 0
    tutorial_steer_mask = 0
    tutorial_steer_count = 0
    steps := tutorial_steps()
    if steps[0].baseline != nil do tutorial_mark = steps[0].baseline()
}

tutorial_advance :: proc() {
    tutorial_step += 1
    steps := tutorial_steps()
    if tutorial_step >= len(steps) {
        tutorial_active = false
        tutorial_write_flag() // 毕业：不再自动开课
        return
    }
    if steps[tutorial_step].baseline != nil {
        tutorial_mark = steps[tutorial_step].baseline()
    }
}

tutorial_skip :: proc() {
    tutorial_active = false
    tutorial_write_flag() // 跳过同样不再自动开课
}

// one frame of the tutorial state machine — pure (no raylib), so the
// self-test can drive it: any_key/esc are sampled by the caller.
tutorial_step_logic :: proc(any_key, esc: bool) {
    if !tutorial_active do return
    if esc { // Esc 随时优雅退出，游戏原样继续
        tutorial_skip()
        return
    }
    steps := tutorial_steps()
    if tutorial_step >= len(steps) {
        tutorial_active = false
        return
    }
    s := steps[tutorial_step]
    if s.detector == nil {
        if any_key do tutorial_advance()
    } else if s.detector() {
        tutorial_advance()
    }
}

tutorial_region_rect :: proc(r: TutRegion) -> rl.Rectangle {
    switch r {
    case .BOTTOM_BAR:   return {0, SCREEN_H - 74, SCREEN_W, 74}
    case .FEED_BOX:     return {510, 736, 580, 98}
    case .DEX_PANEL:    return {SCREEN_W - 392, 160, 384, 344}
    case .EDITOR_PANEL: return {SCREEN_W - 594, 6, 588, SCREEN_H - 12}
    case .NONE:         return {}
    }
    return {}
}

// dim everything (~55%) except the step's highlight rect + a speech bubble
draw_tutorial :: proc() {
    if !tutorial_active || state != .PLAYING do return
    steps := tutorial_steps()
    if tutorial_step >= len(steps) do return
    s := steps[tutorial_step]

    dim := rl.Color{0, 0, 0, 140} // ~55%
    if s.region == .NONE {
        rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, dim)
    } else {
        r := tutorial_region_rect(s.region)
        x0, y0 := i32(r.x), i32(r.y)
        x1 := i32(r.x + r.width)
        y1 := i32(r.y + r.height)
        rl.DrawRectangle(0, 0, SCREEN_W, y0, dim)
        rl.DrawRectangle(0, y1, SCREEN_W, SCREEN_H - y1, dim)
        rl.DrawRectangle(0, y0, x0, y1 - y0, dim)
        rl.DrawRectangle(x1, y0, SCREEN_W - x1, y1 - y0, dim)
        pulse := 0.6 + 0.4 * math.sin(time_total * 5)
        rl.DrawRectangleLinesEx(r, 2, {255, 214, 130, u8(110 + 90 * pulse)})
    }

    // speech-bubble panel, bottom-center (raised when it would cover the feed box)
    text := fmt.ctprintf("%s", s.text)
    sub: cstring
    if s.detector == nil {
        sub = fmt.ctprintf("第 %d/%d 步 · 按任意键继续 · Esc 跳过教程", tutorial_step + 1, len(steps))
    } else {
        sub = fmt.ctprintf("第 %d/%d 步 · Esc 跳过教程", tutorial_step + 1, len(steps))
    }
    tw := measure_text(text, 25, true)
    sw := measure_text(sub, 15)
    pw := max(tw, sw) + 56
    ph: i32 = 78
    px := (SCREEN_W - pw) / 2
    py: i32 = SCREEN_H - 196
    if s.region == .FEED_BOX do py = 626
    rl.DrawRectangle(px, py, pw, ph, {12, 15, 26, 242})
    rl.DrawRectangleLinesEx({f32(px), f32(py), f32(pw), f32(ph)}, 1, {255, 210, 140, 170})
    draw_text(text, px + (pw - tw) / 2, py + 13, 25, {255, 236, 180, 255}, true)
    draw_text(sub, px + (pw - sw) / 2, py + 49, 15, {165, 170, 188, 255})
}

// ---------------------------------------------------------------------------
// 演示模式 (attract loop): 30 s idle on the title screen → the AI snake
// starts performing by itself: feeding mode (autopilot is native there) plus
// a scripted cast playlist, with rotating selling-point captions. Any input
// bails back to the title screen. This same scenario is the demo reel the
// SNAKE_RECORD hook captures.
// ---------------------------------------------------------------------------

TITLE_IDLE_ATTRACT_SECS :: 30.0
ATTRACT_CAST_SECS       :: 6.0
ATTRACT_CAPTION_SECS    :: 5.0

AttractItem :: struct {
    word:   string, // non-empty: cast via cast_word (showcase word)
    preset: int,    // word == "": cast via cast_preset
}

ATTRACT_PLAYLIST := [?]AttractItem{
    {preset = 0},          // 苹果
    {word = "火箭辣椒"},    // 剧本蓝图同款：先上天，再坠毁
    {preset = 6},          // 星星
    {word = "星星糖"},
    {preset = 1},          // 辣椒（暴走）
    {preset = 3},          // 手榴弹（炸尾）
    {word = "神秘蛋"},
    {preset = 2},          // 冰棍
    {preset = 5},          // 毒蘑菇（蛇会学乖）
    {preset = 7},          // 神秘蛋预设：每次随机
    {preset = 4},          // 便便（扣分，终身拒吃）
    {word = "星星糖"},
}

ATTRACT_CAPTIONS := [?]string{
    "AI 自动驾驶中——看它怎么飞",
    "每一种食物都是玩家发明的",
    "说一句话，就能造出带剧本的效果",
    "创造你自己的食物吧——按任意键开始！",
}

attract_saved_map  := MapID.VOID // 进入演示前的地图选择，退出时还原
attract_saved_seed : u32 = 0

attract_begin :: proc() {
    attract_active = true
    attract_elapsed = 0
    attract_cast_idx = 0
    attract_cast_t = ATTRACT_CAST_SECS // 第一投立即开火
    attract_topup_t = 0
    title_idle_t = 0
    game_mode = .FEEDING
    // 演示固定在虚空：playlist 的飞行节奏没有针对迷宫调过
    attract_saved_map = map_id
    attract_saved_seed = map_seed
    if map_id != .VOID do map_apply(.VOID)
    reset_game()
    state = .PLAYING
}

attract_update :: proc(dt: f32) {
    if !attract_active do return
    attract_elapsed += dt
    attract_cast_t += dt
    if attract_cast_t >= ATTRACT_CAST_SECS {
        attract_cast_t = 0
        item := ATTRACT_PLAYLIST[attract_cast_idx % len(ATTRACT_PLAYLIST)]
        attract_cast_idx += 1
        if item.word != "" {
            cast_word(item.word)
        } else {
            cast_preset(item.preset)
        }
    }
    // 断粮救场：没有玩家看着，别让蛇空场超过 ~2 秒（演示观赏性）
    attract_topup_t += dt
    if attract_topup_t >= 2.0 {
        attract_topup_t = 0
        if willing_food_count() == 0 {
            cast_preset(int(rand.int_max(8)))
        }
    }
}

attract_exit :: proc() {
    attract_active = false
    title_idle_t = 0
    if map_id != attract_saved_map { // 还原料演示前的地图（洞穴按原种子确定性重建）
        map_seed = attract_saved_seed
        map_apply(attract_saved_map)
    }
    state = .TITLE
    reset_game()
}

attract_caption_index :: proc() -> int {
    return int(attract_elapsed / ATTRACT_CAPTION_SECS) % len(ATTRACT_CAPTIONS)
}

// title-screen idle clock; returns true once when 30 s elapse with no input
attract_idle_tick :: proc(dt: f32, any_input: bool) -> bool {
    if any_input {
        title_idle_t = 0
        return false
    }
    title_idle_t += dt
    return title_idle_t >= TITLE_IDLE_ATTRACT_SECS
}

// rotating selling-point caption bar, bottom-center (replaces the H hint)
draw_attract :: proc() {
    if !attract_active do return
    c := fmt.ctprintf("%s", ATTRACT_CAPTIONS[attract_caption_index()])
    w := measure_text(c, 23, true)
    x := (SCREEN_W - w) / 2
    y: i32 = SCREEN_H - 116
    rl.DrawRectangle(x - 22, y - 9, w + 44, 40, {10, 12, 20, 200})
    rl.DrawRectangleLinesEx({f32(x - 22), f32(y - 9), f32(w + 44), 40}, 1, {255, 210, 140, 130})
    draw_text(c, x, y, 23, {255, 232, 175, 255}, true)
}

// ---------------------------------------------------------------------------
// 创造台 (Creator Workshop): manual fx sliders + ✨ AI creative descriptions.
// Right-side keyboard-driven panel with a live 3D preview sample; the game
// keeps running while it is open. E opens it in FEEDING mode (with the dex
// open, E clones the selected kind as the starting point).
// ---------------------------------------------------------------------------

Edit_Target :: enum { NONE, NAME, FLAVOR, CREATIVE, MACRO_NAME, NICKNAME }

// cursor rows; the fx block is hidden while edit_has_blueprint is set
Editor_Field :: enum {
    NAME, HUE, SHAPE, RARITY,
    FX_SPEED, FX_SPEED_T, FX_GROWTH, FX_SCORE, FX_SHAKE, FX_CONFUSE,
    FX_BURSTS, FX_TINT,
    CLEAR_BP, FLAVOR, ACT_CREATIVE, ACT_MACRO, ACT_SAVE, ACT_COPY, ACT_ABORT,
}

SHAPE_NAMES  := [4]string{"球", "方块", "圆锥", "宝石"}
RARITY_NAMES := [3]string{"常见", "稀有", "传说"}

editor_row_count :: proc() -> int {
    return 4 + (edit_has_blueprint ? 1 : 8) + 1 + 5
}

editor_field_at :: proc(row: int) -> Editor_Field {
    switch row {
    case 0: return .NAME
    case 1: return .HUE
    case 2: return .SHAPE
    case 3: return .RARITY
    }
    fx_rows := edit_has_blueprint ? 1 : 8
    if row < 4 + fx_rows {
        if edit_has_blueprint do return .CLEAR_BP
        return Editor_Field(int(Editor_Field.FX_SPEED) + (row - 4))
    }
    r := row - 4 - fx_rows
    if r == 0 do return .FLAVOR
    return Editor_Field(int(Editor_Field.ACT_CREATIVE) + (r - 1))
}

free_edit_kind :: proc() {
    if edit_kind.name != "" { delete(edit_kind.name); edit_kind.name = "" }
    if edit_kind.flavor != "" { delete(edit_kind.flavor); edit_kind.flavor = "" }
    if edit_blueprint != "" { delete(edit_blueprint); edit_blueprint = "" }
    edit_has_blueprint = false
}

// a free cell near the map center for the live preview sample
editor_pick_showcase :: proc() {
    c :: GRID_N / 2
    candidates := [?]IV3{
        {c, GRID_N - 2, c}, {c, GRID_N - 3, c},
        {c - 2, GRID_N - 2, c}, {c + 2, GRID_N - 2, c},
        {c, GRID_N - 2, c - 2}, {c, GRID_N - 2, c + 2},
        {c, c + 2, c},
    }
    for cell in candidates {
        if !cell_in_world(cell) || on_snake(cell) || map_solid(cell) do continue
        occupied := false
        for f in foods do if f.pos == cell { occupied = true; break }
        if !occupied {
            editor_showcase = cell
            return
        }
    }
    editor_showcase = candidates[0]
}

editor_begin :: proc() {
    editor_open = true
    editor_sel = 0
    edit_target = .NONE
    edit_len = 0
    edit_rep_timer = 0
    dex_open = false
    editor_pick_showcase()
}

editor_open_blank :: proc() {
    free_edit_kind()
    edit_kind = FoodKind{
        name = strings.clone("我的食物"), author = "自创", flavor = "",
        hue = 45, color = hsv_rgb(45, 0.72, 1.0), shape = .SPHERE,
        size = 0.30, spin = 2.0, rarity = 0,
        fx_speed = 1, fx_speed_t = 0, fx_growth = 1, fx_score = 10,
        fx_shake = 0, fx_tint = {}, fx_confuse = 0, fx_bursts = 1,
    }
    edit_tint_idx = 0
    editor_base_name = ""
    editor_begin()
}

// from the dex: clone the selected kind (blueprint included) as the base
editor_open_from :: proc(kind_idx: int) {
    src := kinds[kind_idx]
    free_edit_kind()
    edit_kind = src // value copy; owned strings re-cloned below
    edit_kind.name = strings.clone(src.name)
    edit_kind.flavor = src.flavor != "" ? strings.clone(src.flavor) : ""
    edit_kind.byline = "" // 保存时落款为当前创作者
    edit_kind.author = "自创"
    edit_kind.blueprint = "" // 编辑器用 edit_blueprint（独立 owned 副本）
    if src.blueprint != "" {
        edit_blueprint = strings.clone(src.blueprint)
        edit_has_blueprint = true
    }
    edit_tint_idx = src.fx_tint.a > 0 ? 1 + (rgb_hue(src.fx_tint) / 30) %% 12 : 0
    editor_base_name = src.name // kinds[] is append-only: the pointer outlives the editor
    editor_begin()
}

editor_close :: proc() {
    editor_open = false
    edit_target = .NONE
    pending_save = false
    free_edit_kind()
}

// rough hue of a tint color, for mapping fx_tint back onto the cycle index
rgb_hue :: proc(c: rl.Color) -> int {
    r := f32(c.r) / 255
    g := f32(c.g) / 255
    b := f32(c.b) / 255
    mx := max(r, max(g, b))
    mn := min(r, min(g, b))
    d := mx - mn
    if d < 1e-5 do return 0
    h: f32
    switch mx {
    case r: h = 60 * math.mod((g - b) / d + 6, 6)
    case g: h = 60 * ((b - r) / d + 2)
    case:   h = 60 * ((r - g) / d + 4)
    }
    return int(h) %% 360
}

// first n runes of s (no allocation; the result aliases s)
utf8_prefix :: proc(s: string, n: int) -> string {
    count := 0
    i := 0
    for i < len(s) {
        if count == n do break
        _, size := utf8.decode_rune_in_string(s[i:])
        if size == 0 do break
        i += size
        count += 1
    }
    return s[:i]
}

// 强度值: purely cosmetic power score from the fx fields or the blueprint
editor_power :: proc() -> int {
    p: f32 = 0
    if edit_has_blueprint && edit_blueprint != "" {
        acts, ok := bp_compile(edit_blueprint)
        if !ok do return 0
        defer bp_free_actions(&acts)
        for a in acts {
            switch a.prim.name {
            case "speed":      p += abs(1 - a.args.f1) * 25 + a.args.f2 * 2
            case "growth":     p += f32(abs(a.args.i1)) * 8
            case "score":      p += f32(abs(a.args.i1)) * 0.5
            case "shake":      p += a.args.f1 * 10
            case "confuse":    p += a.args.f1 * 8
            case "flash":      p += 4
            case "burst":      p += f32(a.args.i1) * 3
            case "spawn_food": p += f32(a.args.i1) * 12
            case "shield":     p += a.args.f1 * 8
            case "reverse":    p += 15
            case "score_mult": p += (a.args.f1 - 1) * 30 + a.args.f2 * 2
            }
        }
    } else {
        k := edit_kind
        p = f32(abs(k.fx_growth)) * 8 + f32(abs(k.fx_score)) * 0.5 +
            f32(abs(k.fx_bursts - 1)) * 3 + k.fx_confuse * 8 + k.fx_shake * 10
        if k.fx_speed_t > 0 do p += abs(1 - k.fx_speed) * 25 + k.fx_speed_t * 2
        if k.fx_tint.a > 0 do p += 4
    }
    return clamp(int(math.round(p)), 0, 999)
}

// ←→ held down: first repeat after 0.35 s, then every 0.06 s
editor_repeat_dir :: proc(dt: f32) -> int {
    pressed := 0
    if rl.IsKeyPressed(.LEFT)  do pressed = -1
    if rl.IsKeyPressed(.RIGHT) do pressed = 1
    if pressed != 0 {
        edit_rep_timer = 0.35
        return pressed
    }
    held := 0
    if rl.IsKeyDown(.LEFT)  do held = -1
    if rl.IsKeyDown(.RIGHT) do held = 1
    if held == 0 {
        edit_rep_timer = 0
        return 0
    }
    edit_rep_timer -= dt
    if edit_rep_timer <= 0 {
        edit_rep_timer = 0.06
        return held
    }
    return 0
}

editor_adjust :: proc(field: Editor_Field, dir: int) {
    k := &edit_kind
    #partial switch field {
    case .HUE:
        k.hue = (k.hue + dir * 5 + 360) %% 360
        k.color = hsv_rgb(f32(k.hue), 0.72, 1.0)
    case .SHAPE:
        k.shape = FoodShape((int(k.shape) + dir + 4) %% 4)
    case .RARITY:
        k.rarity = (k.rarity + dir + 3) %% 3
    case .FX_SPEED:
        k.fx_speed = clamp(k.fx_speed + f32(dir) * 0.05, 0.45, 2.0)
    case .FX_SPEED_T:
        k.fx_speed_t = clamp(k.fx_speed_t + f32(dir) * 0.5, 0, 8)
    case .FX_GROWTH:
        k.fx_growth = clamp(k.fx_growth + dir, -6, 6)
    case .FX_SCORE:
        k.fx_score = clamp(k.fx_score + dir * 5, -50, 100)
    case .FX_SHAKE:
        k.fx_shake = clamp(k.fx_shake + f32(dir) * 0.1, 0, 1)
    case .FX_CONFUSE:
        k.fx_confuse = clamp(k.fx_confuse + f32(dir) * 0.5, 0, 6)
    case .FX_BURSTS:
        k.fx_bursts = clamp(k.fx_bursts + dir, 1, 4)
    case .FX_TINT:
        edit_tint_idx = (edit_tint_idx + dir + 13) %% 13
        if edit_tint_idx == 0 {
            k.fx_tint = {}
        } else {
            tc := hsv_rgb(f32((edit_tint_idx - 1) * 30), 0.85, 1.0)
            k.fx_tint = {tc.r, tc.g, tc.b, 90}
        }
    }
}

editor_begin_edit :: proc(t: Edit_Target) {
    edit_target = t
    edit_len = 0
    src := ""
    #partial switch t {
    case .NAME:   src = edit_kind.name
    case .FLAVOR: src = edit_kind.flavor
    case:         src = ""
    }
    for i := 0; i < len(src) && edit_len < len(edit_buf) - 1; i += 1 {
        edit_buf[edit_len] = src[i]
        edit_len += 1
    }
}

editor_commit_edit :: proc() {
    text := string(edit_buf[:edit_len])
    t := edit_target
    edit_target = .NONE
    switch t {
    case .NAME:
        trimmed := strings.trim_space(text)
        if edit_kind.name != "" do delete(edit_kind.name)
        edit_kind.name = trimmed != "" ? strings.clone(trimmed) : ""
    case .FLAVOR:
        trimmed := strings.trim_space(text)
        if edit_kind.flavor != "" do delete(edit_kind.flavor)
        edit_kind.flavor = trimmed != "" ? strings.clone(trimmed) : ""
    case .CREATIVE:
        editor_submit_creative(strings.trim_space(text))
    case .MACRO_NAME:
        editor_submit_macro(strings.trim_space(text))
    case .NICKNAME:
        pending_save = false
        trimmed := strings.trim_space(text)
        if trimmed != "" do save_creator(utf8_prefix(trimmed, 16))
        editor_do_save(pending_copy)
    case .NONE:
    }
}

editor_submit_creative :: proc(desc: string) {
    if desc == "" do return
    if !llm_enabled {
        set_toast("未配置 API Key，只能手动设计")
        return
    }
    if llm_is_cooking() || !llm_start_creative(desc) {
        set_toast("AI 忙，请稍候")
    }
}

editor_submit_macro :: proc(name: string) {
    if name == "" {
        set_toast("原语名称不能为空")
        return
    }
    if macro_define(name, edit_blueprint) {
        set_toast(fmt.tprintf("原语已保存: %s，AI 设计时可以引用它", name))
    } else {
        set_toast("原语保存失败：蓝图无效")
    }
}

// finalize the scratch kind into kinds[], spawn one, and keep the editor open
editor_save_kind :: proc() -> int {
    base := strings.trim_space(edit_kind.name)
    if base == "" do base = "无名料理"
    name := base
    suffix := 1
    for {
        if _, taken := kind_by_name[name]; !taken do break
        suffix += 1
        name = fmt.tprintf("%s~%d", base, suffix)
    }
    k := FoodKind{
        name = strings.clone(name), author = "自创",
        flavor = edit_kind.flavor != "" ? strings.clone(edit_kind.flavor) : "",
        hue = edit_kind.hue, color = hsv_rgb(f32(edit_kind.hue), 0.72, 1.0),
        shape = edit_kind.shape, size = edit_kind.size, spin = edit_kind.spin,
        rarity = edit_kind.rarity,
        fx_speed = edit_kind.fx_speed, fx_speed_t = edit_kind.fx_speed_t,
        fx_growth = edit_kind.fx_growth, fx_score = edit_kind.fx_score,
        fx_shake = edit_kind.fx_shake, fx_tint = edit_kind.fx_tint,
        fx_confuse = edit_kind.fx_confuse, fx_bursts = edit_kind.fx_bursts,
        blueprint = edit_has_blueprint && edit_blueprint != "" ? strings.clone(edit_blueprint) : "",
        byline = creator_byline != "" ? strings.clone(creator_byline) : "",
    }
    append(&kinds, k)
    idx := len(kinds) - 1
    kind_by_name[k.name] = idx
    spawn_kind(idx)
    last_cast_kind = idx
    if creation_persist() {
        set_toast(fmt.tprintf("已保存并投放: %s", k.name))
    } else {
        set_toast("作品库已满(64)，请在图鉴按 X 删除一些")
    }
    return idx
}

editor_request_save :: proc(copy_after: bool) {
    if creator_byline == "" && !creator_asked {
        // 首次保存：先问昵称（写 creator.txt；env SNAKE_CREATOR 优先）
        creator_asked = true
        pending_save = true
        pending_copy = copy_after
        editor_begin_edit(.NICKNAME)
        return
    }
    editor_do_save(copy_after)
}

editor_do_save :: proc(copy_after: bool) {
    idx := editor_save_kind()
    if copy_after do copy_share_code(idx)
}

editor_activate :: proc(field: Editor_Field) {
    #partial switch field {
    case .NAME:
        editor_begin_edit(.NAME)
    case .FLAVOR:
        editor_begin_edit(.FLAVOR)
    case .CLEAR_BP:
        if edit_blueprint != "" { delete(edit_blueprint); edit_blueprint = "" }
        edit_has_blueprint = false
        set_toast("蓝图已清除，恢复滑杆编辑")
    case .ACT_CREATIVE:
        editor_begin_edit(.CREATIVE)
    case .ACT_MACRO:
        if !edit_has_blueprint {
            set_toast("需要先有蓝图才能存为原语")
        } else {
            editor_begin_edit(.MACRO_NAME)
        }
    case .ACT_SAVE:
        editor_request_save(false)
    case .ACT_COPY:
        editor_request_save(true)
    case .ACT_ABORT:
        editor_close()
    }
}

// AI 设计完成: fill the scratch kind from the creative result (takes ownership
// of the result's owned strings)
editor_apply_creative :: proc(res: ^Creative_Result) {
    if edit_kind.name != "" do delete(edit_kind.name)
    edit_kind.name = res.name
    if edit_kind.flavor != "" do delete(edit_kind.flavor)
    edit_kind.flavor = res.flavor
    if edit_blueprint != "" do delete(edit_blueprint)
    edit_blueprint = res.blueprint
    edit_has_blueprint = true
    edit_kind.hue = res.hue
    edit_kind.color = hsv_rgb(f32(res.hue), 0.72, 1.0)
    edit_kind.shape = FoodShape(res.shape)
    edit_kind.rarity = res.rarity
    res.name = ""
    res.flavor = ""
    res.blueprint = ""
    editor_sel = min(editor_sel, editor_row_count() - 1)
}

// text-edit sub-state keys: ASCII typing + Cmd+V paste (UTF-8 through, so
// Chinese works via paste) + rune-aware backspace + Enter/Esc
editor_text_keys :: proc() {
    for {
        c := rl.GetCharPressed()
        if c == 0 do break
        if c >= 32 && c < 127 && edit_len < len(edit_buf) - 1 {
            edit_buf[edit_len] = u8(c)
            edit_len += 1
        }
    }
    if rl.IsKeyPressed(.V) && (rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)) {
        clip := rl.GetClipboardText()
        if clip != nil {
            p := transmute([^]u8)clip
            for i := 0; p[i] != 0 && edit_len < len(edit_buf) - 1; i += 1 {
                if p[i] >= 32 && p[i] != 127 { // 放行可打印 ASCII 与 UTF-8 多字节
                    edit_buf[edit_len] = p[i]
                    edit_len += 1
                }
            }
        }
    }
    if rl.IsKeyPressed(.BACKSPACE) && edit_len > 0 {
        edit_len -= 1
        for edit_len > 0 && (edit_buf[edit_len] & 0xC0) == 0x80 {
            edit_len -= 1 // 按码点回退，不删出半个汉字
        }
    }
    if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
        editor_commit_edit()
        return
    }
    if rl.IsKeyPressed(.ESCAPE) {
        if edit_target == .NICKNAME && pending_save {
            // 跳过昵称也要完成挂起的保存
            pending_save = false
            edit_target = .NONE
            editor_do_save(pending_copy)
            return
        }
        edit_target = .NONE
    }
}

editor_handle_input :: proc(dt: f32) {
    if edit_target != .NONE {
        editor_text_keys()
        return
    }
    if rl.IsKeyPressed(.V) do toggle_view()
    if rl.IsKeyPressed(.M) do modern_skin = !modern_skin
    if rl.IsKeyPressed(.ESCAPE) {
        editor_close()
        return
    }
    rows := editor_row_count()
    if rl.IsKeyPressed(.UP)   do editor_sel = max(0, editor_sel - 1)
    if rl.IsKeyPressed(.DOWN) do editor_sel = min(rows - 1, editor_sel + 1)
    if dir := editor_repeat_dir(dt); dir != 0 {
        editor_adjust(editor_field_at(editor_sel), dir)
    }
    if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
        editor_activate(editor_field_at(editor_sel))
    }
}

// ---------------------------------------------------------------------------
// 创造台 rendering
// ---------------------------------------------------------------------------

draw_editor_row :: proc(x, w: i32, ry: ^i32, row: int) {
    field := editor_field_at(row)
    sel := editor_sel == row && edit_target == .NONE
    k := &edit_kind

    if field == .CLEAR_BP {
        // read-only blueprint summary block above the 清除蓝图 row
        draw_text("效果蓝图", x + 20, ry^, 15, {150, 200, 255, 255}, true)
        ry^ += 22
        lines := blueprint_summary(edit_blueprint)
        shown := min(len(lines), 8)
        for i in 0..<shown {
            draw_text(fmt.ctprintf("· %s", lines[i]), x + 30, ry^, 13, {175, 185, 205, 230})
            ry^ += 18
        }
        if len(lines) > shown {
            draw_text(fmt.ctprintf("… 共 %d 条", len(lines)), x + 30, ry^, 13, {140, 150, 170, 220})
            ry^ += 18
        }
        if len(lines) == 0 {
            draw_text("（蓝图无法解析）", x + 30, ry^, 13, {255, 130, 130, 230})
            ry^ += 18
        }
        for l in lines do delete(l)
        delete(lines)
        ry^ += 4
    }

    if sel do rl.DrawRectangle(x + 8, ry^ - 4, w - 16, 28, {85, 75, 140, 90})
    label_col := sel ? rl.RAYWHITE : rl.Color{185, 188, 205, 255}
    value_col := sel ? rl.Color{255, 222, 130, 255} : rl.Color{205, 206, 216, 255}

    label: string
    value: string
    vcol := value_col
    switch field {
    case .NAME:
        label = "名称"
        value = utf8_prefix(k.name != "" ? k.name : "（未命名）", 20)
    case .HUE:
        label = "颜色色相"
        value = fmt.tprintf("%d°", k.hue)
    case .SHAPE:
        label = "形状"
        value = SHAPE_NAMES[int(k.shape)]
    case .RARITY:
        label = "稀有度"
        value = RARITY_NAMES[k.rarity]
        vcol = RARITY_COLORS[k.rarity]
    case .FX_SPEED:
        label = "速度倍率"
        value = fmt.tprintf("×%.2f", k.fx_speed)
    case .FX_SPEED_T:
        label = "速度持续"
        value = fmt.tprintf("%.1f 秒", k.fx_speed_t)
    case .FX_GROWTH:
        label = "生长"
        value = fmt.tprintf("%+d 节", k.fx_growth)
    case .FX_SCORE:
        label = "分数"
        value = fmt.tprintf("%+d 分", k.fx_score)
    case .FX_SHAKE:
        label = "震屏"
        value = fmt.tprintf("%.1f", k.fx_shake)
    case .FX_CONFUSE:
        label = "眩晕"
        value = fmt.tprintf("%.1f 秒", k.fx_confuse)
    case .FX_BURSTS:
        label = "烟花"
        value = fmt.tprintf("%d 发", k.fx_bursts)
    case .FX_TINT:
        label = "闪光"
        value = edit_tint_idx == 0 ? "无" : fmt.tprintf("色相 %d°", (edit_tint_idx - 1) * 30)
    case .CLEAR_BP:
        label = "清除蓝图"
        value = "恢复滑杆编辑"
    case .FLAVOR:
        label = "点评"
        value = k.flavor != "" ? utf8_prefix(k.flavor, 18) : "（无，Enter 添加）"
    case .ACT_CREATIVE:
        label = "★ 描述创意"
        value = "让 AI 按你的描述设计"
        vcol = {170, 220, 255, 255}
    case .ACT_MACRO:
        label = "存为原语"
        if edit_has_blueprint {
            value = "AI 之后可引用它"
        } else {
            value = "（需要先有蓝图）"
            label_col = {110, 112, 128, 255}
            vcol = {110, 112, 128, 255}
        }
    case .ACT_SAVE:
        label = "保存并投放"
        value = "进图鉴并生成一个"
    case .ACT_COPY:
        label = "复制分享码"
        value = "先保存再复制"
    case .ACT_ABORT:
        label = "放弃 (Esc)"
        value = "不保存"
    }
    draw_text(fmt.ctprintf("%s", label), x + 20, ry^, 16, label_col, sel)
    if value != "" {
        draw_text(fmt.ctprintf("%s", value), x + 210, ry^ + 1, 15, vcol, sel)
    }
    if field == .HUE {
        rl.DrawRectangle(x + 280, ry^ + 2, 40, 16, k.color)
        rl.DrawRectangleLinesEx({f32(x + 280), f32(ry^ + 2), 40, 16}, 1, {255, 255, 255, 120})
    }
    if field == .FX_TINT && edit_tint_idx > 0 {
        rl.DrawRectangle(x + 330, ry^ + 2, 40, 16, k.fx_tint)
        rl.DrawRectangleLinesEx({f32(x + 330), f32(ry^ + 2), 40, 16}, 1, {255, 255, 255, 120})
    }
    ry^ += 30
}

// drop leading runes until the text fits the width (long pastes stay editable)
fit_tail :: proc(s: string, width: i32, size: i32) -> string {
    out := s
    for len(out) > 0 && measure_text(fmt.ctprintf("%s", out), size, true) > width {
        _, n := utf8.decode_rune_in_string(out)
        if n <= 0 do break
        out = out[n:]
    }
    return out
}

// the inline text-edit overlay (name / flavor / creative / macro / nickname)
draw_editor_input :: proc(x, y, w, h: i32) {
    prompt: cstring
    switch edit_target {
    case .NAME:       prompt = "名称？"
    case .FLAVOR:     prompt = "点评一句话（可空）"
    case .CREATIVE:   prompt = "描述你想要的效果，AI 来设计"
    case .MACRO_NAME: prompt = "原语名称？"
    case .NICKNAME:   prompt = "你的创作者昵称？"
    case .NONE:       prompt = ""
    }
    bw: i32 = w - 60
    bh: i32 = 64
    bx := x + 30
    by := y + h - 180
    rl.DrawRectangle(bx - 6, by - 6, bw + 12, bh + 44, {8, 10, 18, 248})
    rl.DrawRectangleLinesEx({f32(bx - 6), f32(by - 6), f32(bw + 12), f32(bh + 44)}, 2, {255, 200, 120, 230})
    draw_text(prompt, bx + 12, by + 6, 15, {200, 190, 160, 255})
    shown := fit_tail(string(edit_buf[:edit_len]), bw - 40, 22)
    draw_text(fmt.ctprintf("%s", shown), bx + 12, by + 30, 22, rl.RAYWHITE, true)
    if time_total * 2 - math.floor(time_total * 2) < 0.55 {
        tw := measure_text(fmt.ctprintf("%s", shown), 22, true)
        draw_text("_", bx + 12 + tw + 3, by + 30, 22, rl.RAYWHITE, true)
    }
    hint: cstring = "Enter 确认 · Esc 取消 · Cmd+V 粘贴"
    if edit_target == .NICKNAME do hint = "Enter 确认 · Esc 跳过（下次再设）"
    draw_text(hint, bx + 12, by + bh + 12, 13, {140, 145, 160, 255})
}

draw_editor :: proc() {
    if !editor_open do return
    w: i32 = 560
    x := SCREEN_W - w - 16
    y: i32 = 16
    h: i32 = SCREEN_H - 32
    rl.DrawRectangle(x, y, w, h, {12, 14, 24, 238})
    rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 1, {150, 130, 210, 200})

    // header: title + 强度值 + 1-5 stars
    power := editor_power()
    stars := clamp(1 + power / 200, 1, 5)
    draw_text("创造台", x + 18, y + 12, 26, {255, 214, 130, 255}, true)
    draw_text(fmt.ctprintf("强度 %d", power), x + 130, y + 20, 17, {200, 205, 220, 255}, true)
    sx := x + 225
    for i in 1..=5 {
        col := i <= stars ? rl.Color{255, 210, 80, 255} : rl.Color{90, 92, 110, 255}
        draw_text("★", sx, y + 18, 20, col, true)
        sx += 22
    }
    if editor_base_name != "" {
        draw_text(fmt.ctprintf("以此为基础改造: %s", editor_base_name), x + 345, y + 22, 14, {150, 155, 175, 255})
    }

    ry := y + 52
    rows := editor_row_count()
    for row in 0..<rows {
        draw_editor_row(x, w, &ry, row)
    }

    if llm_is_cooking() && llm_job_mode == .CREATIVE {
        pulse := 0.6 + 0.4 * math.sin(time_total * 6)
        draw_text("AI 设计中…", x + 18, y + h - 56, 17, {255, u8(170 + 50 * pulse), 120, 255}, true)
    }
    draw_text("↑↓ 选择   ←→ 调整   Enter 编辑/确认   Esc 关闭", x + 18, y + h - 30, 14, {140, 145, 165, 255})

    if edit_target != .NONE do draw_editor_input(x, y, w, h)
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
// Creator nickname: env SNAKE_CREATOR wins; otherwise creator.txt (written on
// the very first 创造台 save). The byline rides along in v2 share codes.
// ---------------------------------------------------------------------------

CREATOR_FILE :: "creator.txt"

load_creator :: proc() {
    if creator_byline != "" do return // env already set it
    data, err := os.read_entire_file(CREATOR_FILE, context.allocator)
    if err != nil do return
    defer delete(data)
    s := strings.trim_space(string(data))
    if s != "" do creator_byline = strings.clone(s)
}

save_creator :: proc(name: string) {
    if creator_byline != "" do delete(creator_byline)
    creator_byline = strings.clone(name)
    _ = os.write_entire_file(CREATOR_FILE, transmute([]u8)creator_byline)
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// 球体底部的 y 坐标（在 (x,z) 处）：食物/蛇身垂直向下投射到球壳内侧。
floor_y :: proc(x, z: f32) -> f32 {
    R := WORLD_RADIUS
    d := R*R - x*x - z*z
    if d < 0 do return -R
    return -math.sqrt(d)
}

// 球形边界：格对齐纬线 / 经线 + 三条轴色大圆。
// 实心球壳不能先画——DrawSphere 是批渲染，DisableDepthMask 会在 flush 前被
// EnableDepthMask 抵消，近半球写入深度后蛇和食物全被挡住。
// DrawCircle3D 在 XY 平面画圆再绕轴旋转：360° 是恒等变换，轴色大圆必须用 0°/90°。
draw_boundaries :: proc() {
    R := WORLD_RADIUS
    line_col := rl.Color{90, 120, 200, 55}
    // 纬线：落在每个格子中心的 y，对应原来六面格子线
    h := f32(GRID_N - 1) * 0.5 * CELL
    for i in 0..<GRID_N {
        y := f32(i) * CELL - h
        rr := R * R - y * y
        if rr <= 0.08 do continue
        rl.DrawCircle3D({0, y, 0}, math.sqrt(rr), {1, 0, 0}, 90, line_col)
    }
    // 经线：6 条过极点的大圆，每 30° 一条
    for k in 0..<6 {
        rl.DrawCircle3D({0, 0, 0}, R, {0, 1, 0}, f32(k) * 30, line_col)
    }

    // 三条轴色大圆，颜色与罗盘、小地图一致
    rl.DrawCircle3D({0, 0, 0}, R, {0, 0, 1}, 0,  rl.Color{AXIS_Z.r, AXIS_Z.g, AXIS_Z.b, 130}) // XY
    rl.DrawCircle3D({0, 0, 0}, R, {0, 1, 0}, 90, rl.Color{AXIS_X.r, AXIS_X.g, AXIS_X.b, 130}) // YZ
    rl.DrawCircle3D({0, 0, 0}, R, {1, 0, 0}, 90, rl.Color{AXIS_Y.r, AXIS_Y.g, AXIS_Y.b, 130}) // ZX
}

// 实心球壳放在蛇/食物之后画：深度测试让远半球被挡住，近半球只加一层淡蓝。
// 必须在关深度写入期间 flush，否则下一次 EnableDepthMask 会让球壳重新遮住内部。
draw_sphere_shell :: proc() {
    rlgl.DisableDepthMask()
    rl.DrawSphere({0, 0, 0}, WORLD_RADIUS, rl.Color{80, 110, 190, 18})
    rlgl.DrawRenderBatchActive()
    rlgl.EnableDepthMask()
}

// 障碍地图：深青灰砖块 + 顶部亮面 + 边缘微光；≤ ~10% 的格子，全画即可
MAP_BLOCK_COL :: rl.Color{70, 80, 95, 230}
MAP_TOP_COL   :: rl.Color{104, 118, 138, 235}
MAP_EDGE_COL  :: rl.Color{150, 168, 192, 110}

draw_map :: proc() {
    if !map_has_walls do return
    s :: f32(CELL) * 0.98
    for i in 0..<CELLS {
        if !map_bit(i) do continue
        if !cell_in_world(cell3(i)) do continue // 球外的障碍不画（角落禁区）
        p := cell_to_world(cell3(i))
        rl.DrawCubeV(p, {s, s, s}, MAP_BLOCK_COL)
        rl.DrawCubeV(p + {0, s * 0.47, 0}, {s * 0.92, 0.05, s * 0.92}, MAP_TOP_COL)
        rl.DrawCubeWires(p, s, s, s, MAP_EDGE_COL)
    }
}

// Dotted flight path ahead of the head, following the spherical great-circle
// the snake will actually take (not a straight grid ray).
draw_path_hint :: proc() {
    if state != .PLAYING && state != .PAUSED do return

    PATH_MAX :: 20
    pts: [PATH_MAX]IV3
    n_pts := 0
    cur := snake[0]
    cd := dir
    obstacle_dist := 0
    hit_self := false
    found := false
    for i in 1..=PATH_MAX {
        nxt, nd, ok := advance_on_sphere(cur, cd)
        if !ok {
            obstacle_dist = i
            found = true
            break
        }
        if map_solid(nxt) {
            obstacle_dist = i
            found = true
            break
        }
        if on_snake(nxt) {
            obstacle_dist = i
            hit_self = true
            found = true
            break
        }
        pts[n_pts] = nxt
        n_pts += 1
        cur = nxt
        cd = nd
    }
    if !found do obstacle_dist = n_pts + 1

    col := rl.Color{80, 230, 110, 170}          // safe
    if obstacle_dist <= 4 do col = rl.Color{240, 200, 60, 190}   // caution
    if obstacle_dist <= 2 do col = rl.Color{240, 70, 60, 220}    // danger

    hp := cell_to_world(snake[0])
    if n_pts > 0 {
        prev := hp
        for i in 0..<n_pts {
            q := cell_to_world(pts[i])
            SEG :: 4
            for s in 0..<SEG {
                t0 := f32(s) / SEG
                t1 := f32(s + 1) / SEG
                rl.DrawLine3D(slerp_v3(prev, q, t0), slerp_v3(prev, q, t1), col)
            }
            prev = q
        }
        for i in 2..<n_pts {
            rl.DrawSphereEx(cell_to_world(pts[i]), 0.05, 6, 6, col)
        }
    }

    if found && n_pts > 0 {
        p := cell_to_world(pts[n_pts - 1])
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
            rl.DrawLine3D(slerp_v3(a, b, t0), slerp_v3(a, b, t1), col)
        }
    }
}

draw_food :: proc() {
    bob := math.sin(time_total * 3.2) * 0.08
    p := cell_to_world(food)
    p.y += bob
    rl.DrawSphereEx(p, 0.34, 12, 12, rl.RED)
    rl.DrawSphereEx(p + {-0.09, 0.1, -0.09}, 0.12, 8, 8, rl.Color{255, 130, 130, 255})
    // pulsing wire sphere beacon
    k := 0.5 + 0.1 * math.sin(time_total * 4)
    rl.DrawSphereWires(p, k, 8, 8, rl.Color{255, 90, 90, 160})
    // vertical beam down to the sphere's inner bottom for depth perception
    fy := floor_y(p.x, p.z)
    rl.DrawLine3D({p.x, p.y - 0.4, p.z}, {p.x, fy, p.z}, rl.Color{255, 80, 80, 90})
    rl.DrawCubeV({p.x, fy + 0.02, p.z}, {0.3, 0.04, 0.3}, rl.Color{255, 80, 80, 70})
}

// ---------------------------------------------------------------------------
// Feeding Lab rendering
// ---------------------------------------------------------------------------

RARITY_COLORS := [3]rl.Color{
    {190, 195, 210, 255}, // common
    {90, 200, 255, 255},  // rare
    {255, 210, 70, 255},  // legendary
}

// one food of the given kind at a cell (shared by real foods and the 创造台
// live preview, so rarity glow/spin look exactly the same)
draw_one_food :: proc(k: FoodKind, pos: IV3, spin: f32, rot: f32) {
    p := cell_to_world(pos)
    p.y += math.sin(time_total * 3.2 + spin) * 0.07

    s := k.size
    dim: f32 = rot > 0 ? 0.45 : 1.0 // 腐烂变暗
    col := rl.Color{u8(f32(k.color.r) * dim), u8(f32(k.color.g) * dim), u8(f32(k.color.b) * dim), 255}

    rlgl.PushMatrix()
    rlgl.Translatef(p.x, p.y, p.z)
    rlgl.Rotatef(spin + time_total * 60 * k.spin * 0.5, 0, 1, 0)
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
    if k.rarity > 0 && rot <= 0 {
        rc := RARITY_COLORS[k.rarity]
        rl.BeginBlendMode(.ADDITIVE)
        rl.DrawSphereEx(p, s * 1.6 + 0.06 * math.sin(time_total * 4), 10, 8,
            {rc.r, rc.g, rc.b, k.rarity == 2 ? 26 : 14})
        rl.EndBlendMode()
    }
    // 落地参考线（和苹果的落地光束一个道理；终点在球壳内侧）
    rl.DrawLine3D({p.x, p.y - s - 0.05, p.z}, {p.x, floor_y(p.x, p.z), p.z}, {col.r, col.g, col.b, 60})
}

draw_foods :: proc() {
    for f in foods {
        draw_one_food(kinds[f.kind], f.pos, f.spin, f.rot)
    }
    if editor_open {
        // 创造台实时预览：样品食物在展示格旋转（不进入 foods，不会被吃）
        draw_one_food(edit_kind, editor_showcase, 0, 0)
        p := cell_to_world(editor_showcase)
        blink := 0.5 + 0.5 * math.sin(time_total * 5)
        rl.DrawCubeWires(p, 0.48, 0.48, 0.48, {255, 240, 180, u8(70 + 60 * blink)})
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
    if editor_open {
        // 预览样品的小标签
        p := cell_to_world(editor_showcase)
        p.y += 0.7
        sp := rl.GetWorldToScreen(p, cam)
        w := measure_text("预览", 14, true)
        x := i32(sp.x) - w / 2
        y := i32(sp.y)
        rl.DrawRectangle(x - 6, y - 2, w + 12, 20, {10, 12, 20, 150})
        draw_text("预览", x, y, 14, {255, 240, 180, 240}, true)
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
// (retired 作品库 kinds are hidden from the dex)
dex_visible_rows :: proc() -> int {
    budget := SCREEN_H - 170 - 40 - 60 - 26 // panel top, bottom margin, header, footer
    rows := 0
    used := 0
    for k in kinds {
        if k.retired do continue
        used += int(dex_row_h(k))
        if used > budget do break
        rows += 1
    }
    return rows
}

// kinds index of the nth non-retired kind (dex row -> kinds index), -1 if absent
dex_kind_at :: proc(row: int) -> int {
    n := 0
    for k, i in kinds {
        if k.retired do continue
        if n == row do return i
        n += 1
    }
    return -1
}

// all non-retired kinds indices, in dex order (temp allocator)
dex_visible_list :: proc() -> []int {
    list := make([dynamic]int, 0, len(kinds), context.temp_allocator)
    for k, i in kinds do if !k.retired { append(&list, i) }
    return list[:]
}

// 图鉴: all food kinds discovered so far (↑/↓ select, Enter 投喂, X 删除自创, C copies the share code)
draw_dex :: proc() {
    if !dex_open do return
    w: i32 = 360
    x := SCREEN_W - w - 20
    y: i32 = 170
    vis := dex_visible_list()
    rows := dex_visible_rows()
    total := 0
    for i in 0..<rows do total += int(dex_row_h(kinds[vis[i]]))
    h := i32(60 + total + 26) // header + rows + footer hints
    rl.DrawRectangle(x, y, w, h, {12, 14, 24, 225})
    rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 1, {120, 128, 150, 180})
    draw_text(fmt.ctprintf("食物图鉴 · 已发现 %d 种", len(vis)), x + 16, y + 12, 20,
        rl.RAYWHITE, true)

    buf: [192]u8
    sel := min(dex_sel, rows - 1)
    ry := y + 44
    for i in 0..<rows {
        k := kinds[vis[i]]
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
        if k.blueprint != "" do tag(buf[:], &n, "[蓝图]")
        immune := kind_harmful(&kinds[vis[i]]) && snake_memory[k.name] >= 2
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
    if len(vis) > rows {
        draw_text(fmt.ctprintf("... and %d more", len(vis) - rows), x + 40, ry, 14,
            {120, 125, 140, 255})
    }
    draw_text("Enter 投喂 · X 删除 · C 复制", x + 16, y + h - 24, 13, {140, 145, 160, 255})
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
    joints := fair_sphere_pts(snake_joint_pts(alpha))
    spine, u_of := build_arc_spine(joints)

    // floor projection shadows (depth cue) onto the sphere's inner bottom
    for p in joints {
        rl.DrawCubeV({p.x, floor_y(p.x, p.z) + 0.02, p.z}, {0.4, 0.03, 0.4}, rl.Color{80, 220, 100, 26})
    }
    if !hide_head {
        hp := joints[0]
        rl.DrawLine3D({hp.x, hp.y, hp.z}, {hp.x, floor_y(hp.x, hp.z), hp.z}, rl.Color{200, 255, 200, 36})
    }

    // 弧管身子：格子折线只用来定骨架，画出来是连续球面弧
    m := len(spine)
    for k := m - 1; k >= 0; k -= 1 {
        if hide_head && k == 0 do break
        t := u_of[k]
        col := rl.Color{
            u8(60  + t * 20),
            u8(220 - t * 90),
            u8(90  - t * 40),
            255,
        }
        size: f32 = 0.82 - 0.25 * t
        if k == 0 do size = 0.92
        if k < m - 1 {
            rn: f32 = 0.82 - 0.25 * u_of[k + 1]
            rl.DrawCylinderEx(spine[k], spine[k + 1], size * 0.52, rn * 0.52, 8, col)
        }
        rl.DrawSphereEx(spine[k], size * 0.52, 8, 6, col)
    }

    if !hide_head {
        p := joints[0]
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

// 蛇身连续半径：u∈[0,1]，0=头、1=尾尖，与 seg_radius 在关节点处一致
spine_radius :: proc(u: f32) -> f32 {
    if u <= 1e-3 do return 0.46
    return 0.40 * (1.0 - 0.62 * u)
}

// Catmull-Rom 样条段：p1→p2，参数 t∈[0,1]
catmull_rom :: proc(p0, p1, p2, p3: rl.Vector3, t: f32) -> rl.Vector3 {
    t2 := t * t
    t3 := t2 * t
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t +
        (2.0*p0 - 5.0*p1 + 4.0*p2 - p3) * t2 +
        (-p0 + 3.0*p1 - 3.0*p2 + p3) * t3)
}

// 本帧关节点：格子之间用球面插值，身体滑动时走弧而不是弦
snake_joint_pts :: proc(alpha: f32, allocator := context.temp_allocator) -> []rl.Vector3 {
    n := len(snake)
    pts := make([]rl.Vector3, n, allocator)
    for i in 0..<n {
        cur := cell_to_world(snake[i])
        j := min(i, len(prev_snake) - 1)
        pts[i] = j >= 0 ? slerp_v3(cell_to_world(prev_snake[j]), cur, alpha) : cur
    }
    return pts
}

// 把头尾钉住，中间方向在球面上做拉普拉斯光顺，把格子折线收成一条弧。
// 逻辑仍一格一格走；只有绘制骨架被拉圆。
fair_sphere_pts :: proc(pts: []rl.Vector3, allocator := context.temp_allocator) -> []rl.Vector3 {
    n := len(pts)
    out := make([]rl.Vector3, n, allocator)
    copy(out, pts)
    if n < 3 do return out

    dirs := make([]rl.Vector3, n, allocator)
    rads := make([]f32, n, allocator)
    for i in 0..<n {
        rads[i] = len_v3(out[i])
        dirs[i] = rads[i] > 1e-4 ? out[i] / rads[i] : rl.Vector3{0, 1, 0}
    }
    // 半径往整条蛇的平均球壳靠，折线才落在同一个球面上
    r_mean: f32 = 0
    for r in rads do r_mean += r
    r_mean /= f32(n)

    FAIR_ITERS :: 5
    for _ in 0..<FAIR_ITERS {
        next := make([]rl.Vector3, n, allocator)
        next[0] = dirs[0]
        next[n - 1] = dirs[n - 1]
        for i in 1..<n-1 {
            s := dirs[i - 1] + dirs[i] * 2 + dirs[i + 1]
            ln := len_v3(s)
            next[i] = ln > 1e-5 ? s / ln : dirs[i]
        }
        copy(dirs, next)
    }
    for i in 0..<n {
        r := rads[i] * 0.35 + r_mean * 0.65
        out[i] = dirs[i] * r
    }
    // 头必须还在格子上，吃豆/碰撞才对得上
    out[0] = pts[0]
    return out
}

// 关节点之间用大圆细分，再径向拉回光顺半径 —— 整条身子是连续弧管
build_arc_spine :: proc(pts: []rl.Vector3, allocator := context.temp_allocator) -> (spine: []rl.Vector3, u_of: []f32) {
    n := len(pts)
    if n == 0 do return {}, {}
    SPINE_SUB :: 8
    buf := make([dynamic]rl.Vector3, 0, n * SPINE_SUB + 1, allocator)
    ubuf := make([dynamic]f32, 0, n * SPINE_SUB + 1, allocator)
    append(&buf, pts[0])
    append(&ubuf, 0)
    if n == 1 do return buf[:], ubuf[:]
    denom := f32(max(n - 1, 1))
    for i in 0..<n-1 {
        for j in 1..=SPINE_SUB {
            t := f32(j) / f32(SPINE_SUB)
            q := slerp_v3(pts[i], pts[i + 1], t)
            append(&buf, q)
            append(&ubuf, (f32(i) + t) / denom)
        }
    }
    return buf[:], ubuf[:]
}

dist_v3 :: proc(a, b: rl.Vector3) -> f32 {
    dx, dy, dz := a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
}

draw_snake_modern :: proc(alpha: f32, hide_head: bool) {
    n := len(snake)
    light := norm_v3(rl.Vector3{0.45, 1.0, 0.3})
    fog_ref := cam_dist * 2.0 + 10

    raw := snake_joint_pts(alpha)
    pts := fair_sphere_pts(raw)
    spine, u_of := build_arc_spine(pts)

    // floor projection shadows (depth cue)
    for i in 0..<n {
        p := pts[i]
        r := seg_radius(i, n)
        rl.DrawCubeV({p.x, floor_y(p.x, p.z) + 0.02, p.z}, {r * 1.7, 0.03, r * 1.7}, rl.Color{60, 200, 130, 20})
    }
    if !hide_head {
        hp := pts[0]
        rl.DrawLine3D({hp.x, hp.y, hp.z}, {hp.x, floor_y(hp.x, hp.z), hp.z}, rl.Color{200, 255, 220, 30})
    }

    // 身体圆管：沿平滑脊柱画锥形管（尾→头），转弯自然过渡
    m := len(spine)
    for k := m - 1; k >= 0; k -= 1 {
        if hide_head && k == 0 do break
        spl_u := u_of[k]
        r := spine_radius(spl_u) * (1 + 0.045 * math.sin(time_total * 3 + spl_u * 22))
        col := seg_color(int(spl_u * f32(max(n - 1, 1))), n)
        fog := clamp(1.18 - dist_v3(spine[k], cam.position) / fog_ref, 0.40, 1)
        body := rl.Color{u8(f32(col.r) * fog), u8(f32(col.g) * fog), u8(f32(col.b) * fog), col.a}
        rl.DrawSphereEx(spine[k], r, 8, 6, body)
        if k < m - 1 {
            rn := spine_radius(u_of[k + 1]) * (1 + 0.045 * math.sin(time_total * 3 + u_of[k + 1] * 22))
            rl.DrawCylinderEx(spine[k], spine[k + 1], r, rn, 8, body)
        }
    }

    // 头球 + 眼睛画在真实格子上；身子只靠弧管，不再一格一颗珠子把弧折断
    if !hide_head {
        r := seg_radius(0, n) * (1 + 0.045 * math.sin(time_total * 3))
        col := seg_color(0, n)
        fog := clamp(1.18 - dist_v3(pts[0], cam.position) / fog_ref, 0.40, 1)
        body := rl.Color{u8(f32(col.r) * fog), u8(f32(col.g) * fog), u8(f32(col.b) * fog), col.a}
        rl.DrawSphereEx(pts[0], r, 12, 9, body)
        rl.DrawSphereEx(pts[0] + light * (r * 0.58), r * 0.40, 8, 6, rl.Color{255, 255, 255, 52})
        f := rl.Vector3{f32(dir.x), f32(dir.y), f32(dir.z)}
        s := abs(f.y) == 1 ? rl.Vector3{1, 0, 0} : norm_v3(cross_v3(f, {0, 1, 0}))
        u := norm_v3(cross_v3(s, f))
        e1 := pts[0] + f * 0.40 + s * 0.21 + u * 0.19
        e2 := pts[0] + f * 0.40 - s * 0.21 + u * 0.19
        rl.DrawSphereEx(e1, 0.12, 8, 8, rl.WHITE)
        rl.DrawSphereEx(e2, 0.12, 8, 8, rl.WHITE)
        rl.DrawSphereEx(e1 + f * 0.07, 0.06, 8, 8, rl.BLACK)
        rl.DrawSphereEx(e2 + f * 0.07, 0.06, 8, 8, rl.BLACK)
        rl.BeginBlendMode(.ADDITIVE)
        rl.DrawSphereEx(pts[0], 0.85 + 0.1 * math.sin(time_total * 2.5), 14, 10,
            rl.Color{50, 230, 130, 30})
        rl.EndBlendMode()
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
    "投喂 快捷食物 图鉴 视角 皮肤 转 暂停 重开 创造台",
    "食物图鉴 · 已发现 种",
    "加速 减速 节 分 眩晕 爆炸 已免疫 蓝图",
    "腐烂中",
    "投喂什么？",
    "投放 取消",
    "蛇自动觅食，你来发明食物 —",
    "预设 本地 分享 烹饪中 完成 失败 使用 配方 点评 复制 码 粘贴 无效 输入 或 已投喂",
    // 创造台 (editor) labels, toasts and prompts
    "预览 强度 以此为基础改造 名称 未命名 颜色 色相 形状 稀有度 常见 稀有 传说 球 方块 圆锥 宝石",
    "速度倍率 持续 生长 分数 震屏 烟花 闪光 无 清除 恢复滑杆编辑 效果 解析 添加 描述创意 让 按 你 的 设计 存为原语 之后 引用 需要 先有 保存并投放 分享码 先保存再复制 放弃 不保存 选择 调整 确认 关闭 跳过 下次 再设 昵称 一句话 可空 想要 来",
    "已清除 未配置 只能手动 忙请稍候 不能为空 保存失败 已保存 时可以 请换个说法 请重试或 先有蓝图才能 无名料理 设计中 金身 得分 自创 样品",
    "速度不变 长 炸掉尾巴 长度不变 全屏 粒子 下个蛋 无敌护盾 掉头反转 立刻 秒后 重复次 概率 宏 未定义 共条 我的食物 火箭辣椒 坠毁 咯哒",
    "★×°…·「」（），。？： › ←↑→↓ 、 ⇧ 删",
    // 教练模式 + 演示模式 (coach tutorial + attract captions)
    "这条蛇是开的你的工作是喂它！按打开投喂框输入任意词，回车投放试试预设食物图鉴翻页再投一个创造台调整数值然后保存并投放毕业复制分享码发给朋友。蛇归你了第步·跳过教程按任意键继续转向（屏幕方向）切换第一人称环绕视角可以随时让救场",
    "自动驾驶中——看它怎么飞每一种食物都是玩家发明的说一句话，就能造出带剧本的效果创造你自己的食物吧——按任意键开始！新手教程标题界面秒无操作进入演示",
    // 战报图 (battle report card) labels, ranks, toasts
    "战报经典模式得分最高长度节吃掉个时长奇葩菜单段位这局还什么都没吃到再得晋升已是按任意键关闭保存并复制文字快去炫耀吧蛇界萌新初出茅庐老练机长球形传说三维之神新手饲养员资深黑暗料理大师食神下凡莲虹虚榴彩",
    // F 模式切换：HUD 模式行 + 切换/教程提示 toast + 底部按键条
    "模式 经典 手动 投喂 已切换 接管 方向盘交还你 教程进行中——完成或 跳过后再切换",
    // 障碍地图 (obstacle maps) names + title-screen selector
    "地图 切换 虚空 石柱林 十字回廊 蜂巢 随机洞穴",
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
    rl.DrawRectangle(px, py, size, size, rl.Color{14, 16, 24, 200})
    // playable disc = sphere silhouette (inscribed in the 12³ square)
    mid := px + size/2
    midy := py + size/2
    rl.DrawCircle(mid, midy, f32(size/2 - 1), rl.Color{22, 26, 40, 230})
    rl.DrawCircleLines(mid, midy, f32(size/2 - 1), rl.Color{90, 120, 200, 140})
    // mid cross for orientation, clipped to the disc
    rl.DrawLine(px + 4, midy, px + size - 4, midy, rl.Color{70, 76, 92, 120})
    rl.DrawLine(mid, py + 4, mid, py + size - 4, rl.Color{70, 76, 92, 120})
    // axis-colored ticks on the circle (bottom = horizontal, left = vertical)
    rl.DrawLineEx({f32(px + 8), f32(py + size - 3)}, {f32(px + size - 8), f32(py + size - 3)}, 2, hcol)
    rl.DrawLineEx({f32(px + 3), f32(py + 8)}, {f32(px + 3), f32(py + size - 8)}, 2, vcol)
    rl.DrawRectangleLinesEx({f32(px), f32(py), f32(size), f32(size)}, 1, rl.Color{80, 88, 110, 120})

    plot :: proc(px, py, size: i32, c: IV3, ha, va: i32, flip_v: bool, col: rl.Color, r: i32) {
        x := mini_px(px, size, coord_of(c, ha))
        v := mini_px(0, size, coord_of(c, va))
        y := flip_v ? py + size - v : py + v
        rl.DrawRectangle(x - r/2, y - r/2, r, r, col)
    }

    // 障碍：暗灰琥珀小点，三个视图都能读出迷宫结构（只画球内）
    if map_has_walls {
        for i in 0..<CELLS {
            c := cell3(i)
            if map_bit(i) && cell_in_world(c) do plot(px, py, size, c, ha, va, flip_v, rl.Color{188, 158, 96, 90}, 2)
        }
    }

    for s in snake do plot(px, py, size, s, ha, va, flip_v, rl.Color{70, 180, 80, 220}, 4)
    // 目标点按模式取：经典 = 豆豆；投喂 = AI 当前目标（无目标不画，不指已离场的系统）
    if t, ok := nav_target(); ok do plot(px, py, size, t, ha, va, flip_v, rl.RED, 6)
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

// HUD 模式行：当前模式 + 驾驶权（F 切模式，B 切驾驶权）
mode_hud_label :: proc() -> cstring {
    if game_mode == .FEEDING do return autopilot ? "投喂·AI" : "投喂·手动"
    return autopilot ? "经典·AI" : "经典·手动"
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
        // 最近一个蛇还愿意吃的投喂食物的距离（豆豆 FOOD 行的投喂版；
        // 烂掉 / 被免疫拒食的不算目标，和"没东西吃"提示同一口径）
        nd: i32 = -1
        for f in foods {
            if f.rot > 0 do continue
            k := &kinds[f.kind]
            if kind_harmful(k) && snake_memory[k.name] >= 2 do continue
            d := abs(f.pos.x - snake[0].x) + abs(f.pos.y - snake[0].y) + abs(f.pos.z - snake[0].z)
            if nd < 0 || d < nd do nd = d
        }
        if nd >= 0 {
            draw_text(fmt.ctprintf("FOODS   %d in the sphere · nearest %d cells", len(foods), nd), 26, 176, 18,
                rl.Color{255, 190, 120, 255})
        } else {
            draw_text(fmt.ctprintf("FOODS   %d in the sphere", len(foods)), 26, 176, 18,
                rl.Color{255, 190, 120, 255})
        }
        draw_text(fmt.ctprintf("模式: %s · 发现 %d 种 · 地图: %s", mode_hud_label(), len(kinds), current_map.name), 26, 204, 19,
            rl.Color{255, 200, 140, 255}, true)
        // 断粮提示：AI 找不到目标且场上真的没有任何愿意吃的食物
        // （ai_has_target 只在移动 tick 更新，willing_food_count 当场重算，
        //   食物只是离得远时不显示）
        if state == .PLAYING && !ai_has_target && willing_food_count() == 0 {
            draw_centered("蛇没东西吃了 — 按 T 投喂，或按 E 创造新食物", SCREEN_H / 3, 20,
                rl.Color{255, 190, 90, 220}, true)
        }
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
        if shield_timer > 0 {
            draw_text(fmt.ctprintf("金身 %.1fs", shield_timer), 26, fy, 17, {255, 210, 70, 255}, true)
            fy += 22
        }
        if score_mult_timer > 0 {
            draw_text(fmt.ctprintf("得分×%.1f %.1fs", score_mult, score_mult_timer), 26, fy, 17, {255, 170, 90, 255}, true)
            fy += 22
        }
        if llm_is_cooking() && llm_word != "" {
            pulse := 0.6 + 0.4 * math.sin(time_total * 6)
            draw_text(fmt.ctprintf("AI 烹饪中: %s...", llm_word), 26, fy, 17,
                {255, u8(180 + 40 * pulse), 110, 255}, true)
        }
        // 作品库快捷投放提示（⇧1-8，新作品优先，名字截断到 6 字）
        {
            sb := strings.builder_make(context.temp_allocator)
            strings.write_string(&sb, "⇧1-8 自创: ")
            n := 0
            for i in 0..<8 {
                idx := creation_at(i)
                if idx < 0 do break
                if i > 0 do strings.write_string(&sb, " ")
                strings.write_string(&sb, utf8_prefix(kinds[idx].name, 6))
                n += 1
            }
            if n == 0 do strings.write_string(&sb, "(按 E 创造)")
            draw_text(fmt.ctprintf("%s", strings.to_string(sb)), 26, SCREEN_H - 58, 14,
                rl.Color{125, 130, 145, 220})
        }
        draw_text("T: 投喂    1-8: 快捷食物    E: 创造台    Tab: 图鉴    C: 复制分享码    F: 模式    B: 手动/AI    V: 视角    M: 皮肤    IJKL: 转视角    P/Space: 暂停    R: 重开",
            26, SCREEN_H - 36, 16, rl.Color{160, 165, 180, 255})
        return
    }

    fd := abs(food.x - snake[0].x) + abs(food.y - snake[0].y) + abs(food.z - snake[0].z)
    draw_text(fmt.ctprintf("FOOD    %d cells away", fd), 26, 176, 18, rl.Color{255, 140, 140, 255})
    draw_text(fmt.ctprintf("模式: %s · 地图: %s", mode_hud_label(), current_map.name), 26, 204, 19,
        rl.Color{150, 168, 192, 255}, true)
    if autopilot {
        pulse := 0.65 + 0.35 * math.sin(time_total * 5)
        draw_text("AUTOPILOT  (B to take over)", 26, 230, 19,
            rl.Color{255, 200, u8(120 + 80 * pulse), 255}, true)
    }

    draw_text("WASD: steer    IJKL or drag: orbit    U/O or wheel: zoom    -/=: speed    V: view    B: autopilot    F: mode    M: skin    P/Space: pause    R: restart",
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
    draw_centered("True 3D - six directions inside a spherical arena, with a panoramic overview",
        SCREEN_H/2 - 64, 23, rl.Color{170, 175, 190, 255})
    draw_centered("A / D: screen-left & right      W / S: screen-up & down (relative to your view)",
        SCREEN_H/2 - 18, 20, rl.Color{190, 195, 210, 255})
    draw_centered("J / L: rotate    I / K: tilt    U / O: zoom (or use the mouse)   V: first-person view.",
        SCREEN_H/2 + 14, 18, rl.Color{150, 155, 170, 255})
    draw_centered("Press B anytime to watch the AI play (BFS pathfinding + survival lookahead).",
        SCREEN_H/2 + 38, 18, rl.Color{255, 200, 140, 255})
    draw_centered("Press M to switch between the modern tube skin and the classic cube skin.",
        SCREEN_H/2 + 62, 18, rl.Color{140, 230, 190, 255})
    draw_centered("Pause anytime with P or SPACE to inspect the sphere. The dotted line shows where",
        SCREEN_H/2 + 86, 18, rl.Color{150, 155, 170, 255})
    draw_centered("flying straight leads. Mini-map and axis compass share the edge colors.",
        SCREEN_H/2 + 110, 18, rl.Color{150, 155, 170, 255})
    draw_centered("SPACE: classic mode", SCREEN_H/2 + 152, 30, rl.RAYWHITE, true)
    draw_centered("F: 投喂实验室 — AI 蛇自动觅食，你来发明食物 (type any word, T to feed)",
        SCREEN_H/2 + 196, 22, rl.Color{255, 200, 140, 255}, true)
    // 地图选择（N 循环）：进入游戏前唯一换图入口，选中后跨重开保持
    map_pulse := 0.7 + 0.3 * math.sin(time_total * 4)
    draw_centered(fmt.ctprintf("地图: %s   (N 切换)", current_map.name), SCREEN_H/2 + 236, 26,
        rl.Color{255, u8(190 + 40 * map_pulse), 110, 255}, true)
    if best > 0 {
        draw_centered(fmt.ctprintf("Best: %d", best), SCREEN_H/2 + 274, 21, rl.GOLD)
    }
    draw_centered("H: 新手教程 · 标题界面 30 秒无操作自动进入演示", SCREEN_H/2 + 306, 16,
        rl.Color{115, 120, 136, 255})
}

draw_game_over :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{20, 0, 0, 150})
    // 战报卡已生成（经典手动 / 投喂阵亡）：卡片式布局
    if report_tex.id != 0 {
        draw_centered("GAME OVER", 40, 60, rl.RED, true)
        scale: f32 = 560.0 / REPORT_W
        w: f32 = 560
        h: f32 = REPORT_H * scale
        rl.DrawTextureEx(report_tex, {f32(SCREEN_W) / 2 - w / 2, 120}, 0, scale, rl.WHITE)
        y := i32(120 + h)
        if score >= best && score > 0 {
            draw_centered("NEW BEST!", y + 20, 26, rl.GOLD, true)
        }
        hint: cstring = "C 复制文字战报"
        if report_file != "" do hint = fmt.ctprintf("战报已保存 %s · C 复制文字战报", report_file)
        draw_centered(hint, y + 56, 22, rl.Color{200, 205, 220, 255})
        draw_centered("Enter 再来一局 · Esc 回标题", y + 94, 24, rl.LIGHTGRAY)
        return
    }
    draw_centered("GAME OVER", SCREEN_H/2 - 120, 76, rl.RED, true)
    draw_centered(fmt.ctprintf("Score: %d", score), SCREEN_H/2 - 28, 34, rl.RAYWHITE)
    if score >= best && score > 0 {
        draw_centered("NEW BEST!", SCREEN_H/2 + 16, 25, rl.GOLD, true)
    } else {
        draw_centered(fmt.ctprintf("Best: %d", best), SCREEN_H/2 + 16, 23, rl.GOLD)
    }
    draw_centered("Enter 再来一局 · Esc 回标题", SCREEN_H/2 + 68, 25, rl.LIGHTGRAY)
}

draw_win :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 20, 0, 150})
    draw_centered("YOU WIN!", SCREEN_H/2 - 120, 76, rl.LIME, true)
    draw_centered(fmt.ctprintf("Final score: %d", score), SCREEN_H/2 - 28, 34, rl.RAYWHITE)
    draw_centered("Enter 再来一局 · Esc 回标题", SCREEN_H/2 + 30, 25, rl.LIGHTGRAY)
}

draw_paused :: proc() {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 0, 0, 110})
    draw_centered("PAUSED", SCREEN_H/2 - 46, 64, rl.RAYWHITE, true)
    draw_centered("拖动旋转视角 · P/Space 继续 · Q 回标题", SCREEN_H/2 + 32, 23, rl.LIGHTGRAY)
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

update_camera :: proc(dt: f32, alpha: f32) {
    // smoothed head position (shared by both camera modes)
    hp := cell_to_world(snake[0])
    if len(prev_snake) > 0 {
        hp = slerp_v3(cell_to_world(prev_snake[0]), hp, alpha)
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

    // orbit pivots on the SPHERE CENTER: dragging rotates the whole sphere
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
    draw_map()
    draw_tether()
    if game_mode == .CLASSIC do draw_food() // 豆豆只在经典绘制
    draw_foods() // 投喂食物两模式都画：F 切回经典后场上剩余的继续可吃，不能隐身
    first_person := view_mode == .FIRST && state != .TITLE
    if modern_skin {
        draw_snake_modern(alpha, first_person)
    } else {
        draw_snake(alpha, first_person)
    }
    draw_path_hint()
    draw_particles()
    draw_sphere_shell()
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
    draw_editor()
    draw_report_overlay()
    draw_toast()
    draw_attract()
    draw_tutorial()
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

// SNAKE_RECORD reel: ~24 s of the attract scenario at ~10 fps → ~240 PNGs
RECORD_SECONDS :: 24.0
RECORD_DT      :: 0.1

// same offscreen technique as capture(), reusing one persistent render target
record_capture :: proc(rt: rl.RenderTexture2D, filename: cstring, alpha: f32) {
    rl.BeginTextureMode(rt)
    draw_frame(alpha)
    rl.EndTextureMode()
    img := rl.LoadImageFromTexture(rt.texture)
    rl.ImageFlipVertical(&img)
    rl.ExportImage(img, filename)
    rl.UnloadImage(img)
}

// ---------------------------------------------------------------------------
// 战报图 (battle report card): 800x450 PNG 战绩卡 + 可复制的文字战报
// 阵亡自动生成一次（经典手动 + 投喂；演示/观赏自动驾驶不刷文件）；
// 投喂模式游戏中随时按 G 生成并复制文字版，浮层展示至任意键。
// ---------------------------------------------------------------------------

REPORT_W :: 800
REPORT_H :: 450

RANK_GRAY   :: rl.Color{158, 164, 180, 255}
RANK_GREEN  :: rl.Color{105, 220, 140, 255}
RANK_BLUE   :: rl.Color{110, 170, 245, 255}
RANK_PURPLE :: rl.Color{185, 125, 245, 255}
RANK_GOLD   :: rl.Color{245, 205,  80, 255}

// 段位（纯函数，可测）：经典按得分，投喂按吃掉个数
rank_classic :: proc(sc: int) -> (string, rl.Color) {
    switch {
    case sc <  50: return "蛇界萌新",   RANK_GRAY
    case sc < 150: return "初出茅庐",   RANK_GREEN
    case sc < 300: return "老练机长",   RANK_BLUE
    case sc < 500: return "球形传说", RANK_PURPLE
    }
    return "三维之神", RANK_GOLD
}

rank_feeding :: proc(n: int) -> (string, rl.Color) {
    switch {
    case n < 10: return "新手饲养员",   RANK_GRAY
    case n < 25: return "资深饲养员",   RANK_GREEN
    case n < 50: return "黑暗料理大师", RANK_PURPLE
    }
    return "食神下凡", RANK_GOLD
}

rank_title :: proc() -> (string, rl.Color) {
    if game_mode == .FEEDING do return rank_feeding(eaten)
    return rank_classic(score)
}

// 经典模式晋级提示：下一个段位名 + 还差多少分
next_rank_classic :: proc(sc: int) -> (name: string, need: int, at_max: bool) {
    switch {
    case sc <  50: return "初出茅庐",    50 - sc, false
    case sc < 150: return "老练机长",   150 - sc, false
    case sc < 300: return "球形传说", 300 - sc, false
    case sc < 500: return "三维之神",   500 - sc, false
    }
    return "", 0, true
}

ReportEntry :: struct { name: string, count: int, color: rl.Color }

// 奇葩菜单：按吃掉次数降序（同次数按名字字典序，保证确定性），最多 8 条
menu_entries :: proc(allocator := context.temp_allocator) -> []ReportEntry {
    entries := make([dynamic]ReportEntry, allocator)
    for name, count in session_eaten {
        col := RANK_GRAY
        if idx, ok := kind_by_name[name]; ok do col = kinds[idx].color
        append(&entries, ReportEntry{name, count, col})
    }
    // 小数组插入排序：次数降序，名字升序
    for i in 1..<len(entries) {
        for j := i; j > 0; j -= 1 {
            a, b := entries[j - 1], entries[j]
            before := a.count > b.count || (a.count == b.count && a.name < b.name)
            if before do break
            entries[j - 1], entries[j] = b, a
        }
    }
    return entries[:min(8, len(entries))]
}

// 文字战报（纯函数，可测）：投喂模式带奇葩菜单行（<=8 条），经典模式不带
report_text :: proc(allocator := context.temp_allocator) -> string {
    sb := strings.builder_make(allocator)
    title, _ := rank_title()
    strings.write_string(&sb, "🐍 Shinake 战报\n")
    if game_mode == .FEEDING {
        self_made := 0
        for name, _ in session_eaten {
            if idx, ok := kind_by_name[name]; ok && kinds[idx].author == "自创" do self_made += 1
        }
        fmt.sbprintf(&sb, "投喂实验室 · 得分 %d · 投喂 %d 个 · 发现 %d 种 · 自创 %d 道\n",
            score, eaten, len(kinds), self_made)
        entries := menu_entries()
        if len(entries) > 0 {
            strings.write_string(&sb, "奇葩菜单：")
            for e, i in entries {
                if i > 0 do strings.write_string(&sb, " ")
                fmt.sbprintf(&sb, "%s×%d", e.name, e.count)
            }
            strings.write_string(&sb, "\n")
        }
    } else {
        secs := int(play_clock)
        fmt.sbprintf(&sb, "经典模式 · 得分 %d · 最高 %d · 长度 %d · 吃掉 %d 个 · 时长 %d:%02d\n",
            score, best, len(snake), eaten, secs / 60, secs % 60)
    }
    fmt.sbprintf(&sb, "段位：%s\n", title)
    strings.write_string(&sb, "AI 开蛇，你造食物 → github.com/vajraimb/Shinake")
    return strings.to_string(sb)
}

// 战绩卡本体（画进 800x450 渲染目标；布局按带区分：头/数据/菜单/徽章/页脚）
draw_report_card :: proc() {
    W :: REPORT_W
    H :: REPORT_H
    INK   :: rl.Color{232, 236, 248, 255}
    DIM   :: rl.Color{146, 152, 176, 255}
    FAINT :: rl.Color{62, 68, 96, 255}
    GOLD  :: rl.Color{250, 214, 92, 255}
    title, tcol := rank_title()

    rl.DrawRectangleGradientV(0, 0, W, H, rl.Color{26, 30, 48, 255}, rl.Color{12, 14, 24, 255})
    rl.DrawRectangle(0, 0, W, 5, tcol)

    // 头部：SHINAKE 战报 + 模式标签
    x: i32 = 40
    draw_text("SHINAKE", x, 26, 40, rl.Color{125, 232, 150, 255}, true)
    x += measure_text("SHINAKE", 40, true) + 12
    draw_text("战报", x, 26, 40, INK)
    mode_label: cstring = game_mode == .FEEDING ? "投喂实验室" : "经典模式"
    draw_text(mode_label, W - 40 - measure_text(mode_label, 20), 36, 20, DIM)
    rl.DrawRectangle(40, 78, W - 80, 2, FAINT)

    // 大得分（左）+ 数据格（右，2×2）
    draw_text("得分", 40, 92, 17, DIM)
    draw_text(fmt.ctprintf("%d", score), 38, 108, 84, GOLD, true)
    secs := int(play_clock)
    stats := [?]struct{l: cstring, v: string}{
        {"最高分", fmt.tprintf("%d", best)},
        {"长度",   fmt.tprintf("%d 节", len(snake))},
        {"吃掉",   fmt.tprintf("%d 个", eaten)},
        {"时长",   fmt.tprintf("%d:%02d", secs / 60, secs % 60)},
    }
    for s, i in stats {
        cx: i32 = 340 + i32(i % 2) * 220
        cy: i32 = 92 + i32(i / 2) * 58
        draw_text(s.l, cx, cy, 16, DIM)
        draw_text(fmt.ctprintf("%s", s.v), cx, cy + 20, 28, INK, true)
    }

    // 中段：投喂模式列奇葩菜单（2 列 × 4 行）；经典模式给晋级提示
    y0: i32 = 210
    if game_mode == .FEEDING {
        draw_text("奇葩菜单", 40, y0, 20, INK, true)
        rl.DrawRectangle(40, y0 + 26, 84, 3, tcol)
        entries := menu_entries()
        if len(entries) == 0 {
            draw_text("这局还什么都没吃到", 40, y0 + 40, 17, DIM)
        }
        for e, i in entries {
            ex: i32 = 40 + i32(i % 2) * 310
            ey: i32 = y0 + 34 + i32(i / 2) * 27
            rl.DrawCircle(ex + 8, ey + 10, 7, e.color)
            draw_text(fmt.ctprintf("%s ×%d", e.name, e.count), ex + 24, ey, 19, INK)
        }
    } else {
        name, need, maxed := next_rank_classic(score)
        hint := maxed ? fmt.tprintf("已是最高段位 · %s", title) :
            fmt.tprintf("再得 %d 分晋级「%s」", need, name)
        hc := fmt.ctprintf("%s", hint)
        draw_text(hc, (W - measure_text(hc, 19)) / 2, y0 + 56, 19, DIM)
    }

    // 段位徽章：段位色圆角胶囊 + 深色标题字
    draw_text("段位", 40, 356, 15, DIM)
    bw := measure_text(fmt.ctprintf("%s", title), 20) + 44
    rl.DrawRectangleRounded({40, 372, f32(bw), 30}, 0.5, 10, tcol)
    draw_text(fmt.ctprintf("%s", title), 40 + 22, 377, 20, rl.Color{16, 18, 28, 255}, true)

    // 页脚：日期 + 仓库地址
    now := time.now()
    yy, mo, dd := time.date(now)
    draw_text(fmt.ctprintf("%04d-%02d-%02d", yy, int(mo), dd), 40, 416, 15, DIM)
    REPO :: "github.com/vajraimb/Shinake"
    draw_text(REPO, W - 40 - measure_text(REPO, 15), 416, 15, DIM)

    rl.DrawRectangleRoundedLinesEx({1, 1, W - 2, H - 2}, 0.05, 8, 2, FAINT)
}

// 渲染战绩卡并导出 PNG（Y 翻转与 capture() 同理）；成功时保留一份上屏纹理
render_report_card :: proc(filename: cstring) -> bool {
    if !fonts_ok do return false
    rt := rl.LoadRenderTexture(REPORT_W, REPORT_H)
    rl.BeginTextureMode(rt)
    rl.ClearBackground(rl.Color{12, 14, 24, 255})
    draw_report_card()
    rl.EndTextureMode()
    img := rl.LoadImageFromTexture(rt.texture)
    rl.ImageFlipVertical(&img)
    ok := rl.ExportImage(img, filename)
    if report_tex.id != 0 do rl.UnloadTexture(report_tex)
    report_tex = ok ? rl.LoadTextureFromImage(img) : rl.Texture2D{}
    rl.UnloadImage(img)
    rl.UnloadRenderTexture(rt)
    return ok
}

// 生成战绩卡：时间戳文件名（与 best.txt 同目录），返回 "" 表示失败
report_generate :: proc() -> string {
    now := time.now()
    yy, mo, dd := time.date(now)
    hh, mm, ss := time.clock(now)
    name := fmt.tprintf("report_%04d%02d%02d_%02d%02d%02d.png", yy, int(mo), dd, hh, mm, ss)
    report_ready = true // 失败也不再每帧重试
    if render_report_card(fmt.ctprintf("%s", name)) {
        if report_file != "" do delete(report_file)
        report_file = strings.clone(name)
        return report_file
    }
    return ""
}

report_copy_text :: proc(with_toast := true) {
    rl.SetClipboardText(fmt.ctprintf("%s", report_text()))
    if with_toast do set_toast("文字战报已复制 · 快去炫耀吧")
}

report_clear :: proc() {
    if report_tex.id != 0 { rl.UnloadTexture(report_tex); report_tex = {} }
    if report_file != "" { delete(report_file); report_file = "" }
    report_ready = false
    report_open = false
}

// 投喂模式 G 浮层：压暗背景 + 居中展示战绩卡至任意键
draw_report_overlay :: proc() {
    if !report_open || report_tex.id == 0 || state != .PLAYING do return
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 0, 0, 170})
    scale: f32 = 640.0 / REPORT_W
    w: f32 = 640
    h: f32 = REPORT_H * scale
    x := f32(SCREEN_W) / 2 - w / 2
    y := f32(SCREEN_H) / 2 - h / 2 - 20
    rl.DrawTextureEx(report_tex, {x, y}, 0, scale, rl.WHITE)
    draw_centered("按任意键关闭 · 战报已保存并复制", i32(y + h) + 24, 22, rl.LIGHTGRAY)
}

// SNAKE_REPORT=1：伪造一局投喂session，渲染样张战报并自检（隐藏窗口里跑，
// 字体已经就绪）。同时校验经典模式的文字战报 + 段位判定。
report_sample_test :: proc() -> bool {
    game_mode = .FEEDING
    reset_game()
    score = 320
    best = 670
    eaten = 28
    play_clock = 754
    for len(snake) < 9 do append(&snake, snake[len(snake) - 1]) // 长度 9
    // 7 个预设 + 5 个伪造 = 12 种；其中 3 道自创
    Seed :: struct { name: string, n: int, author: string, hue: f32 }
    seeds := [?]Seed{
        {"榴莲",     3, "AI",    45},
        {"火箭辣椒", 2, "自创",  10},
        {"神秘蛋",   1, "AI",   280},
        {"彩虹糖",   4, "自创", 200},
        {"虚空布丁", 1, "自创", 320},
    }
    for s in seeds {
        idx := kind_index(s.name)
        kinds[idx].author = s.author
        kinds[idx].hue = int(s.hue)
        kinds[idx].color = hsv_rgb(s.hue, 0.72, 1.0)
        session_eaten[kinds[idx].name] = s.n
    }
    fmt.println("--- report_text (feeding) ---")
    fmt.println(report_text())

    ok := render_report_card("report_sample.png")
    if !ok {
        fmt.println("REPORT FAIL: render_report_card export failed")
        return false
    }
    fi, err := os.stat("report_sample.png", context.temp_allocator)
    if err != nil || fi.size <= 20 * 1024 {
        fmt.println("REPORT FAIL: report_sample.png missing or too small:", fi.size, err)
        return false
    }
    fmt.printf("report_sample.png: %d bytes\n", fi.size)

    // 经典变体：score 40 → 蛇界萌新，无菜单行
    game_mode = .CLASSIC
    score = 40
    title, _ := rank_title()
    fmt.println("--- report_text (classic) ---")
    fmt.println(report_text())
    if title != "蛇界萌新" {
        fmt.println("REPORT FAIL: classic rank for score 40:", title)
        return false
    }
    fmt.println("REPORT: PASS")
    return true
}


// SNAKE_SHOT only: a canned blueprint kind so the dex capture shows the
// [蓝图] tag (the 火箭辣椒 creative-prompt example design)
shot_inject_blueprint_kind :: proc() -> int {
    bp := `{"do":[{"speed":{"mult":0.5,"secs":4}},{"delay":{"secs":4}},{"growth":{"n":-2}},{"shake":{"s":0.6}},{"burst":{"n":3}}]}`
    k := FoodKind{
        name = strings.clone("火箭辣椒"), author = "自创",
        flavor = strings.clone("先上天，再坠毁"),
        hue = 10, color = hsv_rgb(10, 0.72, 1.0), shape = .CONE,
        size = 0.30, spin = 2.0, rarity = 2,
        fx_growth = 1, fx_score = 10, fx_bursts = 2,
        blueprint = strings.clone(bp), byline = strings.clone("截图演示"),
    }
    append(&kinds, k)
    idx := len(kinds) - 1
    kind_by_name[k.name] = idx
    return idx
}

// SNAKE_SHOT only: stuff the same canned design into the editor's scratch
// state so the blueprint-mode panel (summary lines) can be captured
shot_inject_editor_blueprint :: proc() {
    delete(edit_kind.name)
    edit_kind.name = strings.clone("火箭辣椒")
    if edit_kind.flavor != "" do delete(edit_kind.flavor)
    edit_kind.flavor = strings.clone("先上天，再坠毁")
    edit_kind.hue = 10
    edit_kind.color = hsv_rgb(10, 0.72, 1.0)
    edit_kind.shape = .CONE
    edit_kind.rarity = 2
    if edit_blueprint != "" do delete(edit_blueprint)
    edit_blueprint = strings.clone(`{"do":[{"speed":{"mult":0.5,"secs":4}},{"delay":{"secs":4}},{"growth":{"n":-2}},{"shake":{"s":0.6}},{"burst":{"n":3}}]}`)
    edit_has_blueprint = true
    editor_sel = 4 // 清除蓝图 row, for the highlight
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
    init_primitives() // effect-blueprint registry (needed by self-test too)
    // headless self-test: SNAKE_SELFTEST=1 ./snake3d
    if os.get_env("SNAKE_SELFTEST", context.allocator) == "1" {
        os.exit(self_test() ? 0 : 1)
    }
    if os.get_env("SNAKE_LLMTEST", context.allocator) == "1" {
        os.exit(llm_test() ? 0 : 1)
    }

    llm_init_config() // FEED_LLM_API_KEY / FEED_LLM_BASE_URL / FEED_LLM_MODEL

    // DEBUG: offscreen-render verification mode (SNAKE_SHOT=1) — runs with a
    // hidden window and quits by itself once all captures are taken.
    // SNAKE_RECORD=<outdir> is the demo-reel variant: it runs the attract
    // scenario for RECORD_SECONDS of game time and dumps ~10 fps PNG frames
    // into <outdir>/frames/ (see make_demo.py for the WebP assembly).
    // SNAKE_REPORT=1 is the battle-report variant: fabricates a feeding
    // session, renders report_sample.png and prints the text report.
    shot_mode := os.get_env("SNAKE_SHOT", context.allocator) == "1"
    record_dir := os.get_env("SNAKE_RECORD", context.allocator)
    record_mode := record_dir != ""
    report_mode := os.get_env("SNAKE_REPORT", context.allocator) == "1"
    if shot_mode || record_mode || report_mode {
        rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_HIDDEN})
    } else {
        rl.SetConfigFlags({.MSAA_4X_HINT})
    }
    rl.InitWindow(SCREEN_W, SCREEN_H, "Shinake — true 3D snake (Odin + raylib)")
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
    load_macros() // 自创新原语（macros.json）
    creator_byline = os.get_env("SNAKE_CREATOR", context.allocator)
    load_creator() // creator.txt（env SNAKE_CREATOR 优先）
    make_presets()
    load_creations() // 作品库（creations.json）— 预设之后注册，不投放不碰 last_cast
    map_apply(map_id)  // 默认虚空；填充 current_map.name 等
    reset_game()

    // SNAKE_REPORT=1: fonts + presets are ready here — fabricate, render, exit
    if report_mode {
        os.exit(report_sample_test() ? 0 : 1)
    }

    shots := 0
    shot_bp_idx := -1 // blueprint kind index injected for the dex capture

    // SNAKE_RECORD: persistent render target + the attract scenario as the reel
    record_rt: rl.RenderTexture2D
    record_t: f32 = 0
    record_frame := 0
    if record_mode {
        _ = os.make_directory_all(fmt.tprintf("%s/frames", record_dir))
        record_rt = rl.LoadRenderTexture(SCREEN_W, SCREEN_H)
        attract_begin()
    }

    for !rl.WindowShouldClose() {
        dt := min(rl.GetFrameTime(), 0.05)
        time_total += dt
        toast_t = max(0, toast_t - dt)
        llm_poll()
        if death_squawk { // die() stays raylib-free; the sound plays here
            death_squawk = false
            play(snd_die)
        }

        // sampled once per frame: attract exit + idle clock + tutorial "any key"
        any_key := rl.GetKeyPressed() != .KEY_NULL
        mouse_input := rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) ||
            rl.IsMouseButtonPressed(.MIDDLE) || rl.GetMouseWheelMove() != 0

        alpha := clamp(move_timer / move_interval, 0, 1)

        // 演示模式：任何输入退回标题界面（这个按键本身被吞掉，不再触发标题操作）
        attract_swallowed := false
        if attract_active && (any_key || mouse_input) {
            attract_exit()
            attract_swallowed = true
        }

        switch state {
        case .TITLE:
            if !attract_swallowed {
                if !shot_mode && attract_idle_tick(dt, any_key || mouse_input) {
                    attract_begin()
                    break
                }
                // H: 教程（投喂章 / 经典章，按当前模式）
                if rl.IsKeyPressed(.H) {
                    autopilot = false
                    reset_game()
                    state = .PLAYING
                    tutorial_start(game_mode == .FEEDING ? .FEED : .CLASSIC)
                    break
                }
                // N: 切换障碍地图（虚空→石柱林→十字回廊→蜂巢→随机洞穴→…）
                if rl.IsKeyPressed(.N) {
                    map_cycle()
                }
                if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) {
                    game_mode = .CLASSIC
                    autopilot = false
                    reset_game()
                    state = .PLAYING
                    if !tutorial_seen() do tutorial_start(.CLASSIC) // 首次启动自动开课
                }
                if rl.IsKeyPressed(.F) {
                    game_mode = .FEEDING
                    reset_game()
                    state = .PLAYING
                    if !tutorial_seen() do tutorial_start(.FEED) // 首次启动自动开课
                }
            }
        case .PLAYING:
            if attract_active do attract_update(dt)
            // 战报浮层：任意键关闭，本帧其余输入全部吞掉（模拟照常运行）
            report_was_open := report_open
            if report_open {
                if any_key || mouse_input do report_open = false
            }
            // Esc 先让面板（投喂框/创造台/文本编辑）消费；没人消费才轮到教程跳过
            tut_esc := false
            if !report_open {
                tut_esc = rl.IsKeyPressed(.ESCAPE) && !input_open && !editor_open && edit_target == .NONE
                handle_text_input()
                if editor_open {
                    editor_handle_input(dt) // 创造台接管键盘；游戏照常运行
                } else {
                    handle_input()
                }
                // H: 随时重开教程（游戏不重置，从第 1 步重来）
                if rl.IsKeyPressed(.H) && !input_open && edit_target == .NONE {
                    tutorial_start(game_mode == .FEEDING ? .FEED : .CLASSIC)
                }
                if !input_open && !editor_open {
                    if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) { state = .PAUSED; break }
                    if rl.IsKeyPressed(.R) { reset_game(); break }
                }

                // manual speed control (auto-acceleration on food still applies)
                if game_mode == .CLASSIC {
                    if rl.IsKeyPressed(.MINUS) do move_interval = min(0.50, move_interval + 0.02)
                    if rl.IsKeyPressed(.EQUAL) do move_interval = max(MIN_INTERVAL, move_interval - 0.02)
                }
            }

            // the snake holds still until the player steers for the first time
            if !started && (len(dir_queue) > 0 || autopilot) do started = true

            play_clock += dt
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
            shield_timer   = max(0, shield_timer - dt)
            if score_mult_timer > 0 {
                score_mult_timer = max(0, score_mult_timer - dt)
                if score_mult_timer == 0 do score_mult = 1
            }
            run_scheduled() // due blueprint actions
            if game_mode == .FEEDING do update_food_rot(dt)
            alpha = clamp(smoothstep(move_timer / move_interval), 0, 1)
            update_particles(dt)
            tutorial_step_logic(any_key && !report_was_open, tut_esc) // 教练模式：观察状态变化推进步骤
        case .PAUSED:
            if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) do state = .PLAYING
            if rl.IsKeyPressed(.R) { reset_game(); state = .PLAYING }
            // Q: 回标题（保留地图与 game_mode 选择）
            if rl.IsKeyPressed(.Q) { back_to_title() }
            // allow inspecting from the other view while paused
            if rl.IsKeyPressed(.V) do toggle_view()
            if rl.IsKeyPressed(.M) do modern_skin = !modern_skin
        case .GAME_OVER, .WIN:
            // 阵亡自动生成战报卡一次：经典手动 + 投喂（非演示）都出卡
            if state == .GAME_OVER && gameover_wants_report() && !report_ready {
                report_generate()
            }
            // C: 复制文字战报（两种模式都行；结算屏常驻，随时可按）
            if state == .GAME_OVER && !editor_open && rl.IsKeyPressed(.C) {
                report_copy_text()
            }
            // 创造台打开时 Enter/R 属于编辑器
            if !editor_open && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.R)) {
                reset_game()
                state = .PLAYING
            }
            // Esc: 回标题（保留地图与 game_mode 选择）
            if !editor_open && !input_open && edit_target == .NONE && rl.IsKeyPressed(.ESCAPE) {
                back_to_title()
            }
            // attract 演示 / 经典观赏自动驾驶：死亡后自动重开，继续演出
            if state == .GAME_OVER && gameover_auto_restart() {
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

        // SNAKE_RECORD: a frame every 100 ms of game time for ~24 s, then exit 0
        if record_mode {
            record_t += dt
            for f32(record_frame) * RECORD_DT <= record_t + 0.0001 &&
                f32(record_frame) * RECORD_DT <= RECORD_SECONDS + 0.0001 {
                record_capture(record_rt,
                    fmt.ctprintf("%s/frames/f%04d.png", record_dir, record_frame + 1), alpha)
                record_frame += 1
            }
            if record_t >= RECORD_SECONDS + RECORD_DT do break
        }

        // DEBUG: offscreen captures (reliable even when the window is occluded)
        if shot_mode {
            // 剧本投喂段：阵亡立即重开保持演示连续性（产生的战报文件删掉，不留残留）
            if shots >= 1 && shots <= 5 && state == .GAME_OVER {
                if report_file != "" do os.remove(report_file)
                reset_game()
                state = .PLAYING
            }
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
                // 蓝图食物：让图鉴出现 [蓝图] 标签（仅截图演示用）
                shot_bp_idx = shot_inject_blueprint_kind()
                spawn_kind(shot_bp_idx)
            } else if shots == 1 && time_total > 2.5 {
                capture("shot_feed.png", alpha)
                shots = 2
                dex_open = true // 图鉴展示（高亮 [蓝图] 行）
                dex_sel = min(shot_bp_idx, dex_visible_rows() - 1)
            } else if shots == 2 && time_total > 3.5 {
                capture("shot_dex.png", alpha)
                shots = 3
                dex_open = false
            } else if shots == 3 && time_total > 14.0 {
                capture("shot_late.png", alpha)
                shots = 4
            } else if shots == 4 && time_total > 15.0 {
                editor_open_blank() // 创造台：空白模板 + 实时预览
                capture("shot_editor.png", alpha)
                shots = 5
            } else if shots == 5 && time_total > 15.8 {
                shot_inject_editor_blueprint() // 创造台：蓝图模式（示例设计）
                capture("shot_editor_blueprint.png", alpha)
                shots = 6
            } else if shots == 6 {
                // 障碍地图展示图（README docs/map.png）：蜂巢 + 经典模式
                // 自动驾驶，给蛇 ~2.5 s 飞进迷宫深处再截
                editor_close()
                map_apply(.HIVE)
                game_mode = .CLASSIC
                reset_game()
                autopilot = true
                state = .PLAYING
                shots = 7
            } else if shots == 7 && time_total > 18.3 {
                capture("shot_map.png", alpha)
                shots = 8
            } else if shots == 8 {
                // 经典模式死亡现场：结算屏 + 战报卡（README/验收截图）
                game_mode = .CLASSIC
                autopilot = false
                reset_game()
                state = .PLAYING
                // 填些好看的数据，让战报卡有内容
                score = 120
                eaten = 12
                play_clock = 95
                for len(snake) < 12 {
                    tail := snake[len(snake) - 1]
                    append(&snake, tail)
                    append(&prev_snake, tail)
                }
                state = .GAME_OVER
                report_generate()
                shots = 9
            } else if shots == 9 && time_total > 18.8 {
                capture("shot_gameover.png", alpha)
                if report_file != "" do os.remove(report_file) // 截图用的战报文件不留残留
                shots = 10
            } else if shots == 10 {
                break // 截图完成，自动退出
            }
        }

        rl.EndDrawing()
    }

    if fonts_ok {
        rl.UnloadFont(font_ui)
        rl.UnloadFont(font_bold)
        if cjk_ok do rl.UnloadFont(font_cjk)
    }
    if record_mode do rl.UnloadRenderTexture(record_rt)
    if audio_ok {
        rl.UnloadSound(snd_eat)
        rl.UnloadSound(snd_die)
        rl.UnloadSound(snd_win)
        rl.CloseAudioDevice()
    }
    rl.CloseWindow()
}
