# App icon

[SpottyIcon.png](SpottyIcon.png) is the square source artwork for the native macOS app icon. Five
connected audio spots form a compact waveform on a charcoal tile. The mark is distinct from
Spotify's three-line logo and contains no Spotify artwork.

The source artwork was generated with Codex's built-in image-generation tool from this design brief:

> Create a distinctive native macOS icon for Spotty using five connected luminous audio spots that
> rise and fall like a tiny waveform. Center the simple, high-contrast mint-to-lime mark on a deep
> charcoal rounded-square tile with transparent pixels outside it. Keep the silhouette readable at
> 16 px. Use no text, letters, musical notes, headphones, play triangle, equalizer bars, watermark,
> or imitation of Spotify's logo.

`Spotty.icon` is the Icon Composer document used for the native icon catalog. It embeds the original
artwork at its native size on the 1024-point canvas, so its transparent padding falls outside the
system mask. Extra glass, translucency, and group shadows are disabled to preserve the artwork.
Edit this document in Icon Composer and verify its macOS previews when changing the native icon.

The generated `Spotty.icns` retains the legacy icon representations. After changing the source PNG,
follow the [icon regeneration procedure](../docs/development-setup.md#generated-local-state).
