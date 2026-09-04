// Aural patch: see ../PATCHES.md.
//
// `SpircTask` only ever needs a narrow slice of `librespot_playback::player::Player`. This
// trait names exactly that slice so `Spirc::new` can accept any player implementation, not
// just the concrete librespot `Player`.

use crate::{
    core::SpotifyUri,
    playback::player::{Player, PlayerEventChannel},
};

/// The player operations `SpircTask` calls. Implemented for librespot's own `Player` below;
/// an Aural implementation can swap in a different audio path behind the same Spirc logic.
pub trait SpircPlayer: Send + Sync {
    /// Starts loading and, if `start_playing`, playing `track_id` from `position_ms`.
    fn load(&self, track_id: SpotifyUri, start_playing: bool, position_ms: u32);
    /// Starts preloading `track_id` so it is ready when the current track ends.
    fn preload(&self, track_id: SpotifyUri);
    /// Resumes playback of the loaded track.
    fn play(&self);
    /// Pauses playback of the loaded track.
    fn pause(&self);
    /// Stops playback and releases the loaded track.
    fn stop(&self);
    /// Seeks the loaded track to `position_ms`.
    fn seek(&self, position_ms: u32);
    /// Returns a new channel that receives every subsequent `PlayerEvent`.
    fn get_player_event_channel(&self) -> PlayerEventChannel;
    /// Reports a `VolumeChanged` event without changing the actual output volume.
    fn emit_volume_changed_event(&self, volume: u16);
    /// Reports a `FilterExplicitContentChanged` event.
    fn emit_filter_explicit_content_changed_event(&self, filter: bool);
    /// Reports a `SessionConnected` event.
    fn emit_session_connected_event(&self, connection_id: String, user_name: String);
    /// Reports a `SessionDisconnected` event.
    fn emit_session_disconnected_event(&self, connection_id: String, user_name: String);
    /// Reports a `SessionClientChanged` event.
    fn emit_session_client_changed_event(
        &self,
        client_id: String,
        client_name: String,
        client_brand_name: String,
        client_model_name: String,
    );
    /// Reports a `ShuffleChanged` event.
    fn emit_shuffle_changed_event(&self, shuffle: bool);
    /// Reports a `RepeatChanged` event.
    fn emit_repeat_changed_event(&self, context: bool, track: bool);
    /// Reports an `AutoPlayChanged` event.
    fn emit_auto_play_changed_event(&self, auto_play: bool);
}

impl SpircPlayer for Player {
    fn load(&self, track_id: SpotifyUri, start_playing: bool, position_ms: u32) {
        Player::load(self, track_id, start_playing, position_ms)
    }

    fn preload(&self, track_id: SpotifyUri) {
        Player::preload(self, track_id)
    }

    fn play(&self) {
        Player::play(self)
    }

    fn pause(&self) {
        Player::pause(self)
    }

    fn stop(&self) {
        Player::stop(self)
    }

    fn seek(&self, position_ms: u32) {
        Player::seek(self, position_ms)
    }

    fn get_player_event_channel(&self) -> PlayerEventChannel {
        Player::get_player_event_channel(self)
    }

    fn emit_volume_changed_event(&self, volume: u16) {
        Player::emit_volume_changed_event(self, volume)
    }

    fn emit_filter_explicit_content_changed_event(&self, filter: bool) {
        Player::emit_filter_explicit_content_changed_event(self, filter)
    }

    fn emit_session_connected_event(&self, connection_id: String, user_name: String) {
        Player::emit_session_connected_event(self, connection_id, user_name)
    }

    fn emit_session_disconnected_event(&self, connection_id: String, user_name: String) {
        Player::emit_session_disconnected_event(self, connection_id, user_name)
    }

    fn emit_session_client_changed_event(
        &self,
        client_id: String,
        client_name: String,
        client_brand_name: String,
        client_model_name: String,
    ) {
        Player::emit_session_client_changed_event(
            self,
            client_id,
            client_name,
            client_brand_name,
            client_model_name,
        )
    }

    fn emit_shuffle_changed_event(&self, shuffle: bool) {
        Player::emit_shuffle_changed_event(self, shuffle)
    }

    fn emit_repeat_changed_event(&self, context: bool, track: bool) {
        Player::emit_repeat_changed_event(self, context, track)
    }

    fn emit_auto_play_changed_event(&self, auto_play: bool) {
        Player::emit_auto_play_changed_event(self, auto_play)
    }
}
