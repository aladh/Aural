# App icon

`SpottyIcon.png` is the square source artwork for the native macOS app icon. The mark uses five
connected audio spots to form a compact waveform on a charcoal tile. It is intentionally distinct
from Spotify's three-line logo and contains no Spotify artwork.

The source artwork was generated with Codex's built-in image-generation tool from this design brief:

> Create a distinctive native macOS icon for Spotty using five connected luminous audio spots that
> rise and fall like a tiny waveform. Center the simple, high-contrast mint-to-lime mark on a deep
> charcoal rounded-square tile with transparent pixels outside it. Keep the silhouette readable at
> 16 px. Use no text, letters, musical notes, headphones, play triangle, equalizer bars, watermark,
> or imitation of Spotify's logo.

Run `./Scripts/generate-icon.sh` from the repository root after changing the source PNG. The script
downsamples that exact artwork into every macOS icon representation, generates `Spotty.icns` with
Finder-compatible legacy encodings, and verifies every representation survives a round trip.
