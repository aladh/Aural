use crate::*;

/// Builds the current connection state info struct, stamped with a fresh revision.
///
/// Reading the state and assigning the revision happen together, so two concurrent
/// publishers cannot end up with revisions that contradict the order they read state in.
/// Delivery is deliberately left outside: `send_json` re-enters Swift, which must never
/// happen while a lock is held.
pub(crate) fn build_connection_state_info() -> ConnectionStateInfo {
    stamped_snapshot(|stamp| {
        let state = with_connection(|c| c.clone());
        ConnectionStateInfo {
            revision: stamp.revision,
            session_generation: stamp.session_generation,
            session_connected: state.session_connected,
            session_connection_id: state.session_connection_id,
            spirc_ready: state.spirc_ready,
            device_id: state.device_id,
            device_name: "Aural".to_string(),
            reconnect_attempt: state.reconnect_attempt,
            last_error: state.last_error,
            connected_since_ms: (state.connected_since_ms > 0).then_some(state.connected_since_ms),
            is_active_device: state.is_active_device,
        }
    })
}

/// Marks the session as disconnected, records the reason, and notifies the UI.
pub(crate) fn mark_disconnected(reason: &str) {
    with_connection(|c| {
        c.session_connected = false;
        c.session_connection_id = None;
        c.connected_since_ms = 0;
        c.last_error = Some(reason.to_string());
    });
    notify_connection_state_change();
}

/// Sends the cluster's device list to Swift, skipping an update that says nothing new.
///
/// Volume is 0..=65535 on the wire and 0..=100 in the app, matching what
/// `/me/player/devices` returned — the conversion belongs here rather than in Swift, so the
/// entity keeps meaning one thing.
pub(crate) fn notify_devices(
    devices: &std::collections::HashMap<String, librespot_protocol::connect::DeviceInfo>,
    active_device_id: &str,
) {
    let mut list: Vec<ConnectDeviceInfo> = devices
        .iter()
        .map(|(id, info)| ConnectDeviceInfo {
            id: id.clone(),
            name: info.name.clone(),
            // `DeviceType` is an open enum on the wire, so an unknown value has no variant to
            // name. `/me/player/devices` answered "Unknown" for the same case.
            device_type: info
                .device_type
                .enum_value()
                .map(|kind| format!("{kind:?}").to_uppercase())
                .unwrap_or_else(|_| "UNKNOWN".to_string()),
            is_active: !active_device_id.is_empty() && id == active_device_id,
            is_private_session: info.is_private_session,
            // The protobuf has no equivalent, and nothing in the app reads it for a
            // connect device. False rather than a guess.
            is_restricted: false,
            volume_percent: Some(((info.volume as f64) / 65535.0 * 100.0).round() as i32),
            // Absent capabilities mean "nothing declared", which is not the same as declaring
            // volume disabled — so the default is false, and only an explicit true greys the
            // slider out. `volume_steps` is the other field that bears on this and is
            // deliberately left alone: it describes granularity, not permission.
            disable_volume: info
                .capabilities
                .as_ref()
                .map(|capabilities| capabilities.disable_volume)
                .unwrap_or(false),
        })
        .collect();

    // The protobuf map has no order, so without this the same devices would look like a new
    // list on every update and the change check below would never fire.
    list.sort_by(|a, b| a.id.cmp(&b.id));

    debug!(
        "notify_devices: cluster carried {} device(s), active={}",
        list.len(),
        active_device_id
    );

    let list_json = match serde_json::to_string(&list) {
        Ok(json) => json,
        Err(e) => {
            debug!("Failed to serialize device list: {:?}", e);
            return;
        }
    };

    let mut last = LAST_DEVICES_JSON.lock().unwrap_or_else(|e| e.into_inner());
    if *last == list_json {
        return;
    }
    *last = list_json;
    drop(last);

    let snapshot = stamped_snapshot(|stamp| DevicesState {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        devices: list,
    });
    let json = match serde_json::to_string(&snapshot) {
        Ok(json) => json,
        Err(e) => {
            debug!("Failed to serialize stamped device list: {:?}", e);
            return;
        }
    };

    if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.devices) {
        if let Ok(c_str) = CString::new(json) {
            callback(c_str.as_ptr());
        }
    }
}

