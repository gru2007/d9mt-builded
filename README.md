# d9mt — D3D9 on Metal for Apple Silicon

A from-scratch **Direct3D 9 → Metal** driver for Wine/CrossOver on Apple
Silicon. **No Vulkan, no MoltenVK** — D3D9 calls are translated to Metal
directly.

It pairs DXVK's battle-tested D3D9 front-end (D3D9 → SPIR-V → MSL) with a
custom Metal backend that talks to the GPU through DXMT's `winemetal` bridge.

> **Tested with exactly one game so far.** It has only been run against a
> single D3D9 title (GTA IV) — no other DirectX 9 game has been tried yet, so
> expect unimplemented paths on anything else.

```
YourGame.exe  (32-bit Windows PE, runs under Rosetta 2)
   │  loads
   ▼
d3d9.dll      ← THIS PROJECT (mingw PE):  DXVK D3D9 front-end + d9mt Metal backend
   │            DXSO bytecode → SPIR-V (DXVK) → MSL (spirv-cross) → metallib
   ▼
winemetal.dll / .so   (DXMT prebuilt, Wine builtin)  ──►  Metal  ──►  CAMetalLayer
   ▲
d9mtmetal.so  (our native arm64 Wine unixlib: PSO creation, MSL→metallib compile, shader disk cache)
```

## Status

- **Playable.** A real, draw-call-heavy D3D9 title renders and runs end-to-end
  on an M1 Max at roughly 50-90 fps depending on how many draws a scene issues.
- **Shader disk cache**: each shader compiles once *ever* (out-of-process via
  the Metal toolchain), is cached to disk, and reloads instantly — no compile
  stutter, fast warm boot.
- Performance work landed: async pipeline compilation, command batching,
  buffer suballocation, residency dedup. Frame pacing is clean.
- This is research-grade software for a single platform (Apple Silicon +
  CrossOver). Expect rough edges on untested games.

## Requirements

- **Apple Silicon** Mac (M1/M2/M3…), macOS 14+.
- **CrossOver** (tested on CrossOver 26, which bundles DXMT/winemetal). A
  plain Wine prefix with the DXMT winemetal builtin also works.
- **Xcode Command Line Tools** + the **Metal toolchain** — `xcrun metal` must
  resolve. The native unixlib links `Metal`/`Foundation`, and the shader cache
  shells out to `metal` to compile MSL → metallib. Check:
  `xcrun --sdk macosx --find metal`.
- **mingw-w64** (both `i686-w64-mingw32` and `x86_64-w64-mingw32`) — e.g.
  `brew install mingw-w64`.
- **glslang** (`brew install glslang`), **python3**, and a working `sqlite3`
  (system-provided on macOS).

## Build

Three steps, from the repo root. DXVK and spirv-cross are vendored in
`vendor/` — nothing to fetch for the front-end.

```bash
# 1. Pull DXMT's winemetal binaries into prebuilt/ (needed to link against).
bash scripts/fetch-winemetal.sh

# 2. Build the native companion unixlib (d9mtmetal.so + PE shims) and install
#    it into CrossOver. Set BOTTLE to your game's bottle name.
BOTTLE="My Game" bash tools/build-d9mtmetal.sh

# 3. Build the driver itself -> build/d3d9fe.dll
bash scripts/build-dxvkfe.sh
```

### Release (max-speed) build

For a production build — `-O3`, asserts stripped, and the in-engine profiler +
file logging **compiled out** (zero hot-path instrumentation):

```bash
RELEASE=1 bash scripts/build-dxvkfe.sh
```

It uses a separate object cache (`build/dxvkfe-obj-release`), so it won't clash
with the default dev build.

## Install & run (any bottle, any game)

1. **Deploy the driver as `d3d9.dll`** into your game's folder:

   ```bash
   GAME_DIR="$HOME/Library/Application Support/CrossOver/Bottles/My Game/drive_c/.../YourGame"
   cp build/d3d9fe.dll "$GAME_DIR/d3d9.dll"
   ```

2. **Launch** with `d3d9` overridden to the native (our) DLL:

   ```bash
   CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
   WINEDLLOVERRIDES="d3d9=n" "$CX/bin/wine" --bottle "My Game" \
     start /unix "$GAME_DIR/YourGame.exe"
   ```

Step 2 of the build already installed `winemetal`/`d9mtmetal` into the bottle
and registered them as Wine builtins. If a game ships its own `d3d9.dll`, your
copy in the game folder takes precedence with the override above.

## Tuning (environment variables)

All performance features are **on by default**; set to `0` to disable for A/B.

| var | default | effect |
|-----|---------|--------|
| `D9MT_METALLIB_CACHE` | on | shader disk cache (compile once, reload forever) |
| `D9MT_ASYNC` | on | pre-warm and compile pipelines on background threads; a cold first use still waits by default for correctness |
| `D9MT_ASYNC_SKIP` | off | allow draws to be dropped while their pipeline compiles. This may reduce first-use stutter, but can produce black/incomplete frames; intended only for comparison and profiling |
| `D9MT_PSO_DEADLINE_MS` | `100` | with `D9MT_ASYNC_SKIP=1`, how long a draw may keep being skipped before it compiles the pipeline inline. `0` = never |
| `D9MT_PSO_PREWARM` | on | replay the recorded pipeline set at startup (`d9mt_pso_cache.bin` in the game dir) |
| `D9MT_BATCH` | on | batch render commands into one bridge crossing |
| `D9MT_SUBALLOC` | on | suballocate dynamic buffers (kills DISCARD churn) |
| `D9MT_SHADER_CACHE_PATH` | — | override cache location (default `~/Library/Caches/d9mt/<exe>/`) |
| `D9MT_TRACE` | off | `=1` writes a per-frame CPU breakdown to `d3d9fe-trace.log` (dev builds only; adds overhead) |
| `D9MT_DUMP_MSL` | off | dump generated MSL to a Windows path, e.g. `C:\msl` |

