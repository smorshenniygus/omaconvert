# Contained workers validation

Integration: remote fetched 2026-10-14, origin/main f16eae2. Local refactors applied as b5fdb6b, 9ff472b, cc5ac4e.

Sandbox baseline was invalid for live tests (user systemd bus denied): 247 tests, 81 failures, 68 errors. Retried outside sandbox. Live baseline exposed one actual integration regression: missing tool diagnostic. Reproduced targeted test RED; fixed wrapper order to systemd scope -> exec-helper -> tool. Parent death, memory and launch tests rerun separately.

Implementation and final acceptance pending.
