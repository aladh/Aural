# App icon

[SpottyIcon.png](SpottyIcon.png) is the square source artwork for the native macOS app icon. Five
connected audio spots form a compact waveform on a charcoal tile. The mark is distinct from
Spotify's three-line logo and contains no Spotify artwork.

The source is opaque full-bleed art with no transparency: macOS Tahoe places icons with
transparent edges inside a gray squircle in the Dock, so the system must clip the full-bleed
art to a clean squircle itself. `Scripts/verify-icon-opaque.swift` (run by `generate-icon.sh`)
rejects source art with transparent border pixels. Keep the silhouette readable at 16 px.

The source artwork was generated with Codex's built-in image-generation tool from this design brief:

> Create a distinctive native macOS icon for Spotty using five connected luminous audio spots that
> rise and fall like a tiny waveform. Center the simple, high-contrast mint-to-lime mark on a deep
> charcoal rounded-square tile with transparent pixels outside it. (The transparency has since
> been flattened to opaque full-bleed art for macOS Tahoe; see above.) Keep the silhouette readable at
> 16 px. Use no text, letters, musical notes, headphones, play triangle, equalizer bars, watermark,
> or imitation of Spotify's logo.

The generated `Spotty.icns` contains every standard macOS icon size, with Finder-compatible legacy
encodings. After changing the source PNG, follow the
[icon regeneration procedure](../docs/development-setup.md#generated-local-state).
