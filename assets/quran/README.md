# Quran dataset provenance

`quran-uthmani.txt` is an **unmodified official Tanzil Uthmani 1.1 download**,
retrieved 2026-10-17 from:

https://tanzil.net/pub/download/index.php?quranType=uthmani&outType=txt-2&marks=true&sajdah=true&tatweel=true&agree=true

SHA-256: `6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f`

114 surahs, 6,236 ayahs; UTF-8, numbered text format. Pause marks, sajdah signs,
and tatweel are retained using the publisher's download options. No Unicode
normalization, spelling changes, or generated text is applied by this app.

The publisher's full CC BY 3.0 notice and additional verbatim-copy terms remain
at the end of the file. Attribution: **Tanzil Project**, https://tanzil.net/.
License: https://tanzil.net/docs/text_license. Updates: https://tanzil.net/updates/.
Tanzil describes the text as verified; this project verifies its bundled bytes,
structure, and ayah counts, not an independent scholarly textual review.

`quran-data.xml` is the unmodified metadata version 1.0, copyright 2008–2009
Tanzil.info, CC-BY as declared in its root element, from
https://tanzil.net/res/text/metadata/quran-data.xml.

SHA-256: `8867c1d88191472adec9db694b3cd9f135b1a2ef580574d32cf888dcb22c5c7a`

Runtime and tests check both hashes. Updating assets requires an intentional
review of the upstream changes and updated hashes/tests. The application never
fetches Quran text over the network. Projects store ayah references, not copies
of the text. Exported video has a visible Tanzil credit and MP4 source metadata;
the app retains a `.mp4.txt` attribution sidecar alongside each local export.
