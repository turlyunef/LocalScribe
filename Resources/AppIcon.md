# Иконка LocalScribe

Выбранный вариант 17 с красной точкой из варианта 20. Создан встроенным `image_gen`, без CLI/API. Исходный PNG — 1254 × 1254 px, RGBA; запрошенное в промпте предпочтительное разрешение 2048 × 2048 генератор не выдал. PNG сохранён без увеличения.

`bash scripts/build_icon.sh` уменьшает исходник системным `sips` и собирает `AppIcon.icns` через `iconutil`. В контейнере десять представлений: 16, 32, 128, 256 и 512 pt в масштабах 1× и 2×. Сборка приложения выполняет эту команду автоматически.

## Финальный промпт

Reference image: второй лист вариантов из этого чата, номера 11–20.

```text
Use case: precise-object-edit / logo-brand.
Create ONE final production macOS app icon as a high-resolution square PNG, preferably 2048x2048. The reference is a numbered concept board. EXTRACT AND FAITHFULLY RECREATE the design of ICON 17, bottom row SECOND column, as the sole standalone icon. Add ONLY the coral red recording dot from ICON 20 in the upper-right, outside the document and inside the rounded square. This is a finished app asset, not a concept sheet.

Preserve icon 17: a muted deep indigo rounded-square tile, a large centered warm-white portrait document with gently rounded corners and a folded upper-right corner rendered in pale lavender; on lower half of document a bold indigo waveform resolves into a rising checkmark. The waveform and checkmark must be one continuous thick, smooth, round-ended stroke. Preserve the style, geometry, proportions, colors and uncluttered feel of reference icon 17. Minimal vector-like precision, no texture, no new decorative elements. The tile can retain the extremely subtle indigo gradient of 17.

Add a small solid coral-red circular recording dot near the top-right of the document, positioned as in icon 20: floating outside the page's folded corner, contained fully within the indigo tile. Keep at least one dot-radius gap from the page and from tile edge. The dot should be approximately 11% of tile width. The document may shift very slightly left to balance the added dot, but retain icon 17 composition.

macOS asset framing: the colored rounded-square tile fills about 82% of the total square canvas width and height, centered with even transparent padding on all four sides; rounded corners of tile are genuine transparency outside the tile. The tile itself is opaque. Outside tile, fully transparent alpha, no white or gray surrounding background, no baked checkerboard. At most a very subtle close shadow. Crisp smooth antialiased edges, accurate circle and page silhouette, premium finish.

Absolutely no number 17 or 20, no labels, no letters, no words, no mockup, no grid, no border around the canvas, no perspective. Output exactly the single ready-to-use icon.
```
