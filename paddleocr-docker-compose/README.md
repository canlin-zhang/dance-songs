# paddleocr-docker-compose

Converts scanned PDFs and images to markdown, JSON and DOCX with
[PaddleOCR-VL](https://github.com/PaddlePaddle/PaddleOCR) running in Docker
Compose, GPU-pinned.

One page of a Chinese/English book scan takes roughly 20 s of GPU time plus
about 40 s of container start and model load. Layout, reading order and tables
come out of the VLM; coordinates come out in the JSON.

## Requirements

- An **NVIDIA GPU**. Tested on an RTX 5080 (compute capability 12.0 / `sm_120`)
  only; other cards are untested rather than supported. The base image is
  Paddle's `sm120` build, since `cu126` wheels carry no `sm_120` kernels.
- A driver new enough for CUDA 12.9, which the image requires: **575.51.03+ on
  Linux, 576.02+ on Windows**. Blackwell cards need R570+ regardless.
- **Docker Compose 2.30 or newer** — the `docker compose` plugin, not the old
  `docker-compose` binary. `2.30` is the floor because `compose.yaml` uses the
  service-level `gpus` key; on older v2 it fails with `Additional property gpus
  is not allowed`, and the fix is to swap that line for the longer
  `deploy.resources.reservations.devices` block.
- On **WSL2**, the Windows driver exposes the GPU; nothing NVIDIA is installed
  inside Linux. `setup.sh` handles what is missing (see below).
- About 15 GB of disk: a ~10 GB image, ~2 GB of models, plus outputs.

### What `setup.sh` does to your machine

It needs **sudo and apt**, and it changes system-wide state:

- installs `nvidia-container-toolkit` from NVIDIA's apt repository;
- edits `/etc/docker/daemon.json` to add the `nvidia` runtime (existing keys are
  kept, and the file is backed up if it exists);
- writes `/etc/cdi/nvidia.yaml`;
- **restarts the Docker daemon** — running containers will be interrupted.

If that is not acceptable on a host you care about, install the toolkit
yourself and run `./setup.sh --skip-toolkit`.

## Quickstart

```bash
./setup.sh --dry-run    # print every command it would run, sudo ones included
./setup.sh              # one-time host setup: NVIDIA container toolkit, CDI
                        # spec, GPU gate, base image pull, image build
./ocr.sh scan.pdf       # convert ./input/scan.pdf
```

`setup.sh` refuses to pull the image until a throwaway container can see the
GPU, so a broken toolkit costs you seconds rather than 10 GB.

## Layout

    input/    drop files here (pdf, png, jpg, tif)
    output/   one subdirectory per input file
    models/   model cache, mounted at /models — keep it, it is not re-downloaded

Run `./ocr.sh` with no arguments to convert everything in `input/`.

## Usage

```
./ocr.sh                        convert every file in input/
./ocr.sh scan.pdf               one file: cwd first, then input/
./ocr.sh scan.pdf out/custom    explicit output directory
./ocr.sh --dry-run scan.pdf     print the docker compose command, run nothing
```

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODE` | `doc_parser` | `doc_parser` (PaddleOCR-VL, markdown), `ocr` (text lines only, faster — writes JSON and images, **not** markdown), `pp_structurev3` (untested here) |
| `DEVICE` | `gpu:0` | Passed to Paddle explicitly rather than left to auto-selection |
| `OCR_ROOT` | this directory | Base for the three paths below |
| `OCR_INPUT` / `OCR_OUTPUT` / `OCR_MODELS` | `$OCR_ROOT/{input,output,models}` | Override individually |

Output per input file, in `output/<name>/`: `<name>.md` (reading order and
headings), `<name>_res.json` (blocks, labels, coordinates), `<name>.docx`,
`imgs/`, and `<name>_layout_det_res.png` (what the layout model saw).

## Troubleshooting

**`libcuda.so` warning at startup — harmless.** The WSL2 mount provides only
`libcuda.so.1`, and Paddle warns while probing for the bare `libcuda.so` name
before loading the versioned one. Paddle still reports the GPU and computes.

**`failed to discover GPU vendor from CDI: no known GPU vendor found`** — the
NVIDIA container toolkit or its CDI spec is missing. Re-run `./setup.sh`, or
check `ls -l /etc/cdi/nvidia.yaml` and `docker info | grep -i cdi`.

**A page looks garbled or truncated** — check `<name>_layout_det_res.png` first.
Blocks the layout model merged or split are visible there, and no amount of
prompting fixes a bad box.

### Known issue: the run can stall forever (root cause located)

Observed rate: **5 stalls in 39 single-page runs (12.8%, Wilson 95% CI
5.6–26.7%)**. Every stall looked identical: one CPU core pinned near 100%, GPU
idle, model weights resident in VRAM, no output, no error, indefinitely.

**Where it spins.** `py-spy` on five independent stalls put the VLM worker
thread in the same place every time: `cuLibraryGetModule` in `libcuda.so.1.1`,
called from `cudaLaunchKernel` for the first bf16 `EmbeddingKernel`. Sampling
the innermost frame 20 times during one stall returned the same address 12
times; disassembling that address in the driver shows a spin loop:

```
4ddd90:  mov    -0x84(%rbp),%eax    ; read status
4ddd99:  je     ...                 ; 1 = done, leave
4ddda2:  je     ...                 ; 5 = done, leave
4ddda8:  pause                      ; spin hint
4dddaa:  call   0x12fd9a0           ; re-check
4dddb7:  je     0x4ddd90            ; not ready -> loop
```

**What that means.** The driver waits in userspace for a status word to become
1 or 5. While it spins it issues **no system calls at all** — so this is not
blocked I/O or a kernel wait, it is a memory flag that never changes. On WSL2
that flag is updated by the Windows driver over `/dev/dxg`; when the update
never arrives, the Linux side spins forever.

**Ruled out by measurement:**

- *PTX JIT* — the image ships `sm_120` SASS (`-arch sm_120` annotations), and an
  embedding kernel runs with `CUDA_DISABLE_PTX_JIT=1`, which fails hard if any
  kernel has to be compiled. The driver is loading a prebuilt module.
- *Insufficient VRAM* — no allocation error was ever raised, and the same
  workload completes on the same card.
- *Page count* — a single page stalls, eight pages stall, and the stall happens
  before the first page is written, so it is independent of workload size.

**Mitigation, not a fix:** `compose.yaml` sets `CUDA_MODULE_LOADING=EAGER`.
Measured on the same harness — **40/40 runs clean with EAGER against 5/39
stalls without it** (Fisher exact, one-sided p ≈ 0.026). It costs about 15 s
per run (56–63 s versus 36–43 s) because modules load at context init instead
of at first launch. It does not remove the spin loop; it changes when the flag
the loop waits on is read. At this rate it is the better trade, especially for
a long batch where one stall wastes the whole run. If a stall still happens,
kill the container and run again.

### TODO: throughput varies ~1.5× between runs

Same input, same machine, same settings: the 205-page book took 42 minutes on
one run and 63 on another, with identical GPU clocks and utilisation. Unexplained.
**Needs more profiling**; not currently under investigation. Do not chase this
without a proper measurement harness — several earlier attempts produced wrong
conclusions for exactly that reason.

## Licence

MIT, see the repository root.
