# Reverse Engineering Notes

Two separate RE tasks live in this file:

1. **Aim-function hook** (lower section). Found; offset `0x28D4B8`. Catches *projectile* spawn. Doesn't cover hitscan weapons (pistols, SMGs).

2. **View-matrix hook** (next section). UNFOUND. This is the one that fully decouples `MOUSE FORWARD` from `CAMERA FORWARD` — once it's wired, hitscan bullets automatically go where the crosshair is because game logic reads a clean `cam.transform` and only the render pipeline sees head rotation.

---

## View-matrix hook (hitscan aim decoupling)

### Goal

Find a function in `Cyberpunk2077.exe` that is called every rendered frame, takes a camera object, and writes a 4x4 view (or world-to-view) matrix to an output buffer. Hooking it lets us inject head rotation into the rendered view *without* modifying `cam.localOrientation`, so every game system that reads camera orientation (hitscan raycasts, projectile spawn, interaction probes, AI vision) keeps seeing the clean body-yaw+mouse-pitch pose.

When this hook is live:
- Bullets fire where the crosshair is (MOUSE FORWARD), not where the head is looking.
- The CET Lua `camera.lua` stops calling `SetLocalOrientation` (it polls the `camera_hook_active` flag in shared memory and stands down).
- Head rotation becomes purely cosmetic to the game; only the rendered image changes.

### Where to plug in

`native/src/CameraHook.cpp` has the scaffolding:
- `kViewMatrixOffset` — fill in the function offset from `Cyberpunk2077.exe`.
- `kViewMatrixPattern` / `kViewMatrixPatternLen` — optional pattern for version resilience.
- `ViewMatrixFn` typedef — adjust if the real signature has extra args.
- `ApplyHeadRotationToMatrix` — row-major 4x4 assumed; swap indices if heartbeat log shows wrong axis.

The scaffold already attaches via the RED4ext SDK, reads the head quaternion out of shared state, and writes a heartbeat to `bin/x64/HeadTracking.log` (rotated per launch) when the picture changes, and at least every 5 minutes. Kill-switch semantics: if offset stays `0`, the hook refuses to attach, `camera_hook_active` stays `false`, and Lua falls back to `SetLocalOrientation`, i.e. regressions are safe.

### Discovery workflow

1. **Shortlist candidates.** Use the RTTI walkers already in `tools/`:
   - `tools/find_camera_system.py` — dumps RTTI for camera-ish classes.
   - `tools/find_aim_getter.py` / `find_aim_target.py` — adjacent helpers useful for locating the camera component.
   Look for classes with names like `CRenderCamera`, `entCameraComponent`, `ScnCamera`, `CCameraDirector`. Dump their first ~10 vfuncs.
2. **Heartbeat each candidate.** Hook a candidate vfunc with a logging trampoline; confirm it's called per-frame (not per-input-event or on-demand).
3. **Inspect the output.** For each per-frame candidate, dump 16 floats at any pointer argument. The right target writes an orthonormal 3x3 rotation in the top-left and a translation in the 4th column/row — i.e. a view matrix.
4. **Confirm game-logic cleanliness.** With the hook attached but *not yet modifying anything*, verify `cam.localOrientation` remains clean when head moves (compare against the UDP raw yaw/pitch). If game logic still reads head-rotated state, the hook is on the wrong path — try the next candidate.
5. **Validate matrix layout.** Row-major vs column-major: enable the hook, look at a wall, turn head left. If the rendered view rotates left → row-major path is right. If it rotates sideways or up/down → swap row/col indexing in `ApplyHeadRotationToMatrix`.

### Pitfalls to dodge

- Hooking the *camera update* function (writes `cam.transform`) instead of the *view matrix build* function. Update writes would still couple aim. We want the function that produces the matrix the renderer uses — strictly after game logic has read the camera.
- Signature wrong: scaffold assumes `void Fn(void* cam, void* outMat)`. If the real function returns the matrix or takes more args, the hook detour will corrupt the stack. Validate with Cheat Engine / x64dbg first; keep a detach path handy.
- Matrix written into a game-owned constant buffer vs a scratch buffer: our write might be clobbered by a later copy. If heartbeat shows correct injection but render doesn't change, look for the function that copies into the D3D constant buffer and hook *that* instead (or additionally).

### Checklist when the hook lands

