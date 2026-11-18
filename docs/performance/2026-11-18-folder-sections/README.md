# Folder rows in sections, 18 November 2026

Raw samples for [the folder list's sections](../../PERFORMANCE.md#scrolling-deep-in-a-large-folder-18-november).
All runs were on an iPad Pro 11-inch (M5) Simulator, iOS 27.2, on the MacBook Air, with a Release
build (`ENABLE_TESTABILITY=YES`) and three samples per size. Each variant ran in the same build,
chosen at launch, so build differences can't account for them. Pairs were alternated and their
order reversed in the second pass.

| File | Benchmark | Labels |
|---|---|---|
| `deep-scroll.jsonl` | `testFolderScreen`, `REMOTEFILES_BENCHMARK_SCROLL_START=0.7` | `baseline` (one section), `fresh` (the change) |
| `filter.jsonl` | `testFolderScreenFiltering` | `baseline`, `fresh`, `pow2` (the change's sizes with fixed identities) |
| `arriving.jsonl` | `testFolderScreenArriving` | `baseline`, `fresh` |
| `deep-scroll-section-sizes.jsonl` | `testFolderScreen`, scrolling from 0.7 | `baseline`, `s50` (sections of 50), `sqrt` (sections of the square root, fixed identities) |
| `top-scroll-sections-of-50.jsonl` | `testFolderScreen`, scrolling from the top | `baseline`, `sections` (sections of 50) |
| `arriving-fixed-identities.jsonl` | `testFolderScreenArriving` | `baseline`, `pow2` |

The first three files were recorded with the Mac's one-minute load average between 5 and 11. The
last was recorded while two other apps' processes each kept a core busy, so its frame times are
noisier; it is kept because the gap between its arms was far larger than that noise in both passes.
