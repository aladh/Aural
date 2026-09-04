#![warn(missing_docs)]
#![doc=include_str!("../README.md")]

#[macro_use]
extern crate log;

use librespot_core as core;
use librespot_playback as playback;
use librespot_protocol as protocol;

mod context_resolver;
mod model;
mod player_bridge; // Aural patch: see PATCHES.md.
mod shuffle_vec;
mod spirc;
mod state;

pub use model::*;
pub use player_bridge::SpircPlayer; // Aural patch: see PATCHES.md.
pub use spirc::*;
pub use state::*;
