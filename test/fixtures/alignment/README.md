# Licensed alignment fixture

`fatiha-cc0.ogg` is the unmodified Commons file **AlFātihatulKitāb.ogg**,
own work by **Ibrahimmusa4**, dated 2024-11-08, released under **CC0 1.0**.

- Source/license declaration: https://commons.wikimedia.org/wiki/File:AlF%C4%81tihatulKit%C4%81b.ogg
- Original: https://upload.wikimedia.org/wikipedia/commons/6/6d/AlF%C4%81tihatulKit%C4%81b.ogg
- License: https://creativecommons.org/publicdomain/zero/1.0/
- SHA-256: `59a4eef339d3e42aeaf9b77a6423297a0f830e4872783fc0718a64862b02df32`
- Commons SHA-1: `671b6e324988d3752318d2e8be1fb9cc7db30e58`
- Original size 809,597 bytes; duration 92.72 seconds. Retrieved 2026-10-17.

The description identifies Al-Fatiha; the English structured-data caption
incorrectly says Al-Baqarah. Acoustic decoding of the selected passage agrees
with Al-Fatiha 1:2–3. The recording includes introductory speech and material
outside this selection; the tests deliberately select source seconds 14–27.

`expected.json` contains broad **model-assisted regression windows**, established
by inspecting acoustic output for this fixture. They are not independent human
annotations and cannot establish model accuracy. The strongest timing regression
uses known edits: prepend five seconds, insert a two-second pause at source
21.75 s, then verify that returned source times change by those known offsets
within 0.7 seconds. Tests also reject silence, random noise and a wrong ayah range.
Repeated passage rejection and slowed playback crossing a chunk boundary are
also checked. Synthetic CTC tests independently check repeated labels, blank
states and dwell.

This small test is a pipeline smoke/regression test, not a multi-reciter benchmark.
No median/p95 boundary error or Quran-wide accuracy claim is supported by it.

The reviewer procedure for turning `reference-template.json` into a filled
independent reference, and the ≥24-clip / 3-reciter evaluation procedure, are
documented in [`docs/ALIGNMENT_ANNOTATION.md`](../../../docs/ALIGNMENT_ANNOTATION.md).
Keep this template unfilled; copy it to a working file (for example
`output/quality/reference.json`) before annotating.
