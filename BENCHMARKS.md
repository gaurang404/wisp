# Wisp performance

Measured on an Apple M5 Pro, macOS 27, Wisp 1.0 release build. Medians of repeated runs.

## Size

| | |
|---|---:|
| Download (zip) | **2.9 MB** — universal (Apple silicon + Intel) |
| App on disk | **5.1 MB** (about 2 MB of code per architecture, plus the icon) |
| Third-party libraries | **none** — only Apple's system frameworks |

## Startup and memory

| | |
|---|---:|
| Launch → window on screen | **≈ 0.28 s** |
| Memory at idle | **41 MB** |
| Memory with a 1 MB JSON response open | 61 MB |
| Memory with a 10 MB JSON response open | 120 MB |
| CPU at idle | **0 %** |

Memory is the app's physical footprint — what it actually costs your Mac. The very first launch after installing or updating can take a little longer and use more memory while macOS checks the new app; every launch after that settles to the numbers above.

## Speed

| Operation | Time |
|---|---:|
| Pretty-print 1 MB of JSON | 6.7 ms |
| Pretty-print 10 MB of JSON | 67 ms |
| Syntax-highlight a 3.3 MB document | 55 ms |
| Filter a 10 MB JSON response | 48 ms |
| Parse 1,000 cURL commands | 6.4 ms |
| Import a 200-endpoint OpenAPI spec | 7 ms |
| Overhead per request vs. raw `curl` (small JSON, local server) | ≈ 0.3 ms |

How these were measured is in [DEVELOPMENT.md](DEVELOPMENT.md#benchmarks).