- `bin/x64/HeadTracking.log` shows `view-matrix hook attached at 0x...`
- Heartbeat log lines appear every ~3s with `fires > 0` and `inject=yes` during gameplay.
- CET console shows `[HeadTracking:AIM] native camera hook active` (Lua detected the flag).
- With head turned, bullet impact is on the *in-game crosshair* (the offset reticle drawn by `modules/crosshair.lua`), not the centre of the screen.
- `cam.localOrientation` is no longer being written by Lua (the `undo+re-apply` branch is skipped; the "native handoff" branch peeled off any prior head rotation the first time it fired).

### Adjacent RE tasks needed AFTER the view-matrix hook lands

Even with correct aim decoupling, the reticle projection math needs the
LIVE FOV to be accurate - `crosshair_pixels_per_degree` is a stale
calibration constant the moment the player ADSes, uses a scope, or the
game plays a cutscene at a different FOV.

**FOV (and aspect ratio) discovery.** Same memory-scan + HW-watchpoint
workflow as the view matrix, but looking for the *projection* matrix:

- Row-major proj matrix layout for perspective rendering:

  ```
  [ 1/(aspect*tan(fy/2))  0                 0                              0 ]
  [ 0                     1/tan(fy/2)       0                              0 ]
  [ 0                     0                 -(far+near)/(far-near)         -2*far*near/(far-near) ]
  [ 0                     0                 -1                             0 ]
  ```

  Very distinctive signature: most cells are zero, `m22 ≈ -1`, `m32 = -1`,
  non-zero `m00`/`m11` in the [0.5, 2.0] range.

- Workflow:
  1. Widen `tools/find_view_matrix_in_memory.py`'s `matrixScore` heuristic
     to also accept proj-matrix-shaped data (or write a companion scanner).
  2. HW-watchpoint writers on the top proj-matrix candidates -> function
     offset goes into a new `kProjMatrixOffset` in CameraHook.cpp.
  3. In the proj-hook, extract FOV and aspect from the matrix cells we
     just passed through, and publish them into shared state so
     `modules/crosshair.lua` can compute the correct screen offset each
     frame instead of relying on a static calibration.

Fields to add to `HeadTrackingState`:

- `float live_fov_vertical;`  // radians, current effective FOV
- `float live_aspect;`         // width / height

**Camera world position** (lower priority, useful as a disambiguation
signal during matrix hunts). If the view-matrix scan ever yields multiple
plausible live candidates, the one whose translation column matches
`player:GetWorldPosition()` is the real one.

Parking these here so they don't get forgotten once the view-matrix work
lands - same tool chain, same technique, just different target
signatures.

---

## Aim-function hook (projectile path, already found)

## Goal
Find the native function that determines bullet/projectile direction so we can hook it and rotate the aim vector.

## What We Know
- `TargetingSystem` script functions (GetCrosshairData, etc.) are NOT called during shooting
- The bullet trajectory is determined at a deeper native level
- We need to hook a function that:
  1. Is called when weapon fires
  2. Has access to aim direction (Vector4)
  3. Runs BEFORE the projectile spawns

## Tools Required

1. **Cheat Engine** (beginner-friendly): https://www.cheatengine.org
2. **x64dbg** (more advanced): https://x64dbg.com

## Method 1: Cheat Engine Memory Scanning (RECOMMENDED for beginners)

This is the easiest approach - find the aim direction in memory and trace what writes to it.

### Step 1: Setup
1. Start Cyberpunk 2077, load a save where you have a gun
2. Open Cheat Engine, click the PC icon → select `Cyberpunk2077.exe`

### Step 2: Find Aim Direction in Memory
1. In game, aim at a wall/object - keep crosshair perfectly still
2. In CE: Click "New Scan"
   - Value Type: **Float**
   - Scan Type: **Unknown initial value**
   - Click "First Scan"
3. In game, turn camera slightly **left or right**
4. In CE: Scan Type: **Changed value** → Click "Next Scan"
5. In game, turn camera back to original position
6. In CE: Scan Type: **Changed value** → Click "Next Scan"
7. Repeat steps 3-6 until you have ~10-50 addresses

### Step 3: Identify the Direction Vector
Look for 3 consecutive addresses with values like:
- When looking **forward (north)**: Y ≈ 1.0, X ≈ 0, Z ≈ 0
- When looking **left (west)**: X ≈ -1.0, Y ≈ 0, Z ≈ 0
- When looking **up**: Z increases, Y decreases
- All components should be between -1.0 and 1.0 (normalized)

Add promising addresses to your list (double-click them).

