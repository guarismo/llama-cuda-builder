# llama-cuda-builder

Builds upstream [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) releases
in GitHub Actions for **shockwave**, so nothing has to compile on the box itself.

This is **not a fork**. Upstream tags are built verbatim; only the build flags are ours.

## What it does

A scheduled workflow (every 6h, or manually) checks upstream for a new release. If it
finds one it hasn't built, it compiles it and publishes a tarball as a release here,
tagged with the upstream tag.

## Target: shockwave

| | |
|---|---|
| GPUs | 2× RTX 3060 12 GB → `CMAKE_CUDA_ARCHITECTURES=86` |
| CPU | **AMD FX-8350** (Piledriver): `avx`, `fma`, `f16c` — **no AVX2, no AVX-512** |
| OS | Ubuntu 26.04, glibc 2.43, GCC 15.2 |
| CUDA | 12.4 runtime (`libcudart.so.12`) — CI builds with 12.6.3, compatible via major soname |

**The CPU is the part that bites.** Runners are modern Xeon/EPYC. Building with
`-DGGML_NATIVE=ON` there emits AVX2/AVX-512 and the binary dies with SIGILL on the
FX-8350, so the workflow pins flags explicitly:

```
-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_FMA=ON -DGGML_F16C=ON
-DGGML_AVX2=OFF -DGGML_AVX512=OFF
```

It isn't only a startup concern: `qwen36-35b-a3b` runs `--n-cpu-moe 8`, so CPU kernels
execute on every token. Both the workflow and the installer check the built binary for
`%ymm`/`%zmm` registers and refuse it if present.

CUDA stays on **12.x** (CI uses 12.6.3). The box links `libcudart.so.12`/`libcublas.so.12`,
so a 13.x build would want `.so.13` and fail to load. The minor version need not match.

## Installing a build

```bash
scripts/install-shockwave.sh v0.5.0            # download, verify, back up, install, check
scripts/install-shockwave.sh v0.5.0 --dry-run  # show the steps only
```

The installer refuses to proceed if the binary doesn't match the CPU or if the backup
comes out suspiciously small, and it finishes by running `verify-presets.py` against the
live router. If any preset fails it prints the rollback command.

## Why verification is not optional

A merged build once benchmarked beautifully, ran Gemma and Bonsai fine, and silently
crashed `qwen36-35b-a3b` — a preset with `load-on-startup = false`, so it only broke when
something asked for it. It went unnoticed for days. `verify-presets.py` asks every preset
the router advertises a real question and checks the answer, not just that it loaded.

## Deliberately manual

CI publishes; it does not deploy. Installing stops the service on a machine that serves
live agents, so that step stays a human decision.