/// Sends the active device ID to the registered callback if it changed since the last update.
/// Called on every cluster update — deduplicates so Swift only sees actual changes.
///
/// An empty ID means "no device is active" and is forwarded as such. It used to be
/// dropped, which left Swift showing the previous active device forever once playback
/// stopped everywhere.
pub(crate) fn notify_active_device_id(device_id: &str) {
    // Only notify if the active device actually changed
    let mut last = LAST_ACTIVE_DEVICE_ID
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if *last == device_id {
        return;
    }
    *last = device_id.to_string();
    drop(last);

    if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.active_device) {
        if let Ok(c_str) = CString::new(device_id) {
            callback(c_str.as_ptr());
        }
    }
}

/// Sends connection state update to the registered callback
pub(crate) fn notify_connection_state_change() {
    if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.connection_state) {
        send_json(callback, &build_connection_state_info());
    }
}

/// Creates the standard ConnectConfig for Spirc.
pub(crate) fn create_connect_config() -> ConnectConfig {
    let initial_volume = INITIAL_VOLUME_SETTING.load(Ordering::SeqCst);
    ConnectConfig {
        name: "Aural".to_string(),
        device_type: DeviceType::Computer,
        initial_volume,
        emit_set_queue_events: true,
        ..Default::default()
    }
}

/// Creates Spirc, spawns its background task, and stores it globally.
/// Returns the Spirc Arc for activation by the caller.
pub(crate) async fn create_and_store_spirc(
    session: &Session,
    credentials: &librespot_core::authentication::Credentials,
    player: Arc<Player>,
    mixer: Arc<SoftMixer>,
) -> Result<Arc<Spirc>, String> {
    let connect_config = create_connect_config();

    let (spirc, spirc_task) = Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player,
        mixer as Arc<dyn Mixer>,
    )
    .await
    .map_err(|e| format!("Spirc init failed: {:?}", e))?;

    let spirc_arc = Arc::new(spirc);
    RUNTIME.spawn(spirc_task);

    *SPIRC.lock().unwrap_or_else(|e| e.into_inner()) = Some(spirc_arc.clone());
    // Deliberately does not record success yet. Activation and, on a reconnect, the
    // rehydrating load still have to run, and either can fail — `init_player_async` commits
    // the whole set once, at the end, when the session is genuinely usable.
    //
    // Setting it here was subtly wrong in two ways. The activation that follows makes
    // librespot emit SessionConnected, whose handler publishes a snapshot; with the flags
    // already true that snapshot announced readiness before playback resumed. And a later
    // failure could only clear the booleans, leaving a fresh connected-since timestamp and
    // a reset attempt counter in the disconnected snapshot that followed.

    debug!(
        "[WAKE +{}ms] Spirc ready - connected to Spotify Connect",
        elapsed_since_wake_ms()
    );

    // Small delay to let librespot's initial cluster processing complete
    tokio::time::sleep(Duration::from_millis(200)).await;

    Ok(spirc_arc)
}

/// Asks for the cluster once, because subscribing to it is not enough to be told what it is.
///
/// **The dealer only pushes changes.** librespot registers its own device and receives the
/// current cluster in the *HTTP response* to that PUT — which this app's separate dealer
/// subscription never sees. Measured on 2026-08-13: registration completed at :04.702 and the
/// first push arrived at :27.035, twenty-three seconds later, and only because a phone
/// connected. With nothing else on the account, Speakers stayed empty indefinitely while a
/// Connect-enabled stereo sat there reachable.
///
/// So this registers a **hidden member** — `can_be_player: false, hidden: true` — the way any
/// pure controller does, and reads the cluster out of the reply. Hidden because this is not a
/// second playback device: librespot already registered the real one under its own id, and
/// re-PUTing that id with a partial state would disturb its registration rather than ask a
/// question.
pub(crate) fn spawn_initial_cluster_fetch(session: &Session, generation: u64) {
    let session = session.clone();

    RUNTIME.spawn(async move {
        // The connection id is assigned over the dealer websocket, which is launched
        // alongside the session rather than before it, so it can be a moment behind.
        let mut connection_id = String::new();
        for _ in 0..40 {
            connection_id = session.connection_id();
            if !connection_id.is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }

        if connection_id.is_empty() {
            debug!("Initial cluster fetch: no connection id, giving up");
            return;
        }

        if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
            return;
        }

        match fetch_cluster(&session).await {
            Ok(cluster) => {
                // Again, after the request rather than only before it. A cluster describes an
                // account, and a logout can land inside this call — `aural_playback_cleanup` empties
                // the snapshot caches, and applying this would fill them straight back up and
                // publish the previous account's devices, queue and playback state to whoever
                // signs in next. The check before the request cannot see that; only this one
                // can.
                if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                    debug!("Initial cluster fetch: superseded while in flight, discarding");
                    return;
                }

                debug!(
                    "Initial cluster fetch: {} device(s), active={}",
                    cluster.device.len(),
                    cluster.active_device_id
                );
                // Same handling a pushed update gets, so there is one path into Swift rather
                // than two that can drift.
                apply_cluster(cluster);
            }
            Err(e) => debug!("Initial cluster fetch failed: {}", e),
        }
    });
}