### Step 4: Find What Writes to the Direction
1. Right-click an address in your list
2. Select "Find out what writes to this address"
3. A new window opens - in game, **fire your weapon**
4. CE shows the instruction that wrote the value!
5. Note the address: e.g., `Cyberpunk2077.exe+23ABCDE`

### Step 5: Extract the Offset
The offset is the part after `+`:
- If address is `Cyberpunk2077.exe+23ABCDE`, offset is `0x23ABCDE`

You'll need to trace back to find the START of the function (not just this one instruction). Use x64dbg for this, or note the instruction address and search for its containing function.

## Method 2: x64dbg String Search

### Step 1: Attach to Game
1. Start Cyberpunk 2077
2. Open x64dbg
3. File → Attach → select `Cyberpunk2077.exe`

### Step 2: Search for Strings
1. Right-click in the CPU window
2. Search for → Current Module → String references
3. Search for these terms (one at a time):
   - `projectile`
   - `Projectile`
   - `raycast`
   - `RayCast`
   - `shootDirection`
   - `muzzle`
   - `bullet`
   - `Bullet`

### Step 3: Set Breakpoints
1. Double-click a promising string reference
2. This takes you to the code using that string
3. Press F2 to set a breakpoint at the function start
4. Resume the game (F9)
5. **Fire your weapon** in game
6. If breakpoint hits, you're in a weapon-related function!

### Step 4: Walk Call Stack
1. When breakpoint hits, press `Alt+K` to open Call Stack
2. Look UP the stack - the aim direction likely originates higher up
3. Double-click each caller to examine it
4. Look for functions that:
   - Have Vector4* parameters
   - Read from camera or weapon object
   - Write to a direction variable

### Step 5: Note the Offset
1. Once you find the target function, note its address
2. In x64dbg: View → Modules → double-click Cyberpunk2077.exe
3. The base address is shown (usually `0x140000000`)
4. Offset = function_address - base_address

## Expected Function Signatures

Based on similar game engines, likely patterns:

```cpp
// Option A: Direction as out parameter
void GetShootDirection(void* weapon, Vector4* outDir);

// Option B: Direction computed from camera
Vector4 ComputeProjectileDirection(void* camera, void* weapon);

// Option C: Full raycast setup
void SetupWeaponRaycast(Vector4* origin, Vector4* direction, float range);
```

In x64 calling convention:
- `rcx` = first param (self/weapon/camera)
- `rdx` = second param (often Vector4* direction)
- `r8` = third param
- `r9` = fourth param
- `xmm0-xmm3` = float params

## Validation: Is This the Right Function?

Once you find a candidate, verify:
1. It's called once per shot (not constantly)
2. The direction values match your aim direction
3. Modifying them changes where bullets land

Quick test: In CE/x64dbg, manually change the direction values right before the function returns. Fire weapon - does the bullet go in the new direction?

## Known Offsets

Fill in after reverse engineering:

| Game Version | Function | Offset | Signature | Notes |
|--------------|----------|--------|-----------|-------|
| 2.1x | AimDirection setup | 0x??? | ???*(???, Vec4*) | |

## After Finding the Offset

1. Update `native/src/AimCompensation.hpp`:
```cpp
constexpr uintptr_t AIM_FUNCTION_OFFSET = 0xYOUR_OFFSET;
```

2. Update the function signature if needed:
```cpp
// If direction is in a different parameter position, adjust:
using AimFunction_t = void* (*)(void* self, void* arg1, void* arg2);
constexpr int DIRECTION_ARG_INDEX = 2;  // Change to match which arg has direction
```

3. Optionally, extract pattern bytes for version resilience:
```cpp
// Copy first 16 bytes of the function from x64dbg
constexpr const char* AIM_FUNCTION_PATTERN = "\x48\x89\x5C\x24\x08...";
constexpr size_t AIM_FUNCTION_PATTERN_LEN = 16;
```

4. Rebuild and deploy:
```powershell
pixi run build-native
pixi run deploy
```

## Troubleshooting

**Can't find aim direction in memory?**
- Make sure you're scanning while ADS (aiming down sights) for clearer direction values
- Try scanning for the crosshair screen position instead (integer pixels)

**Function not called when firing?**
- You may be looking at targeting preview, not actual fire
- Look for functions called ONLY when you pull the trigger

**Game crashes after hooking?**
- Wrong function signature - double-check parameter types
- Wrong offset - verify with breakpoint first before hooking

**Bullets still follow camera?**
- Hook might be on the wrong function
- Direction modification might be overwritten later
- Try hooking further downstream (closer to projectile spawn)
