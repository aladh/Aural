use super::*;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;

/// Canonical engine JSON lives with the Swift boundary fixtures so both languages
/// pin one directory. Rust serializes the live structs; Swift decodes the same files.
fn engine_fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../Sources/AuralChecks/DeferredBoundaryChecks/Fixtures/engine")
}

fn fixture_path(name: &str) -> PathBuf {
    engine_fixture_dir().join(format!("{name}.json"))
}

fn pretty_canonical(value: &serde_json::Value) -> String {
    let mut buf = Vec::new();
    let formatter = serde_json::ser::PrettyFormatter::with_indent(b"  ");
    let mut serializer = serde_json::Serializer::with_formatter(&mut buf, formatter);
    value
        .serialize(&mut serializer)
        .expect("pretty-print canonical JSON");
    buf.push(b'\n');
    String::from_utf8(buf).expect("canonical JSON is utf-8")
}

fn assert_canonical_fixture(name: &str, payload: &impl Serialize) {
    let actual = serde_json::to_value(payload).expect("serialize canonical payload");
    let pretty = pretty_canonical(&actual);
    let path = fixture_path(name);
    let expected_text = fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!("missing canonical fixture {}: {error}", path.display());
    });
    let expected: serde_json::Value =
        serde_json::from_str(&expected_text).expect("checked-in fixture is JSON");
    assert_eq!(
        actual, expected,
        "serialized {name} drifted from the checked-in semantic JSON"
    );
    assert_eq!(
        pretty, expected_text,
        "checked-in {name}.json must match the pretty canonical form"
    );
}

fn write_canonical_fixture(name: &str, payload: &impl Serialize) {
    let actual = serde_json::to_value(payload).expect("serialize canonical payload");
    let path = fixture_path(name);
    fs::create_dir_all(path.parent().expect("fixture directory"))
        .expect("create fixture directory");
    fs::write(&path, pretty_canonical(&actual)).expect("write canonical fixture");
}

fn converted_queue_item(uri: &str, provider: &str, uid: &str) -> QueueItem {
    to_queue_item(&provided_track(uri, provider, uid))
}

fn provided_track(uri: &str, provider: &str, uid: &str) -> ProvidedTrack {
    ProvidedTrack {
        uri: uri.to_string(),
        provider: provider.to_string(),
        uid: uid.to_string(),
        ..Default::default()
    }
}

fn playback_minimal() -> PlaybackStateUpdate {
    PlaybackStateUpdate {
        revision: 1,
        session_generation: 1,
        is_playing: false,
        is_paused: false,
        track_uri: String::new(),
        position_ms: 0,
        duration_ms: 0,
        shuffle: false,
        repeat_track: false,
        repeat_context: false,
        timestamp_ms: 0,
    }
}

fn playback_full() -> PlaybackStateUpdate {
    PlaybackStateUpdate {
        revision: 12,
        session_generation: 4,
        is_playing: true,
        is_paused: true,
        track_uri: "spotify:track:fixtureNow".to_string(),
        position_ms: 1_250,
        duration_ms: 180_000,
        shuffle: true,
        repeat_track: false,
        repeat_context: true,
        timestamp_ms: 1_700_000_000_000,
    }
}

fn queue_minimal() -> QueueState {
    QueueState {
        revision: 1,
        session_generation: 1,
        track: None,
        next_tracks: Vec::new(),
        prev_tracks: Vec::new(),
        protocol_next_tracks: Vec::new(),
        protocol_prev_tracks: Vec::new(),
        queue_revision: String::new(),
        disallow_set_queue: false,
        disallow_removing_from_next_tracks: false,
    }
}

fn protocol_next_full() -> ProtocolQueueTrack {
    let mut track = provided_track("spotify:track:fixtureDup", "queue", "occ-a");
    track
        .metadata
        .insert("is_queued".to_string(), "true".to_string());
    track.album_uri = "spotify:album:fixtureAlbum".to_string();
    track.artist_uri = "spotify:artist:fixtureArtist".to_string();
    track.disallow_reasons = vec!["not_active_device".to_string()];
    track
        .restrictions
        .mut_or_insert_default()
        .disallow_resuming_reasons = vec!["not_active_device".to_string()];
    to_protocol_track(&track)
}

fn protocol_next_omitted() -> ProtocolQueueTrack {
    to_protocol_track(&provided_track(
        "spotify:track:fixtureAutoplay",
        "autoplay",
        "",
    ))
}

fn protocol_prev_full() -> ProtocolQueueTrack {
    let mut track = provided_track("spotify:track:fixturePrev", "context", "occ-prev");
    track.metadata.insert(
        "context_uri".to_string(),
        "spotify:playlist:fixtureContext".to_string(),
    );
    track.removed = vec!["removed-reason".to_string()];
    track.blocked = vec!["blocked-reason".to_string()];
    track.album_uri = "spotify:album:fixtureAlbum".to_string();
    track.artist_uri = "spotify:artist:fixtureArtist".to_string();
    to_protocol_track(&track)
}