/// Registers a hidden connect-state member and returns the cluster the service answers with.
pub(crate) async fn fetch_cluster(session: &Session) -> Result<Cluster, String> {
    use protobuf::Message;

    let mut request = PutStateRequest::new();
    request.member_type = MemberType::CONNECT_STATE.into();

    let device = request.device.mut_or_insert_default();
    let info = device.device_info.mut_or_insert_default();
    let capabilities = info.capabilities.mut_or_insert_default();
    capabilities.can_be_player = false;
    capabilities.hidden = true;
    capabilities.needs_full_player_state = true;

    // A member id of our own, distinct from the one librespot registered.
    let endpoint = format!(
        "/connect-state/v1/devices/hobs_{}",
        session.device_id().chars().take(32).collect::<String>()
    );

    let mut headers = http::HeaderMap::new();
    headers.insert(
        "x-spotify-connection-id",
        session
            .connection_id()
            .parse()
            .map_err(|_| "connection id is not a valid header value".to_string())?,
    );

    let bytes = session
        .spclient()
        .request_with_protobuf(&http::Method::PUT, &endpoint, Some(headers), &request)
        .await
        .map_err(|e| format!("{e:?}"))?;

    Cluster::parse_from_bytes(&bytes).map_err(|e| format!("could not parse cluster: {e:?}"))
}

/// Everything a cluster says, delivered to Swift. Shared by the push and the initial fetch,
/// so what the app learns cannot depend on which of the two told it.
///
/// Our own activity is derived from the cluster rather than inferred from whichever command
/// ran last. This is the same comparison `SpircTask` makes internally; Aural runs a second
/// subscription to the same dealer topic and has to reach the same conclusion, or playback
/// routing and the UI disagree.
///
/// The device list rides along and used to be dropped on the floor, so Swift asked
/// `/me/player/devices` for what was already here.
pub(crate) fn apply_cluster(cluster: Cluster) {
    set_active_device(is_active_in_cluster(
        &cluster.active_device_id,
        current_device_id().as_deref(),
    ));
    notify_active_device_id(&cluster.active_device_id);
    notify_devices(&cluster.device, &cluster.active_device_id);

    if let Some(player_state) = cluster.player_state.into_option() {
        send_playback_state(&player_state);
        process_and_send_queue(player_state);
    }
}

/// Subscribes to cluster updates on the session's dealer and spawns a task to process them.
///
/// When the stream ends, the Spirc it belonged to is gone, so this triggers reconnection —
/// but only for the current generation, and only outside an intentional teardown.
pub(crate) fn spawn_cluster_listener(session: &Session, generation: u64) -> Result<(), String> {
    let queue_stream = session
        .dealer()
        .listen_for(
            "hm://connect-state/v1/cluster",
            librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>,
        )
        .map_err(|e| format!("Failed to subscribe to cluster updates: {}", e))?;

    RUNTIME.spawn(async move {
        debug!("Cluster listener started (generation={})", generation);
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            // Same rule as the player event listener: a superseded cluster listener keeps
            // receiving until its stream actually closes, and its updates describe a session
            // that has been replaced. Checking only after the stream ends, as this used to,
            // leaves every message before that point unguarded.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                continue;
            }

            match msg_result {
                Ok(cluster_update) => {
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        apply_cluster(cluster);
                    }
                }
                Err(e) => {
                    debug!("Failed to parse cluster update: {:?}", e);
                }
            }
        }

        debug!("Cluster listener ended (generation={})", generation);

        let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
        if !should_recover_after_cluster_end(generation, current_gen, teardown_in_progress()) {
            debug!(
                "Cluster listener ended without recovery (generation={}, current={})",
                generation, current_gen
            );
            return;
        }

        let intent = RecoveryIntent::capture();
        mark_disconnected("Cluster listener ended unexpectedly");
        spawn_reconnection_loop(intent);
    });

    Ok(())
}