Example — run with the cache off to measure cold compile:
`D9MT_METALLIB_CACHE=0 wine ...`

- SIP can stay enabled; the driver itself doesn't require disabling it.

### A black world with a working HUD

Two unrelated faults look like this, and the log tells them apart.

#### A dropped framebuffer copy (fixed)

Source does not hand the finished frame straight to the swap chain. Several
passes copy the framebuffer into a render-target texture and paint that texture
back over the whole screen: the glow-outline pass copies the scene into a backup
target, clears the framebuffer to black, draws every glowing entity in flat
colour and then restores the backup; motion blur and the engine's post
processing do the same through `_rt_FullFrameFB`. Those copies scale or convert
format — the glow targets are `RGBA16161616F` under HDR — so the d3d9 front-end
sends them down `blitImageView` rather than its copy/resolve fast paths, and
both ways `blitImageView` had of refusing one fired on every frame of a Source
game:

- **`failed to create 2D source view`.** The front-end hands the copy's source
  over as a view created with `VK_IMAGE_USAGE_TRANSFER_SRC_BIT`, and
  `DxvkImageView::createView` — like upstream, which builds its own sampled view
  for the meta-blit pass — returns no descriptor for a view that is neither
  sampled, storage nor an attachment. The sampled view is now built from the
  source image instead, carrying the view's format, subresource and swizzle.
- **`multisampled blit not implemented`.** With antialiasing on, that same
  source is the multisampled scene, which Metal cannot sample from the blit
  shader. It is now resolved into a 1-sample image first — cached per device,
  format and size, since the pass runs two or three times a frame — and the
  sample pass reads the resolved copy. Only a multisampled *destination* still
  fails loud.

Lose the copy and the backup target is never written, so the pass that restores
it paints a full-screen black rectangle over the world and everything in it.
What survives is whatever is drawn afterwards: the glow silhouettes, the
viewmodel, the HUD, the nameplates. Any `blitImageView:` line left in the log is
a copy D9MT still cannot perform, and it names the operation.

#### A skipped draw (off by default)

Dropping a draw whose Metal pipeline is still being built is not semantically
safe. In a game that draws its world with shaders it created moments earlier
(any Source title), that reads as a black screen with a perfectly good HUD and
viewmodel on top. D9MT therefore blocks the first use of a cold pipeline by
default: it takes a queued compile onto the draw thread, or waits for the worker
that already owns it. Recorded pipelines are still pre-warmed asynchronously.
Set `D9MT_ASYNC_SKIP=1` only to restore the old, deliberately lossy behaviour.

When lossy skipping is explicitly enabled, three things bound it, all in
`src/d3d9fe/d9mt_context.cpp`:

- **Two compile lanes.** A pipeline a draw is blocked on goes to an urgent queue
  with normal-priority workers; speculative pre-warm work stays on the
  lowest-priority lane. A stalled draw promotes its pipeline into the urgent
  lane, so it can't sit behind hundreds of pre-warm compiles.
- **A deadline.** After `D9MT_PSO_DEADLINE_MS` of skipped draws the frame thread
  compiles the pipeline itself, rate-limited to a 50% duty cycle so a cold level
  fills in at reduced frame rate instead of freezing or staying black.
- **A stall report**, in the release build too: `d3d9fe.log` (next to the game's
  exe) gets a `d9mt: PSO stall:` line about once a second while draws are being
  dropped, with the queue depths. No line, and the screen still black, means the
  dropped-copy failure above — which reports itself on the `err:` channel, not in
  `d3d9fe.log`.

## How it works (deeper)

- The DXVK D3D9 front-end (vendored) turns the game's DXSO shader bytecode into
  SPIR-V and tracks all D3D9 state; spirv-cross turns SPIR-V into MSL.
- The d9mt backend (`src/d3d9fe/`) replaces DXVK's Vulkan layer: it builds
  Metal render pipelines, argument buffers, and command streams, and submits
  them through `winemetal`.
- `d9mtmetal` (`src/d9mtmetal/`) is our small native Wine unixlib for the two
  things `winemetal` doesn't expose: pipeline-state creation with a vertex
  descriptor, and the MSL→metallib compile + on-disk shader cache.
- See `docs/` for the architecture notes (Metal backend, shader cache design).

## Credits

- **[DXVK](https://github.com/doitsujin/dxvk)** — the D3D9 front-end (DXSO →
  SPIR-V) and spirv-cross plumbing, vendored under `vendor/`.
- **[DXMT](https://github.com/3Shain/dxmt)** — the `winemetal` bridge that
  carries Metal calls across the Wine wow64 boundary.
- **spirv-cross** — SPIR-V → MSL.

## License

See the licenses of the vendored components (DXVK, spirv-cross) under
`vendor/`. d9mt's own code follows suit.
