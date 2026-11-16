# Wisp performance

Measured on an Apple M5 Pro, macOS 27, Wisp 1.2.0 release build (November 2026). Medians of repeated runs.

## Size

| | |
|---|---:|
| Download | **4.2 MB** zip, 4.4 MB disk image — universal (Apple silicon + Intel) |
| App on disk | **8 MB** — about 2 MB of code per architecture, plus Sparkle (2.4 MB) and the icon |
| Third-party libraries | **one** — [Sparkle](https://sparkle-project.org), for in-app updates |

## Startup and memory

| | |
|---|---:|
| Launch → window on screen | **≈ 0.4 s** |
| Memory at idle | **42 MB** |
| Memory with a 1 MB JSON response open | 70 MB |
| Memory with a 10 MB JSON response open | 115 MB |
| CPU at idle | **0 %** |

Memory is the app's physical footprint — what it actually costs your Mac. The very first launch after installing or updating can take a little longer and use more memory while macOS checks the new app; every launch after that settles to the numbers above.

## Speed

| Operation | Time |
|---|---:|
| Pretty-print 1 MB of JSON | 6.7 ms |
| Pretty-print 10 MB of JSON | 68 ms |
| Syntax-highlight a 3.3 MB document | 51 ms |
| Filter a 10 MB JSON response | 49 ms |
| Parse 1,000 cURL commands | 6.4 ms |
| Import a 200-endpoint OpenAPI spec | 7 ms |
| Overhead per request vs. raw `curl` (small JSON, local server) | ≈ 0.3 ms |

How these were measured is in [DEVELOPMENT.md](DEVELOPMENT.md#benchmarks).
