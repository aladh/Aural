//! Native Spotify playback and Connect bridge for Aural.
//!
//! The crate intentionally retains process-wide ownership: the macOS application creates one
//! playback engine for one account. Modules separate the synchronization, FFI, lifecycle,
//! Connect, queue, and transport responsibilities without changing that runtime contract.

mod connect;
mod ffi;
mod player_control;
mod proxy_sink;
mod queue;
mod runtime;
mod session_lifecycle;
mod state;

pub(crate) use connect::*;
pub(crate) use ffi::*;
pub(crate) use player_control::*;
pub(crate) use proxy_sink::mk_proxy_sink;
pub(crate) use queue::*;
pub(crate) use runtime::*;
pub(crate) use session_lifecycle::*;
pub(crate) use state::*;

pub(crate) use futures_util::StreamExt;
pub(crate) use librespot_connect::{
    ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc,
};
pub(crate) use librespot_core::cache::Cache;
pub(crate) use librespot_core::config::DeviceType;
pub(crate) use librespot_core::session::Session;
pub(crate) use librespot_core::SessionConfig;
pub(crate) use librespot_core::SpotifyUri;
pub(crate) use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
pub(crate) use librespot_playback::mixer::softmixer::SoftMixer;
pub(crate) use librespot_playback::mixer::{Mixer, MixerConfig, NoOpVolume};
pub(crate) use librespot_playback::player::{Player, PlayerEvent, QueueTrack};
pub(crate) use librespot_protocol::connect::{Cluster, ClusterUpdate, MemberType, PutStateRequest};
pub(crate) use librespot_protocol::player::{PlayerState, ProvidedTrack};
pub(crate) use log::debug;
pub(crate) use once_cell::sync::Lazy;
pub(crate) use serde::Serialize;
pub(crate) use std::ffi::{c_char, CStr, CString};
pub(crate) use std::sync::atomic::{
    AtomicBool, AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering,
};
pub(crate) use std::sync::{Arc, Mutex};
pub(crate) use std::time::{Duration, SystemTime, UNIX_EPOCH};
pub(crate) use tokio::runtime::Runtime;
pub(crate) use tokio::sync::mpsc;

#[cfg(test)]
mod tests;