fn queue_full() -> QueueState {
    QueueState {
        revision: 13,
        session_generation: 4,
        track: Some(QueueItem {
            uri: "spotify:track:fixtureNow".to_string(),
            name: "Fixture Track".to_string(),
            artist: "Fixture Artist".to_string(),
            image_url: "https://example.test/fixture-cover.jpg".to_string(),
            duration_ms: 180_000,
            album_name: "Fixture Album".to_string(),
            provider: "context".to_string(),
            uid: "occ-now".to_string(),
        }),
        next_tracks: vec![
            converted_queue_item("spotify:track:fixtureDup", "queue", "occ-a"),
            converted_queue_item("spotify:track:fixtureDup", "queue", "occ-b"),
            converted_queue_item("spotify:track:fixtureUnavailable", "unavailable", "occ-u"),
        ],
        prev_tracks: vec![converted_queue_item(
            "spotify:track:fixturePrev",
            "context",
            "occ-prev",
        )],
        protocol_next_tracks: vec![protocol_next_full(), protocol_next_omitted()],
        protocol_prev_tracks: vec![protocol_prev_full()],
        queue_revision: "fixture-rev-1".to_string(),
        disallow_set_queue: true,
        disallow_removing_from_next_tracks: true,
    }
}

fn connection_minimal() -> ConnectionStateInfo {
    ConnectionStateInfo {
        revision: 2,
        session_generation: 1,
        session_connected: false,
        session_connection_id: None,
        spirc_ready: false,
        device_id: None,
        device_name: String::new(),
        reconnect_attempt: 3,
        last_error: Some("fixture-session-timeout".to_string()),
        connected_since_ms: None,
        is_active_device: false,
    }
}

fn connection_full() -> ConnectionStateInfo {
    ConnectionStateInfo {
        revision: 14,
        session_generation: 5,
        session_connected: true,
        session_connection_id: Some("fixture-connection".to_string()),
        spirc_ready: true,
        device_id: Some("fixture-mac".to_string()),
        device_name: "Fixture Mac".to_string(),
        reconnect_attempt: 0,
        last_error: None,
        connected_since_ms: Some(1_700_000_000_000),
        is_active_device: true,
    }
}

fn devices_full() -> DevicesState {
    DevicesState {
        revision: 15,
        session_generation: 6,
        devices: vec![
            ConnectDeviceInfo {
                id: "fixture-mac".to_string(),
                name: "Fixture Mac".to_string(),
                device_type: "Computer".to_string(),
                is_active: true,
                is_private_session: false,
                is_restricted: false,
                volume_percent: Some(50),
                disable_volume: false,
            },
            ConnectDeviceInfo {
                id: "fixture-speaker".to_string(),
                name: "Fixture Speaker".to_string(),
                device_type: "Speaker".to_string(),
                is_active: false,
                is_private_session: false,
                is_restricted: false,
                volume_percent: None,
                disable_volume: true,
            },
            ConnectDeviceInfo {
                id: "fixture-unknown".to_string(),
                name: "Fixture Unknown".to_string(),
                device_type: "TOASTER".to_string(),
                is_active: false,
                is_private_session: false,
                is_restricted: true,
                volume_percent: Some(0),
                disable_volume: false,
            },
        ],
    }
}

#[test]
fn canonical_engine_json_matches_pinned_structs() {
    assert_canonical_fixture("playback-minimal", &playback_minimal());
    assert_canonical_fixture("playback-full", &playback_full());
    assert_canonical_fixture("queue-minimal", &queue_minimal());
    assert_canonical_fixture("queue-full", &queue_full());
    assert_canonical_fixture("connection-minimal", &connection_minimal());
    assert_canonical_fixture("connection-full", &connection_full());
    assert_canonical_fixture("devices-full", &devices_full());
}

#[test]
fn canonical_engine_fixture_dir_is_the_swift_boundary_resource() {
    let rendered = engine_fixture_dir().to_string_lossy().replace('\\', "/");
    assert!(
        rendered.contains("Sources/AuralChecks/DeferredBoundaryChecks/Fixtures/engine"),
        "engine fixtures must stay under the boundary Fixtures/engine directory, got {rendered}"
    );
}

/// Regenerates the checked-in artifacts after an intentional serialized-field change.
/// `cargo test --manifest-path Backend/aural-playback/Cargo.toml --lib -- --ignored write_engine_json_contract_fixtures`
#[test]
#[ignore = "rewrites checked-in canonical engine JSON"]
fn write_engine_json_contract_fixtures() {
    write_canonical_fixture("playback-minimal", &playback_minimal());
    write_canonical_fixture("playback-full", &playback_full());
    write_canonical_fixture("queue-minimal", &queue_minimal());
    write_canonical_fixture("queue-full", &queue_full());
    write_canonical_fixture("connection-minimal", &connection_minimal());
    write_canonical_fixture("connection-full", &connection_full());
    write_canonical_fixture("devices-full", &devices_full());
}
