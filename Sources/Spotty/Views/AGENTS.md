# Native UI agent guidance

The canonical UX and acceptance rules are in the
[product contract](../../../docs/product-and-acceptance-contract.md). Use this file for the recurring
implementation and review gotchas closest to the view code.

## Product taste

Spotty should have quiet confidence: native, visually calm, information-dense without feeling cramped,
and capable without advertising every capability.

- Start with established macOS structure, typography, controls, menus, focus, keyboard behavior,
  accessibility, and inactive-window semantics. Prefer system behavior over custom chrome.
- Preserve the fixed dark appearance and Spotify-familiar hierarchy through native surfaces: a
  near-black canvas, artwork-led headers, dense tables, queue rail, and full-width player shelf. Do
  not add a theme system, appearance preference, or Settings scene.
- Keep one clear hierarchy. At a glance, the user should know where they are, what is playing, and the
  primary action. Remove persistent controls that do not earn their space.
- Make state honest. Loading, empty, stale, disabled, error, reconnecting, and remote-owner states are
  design requirements. Never show speculative playback state or an action that cannot succeed.
- Preserve selection, focus, scroll position, artwork/content anchors, and useful content across
  refresh, metadata arrival, tab changes, resize, and window activation. Motion explains continuity;
  it does not delay input or decorate chrome.
- Verify keyboard focus, VoiceOver labels/order, reduced motion, active/inactive selection, disabled
  state, truncation, and narrow/window-resize behavior.
- Do not use `.draggable`, `.dropDestination`, or `onDrop`; drag-and-drop is deliberately outside the
  current product contract.
- Views render state and invoke narrow actions. They do not construct network/auth/playback
  dependencies or own asynchronous orchestration. Downsample artwork to rendered Retina size, keep
  presentation caches cost-bounded, and release them with the window lifecycle.
