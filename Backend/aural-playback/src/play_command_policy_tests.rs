fn rust_src(file_name: &str) -> String {
    std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src")
            .join(file_name),
    )
    .unwrap_or_else(|e| panic!("read {file_name}: {e}"))
}

fn function_body(source: &str, signature: &str) -> String {
    let start = source
        .find(signature)
        .unwrap_or_else(|| panic!("missing {signature}"));
    let bytes = source.as_bytes();
    let brace =
        next_unquoted(bytes, start, b'{').unwrap_or_else(|| panic!("{signature} has no body"));
    let end = matching_brace(bytes, brace);
    source[brace + 1..end].to_string()
}

fn match_arm_body(source: &str, pattern: &str) -> String {
    let start = source
        .find(pattern)
        .unwrap_or_else(|| panic!("missing {pattern}"));
    let bytes = source.as_bytes();
    let arrow_rel = source[start..]
        .find("=>")
        .unwrap_or_else(|| panic!("{pattern} is not a match arm"));
    let brace = next_unquoted(bytes, start + arrow_rel + 2, b'{')
        .unwrap_or_else(|| panic!("{pattern} arm has no body"));
    let end = matching_brace(bytes, brace);
    source[brace + 1..end].to_string()
}

fn next_unquoted(bytes: &[u8], from: usize, target: u8) -> Option<usize> {
    let mut i = from;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == target {
                    return Some(i);
                }
                i = next;
            }
        }
    }
    None
}

fn matching_brace(bytes: &[u8], open: usize) -> usize {
    let mut depth = 0usize;
    let mut i = open;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == b'{' {
                    depth += 1;
                } else if b == b'}' {
                    depth -= 1;
                    if depth == 0 {
                        return i;
                    }
                }
                i = next;
            }
        }
    }
    panic!("unbalanced brace")
}

enum Scan {
    Skip(usize),
    Byte(u8, usize),
}

fn scan_code_byte(bytes: &[u8], i: usize) -> Scan {
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'/' {
        let mut j = i + 2;
        while j < bytes.len() && bytes[j] != b'\n' {
            j += 1;
        }
        return Scan::Skip(j);
    }
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
        let mut j = i + 2;
        while j + 1 < bytes.len() && !(bytes[j] == b'*' && bytes[j + 1] == b'/') {
            j += 1;
        }
        return Scan::Skip(j.saturating_add(2).min(bytes.len()));
    }
    if bytes[i] == b'"' {
        return Scan::Skip(skip_quoted(bytes, i, b'"'));
    }
    if bytes[i] == b'\'' {
        return Scan::Skip(skip_quoted(bytes, i, b'\''));
    }
    Scan::Byte(bytes[i], i + 1)
}

fn skip_quoted(bytes: &[u8], start: usize, quote: u8) -> usize {
    let mut i = start + 1;
    let mut escape = false;
    while i < bytes.len() {
        let b = bytes[i];
        if escape {
            escape = false;
        } else if b == b'\\' {
            escape = true;
        } else if b == quote {
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}

fn contains_playing_true_store(source: &str) -> bool {
    let needle = b"IS_PLAYING.store(true";
    let bytes = source.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(_, next) => {
                if bytes[i..].starts_with(needle) {
                    return true;
                }
                i = next;
            }
        }
    }
    false
}

fn production_sources() -> Vec<(String, String)> {
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    for entry in std::fs::read_dir(&src_dir).expect("src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_string();
        if file_name == "tests.rs" || file_name.ends_with("_tests.rs") {
            continue;
        }
        files.push((
            file_name.clone(),
            std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {file_name}: {e}")),
        ));
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));
    files
}

#[test]
fn queued_play_commands_do_not_store_playing_on_load_ok() {
    let control = rust_src("player_control.rs");
    for signature in [
        "fn aural_playback_play_uri",
        "fn aural_playback_play_tracks",
        "fn play_radio_async",
        "fn aural_playback_play_radio",
    ] {
        let body = function_body(&control, signature);
        assert!(
            !contains_playing_true_store(&body),
            "{signature} must not treat Spirc.load Ok as playing"
        );
    }
}

#[test]
fn resume_cannot_short_circuit_from_a_queued_load_alone() {
    let resume = function_body(&rust_src("transport.rs"), "fn resume_playback");
    let playing_guard = resume
        .find("IS_PLAYING.load(Ordering::SeqCst)")
        .expect("resume still consults IS_PLAYING");
    let play_command = resume
        .find("spirc.play()")
        .expect("resume still issues play after the playing guard");
    assert!(
        playing_guard < play_command,
        "queued-load optimism must not skip play/fallback"
    );
    assert!(
        resume[playing_guard..play_command].contains("return 0"),
        "the early return remains the established-playing guard, not a queued-load success"
    );
}

#[test]
fn playing_event_is_the_only_production_store_of_playing_true() {
    let mut true_stores = Vec::new();
    for (file_name, source) in production_sources() {
        if contains_playing_true_store(&source) {
            true_stores.push(file_name);
        }
    }
    assert_eq!(
        true_stores,
        vec!["player_event_pump.rs".to_string()],
        "PlayerEvent::Playing must remain the only production IS_PLAYING=true write"
    );

    let pump = rust_src("player_event_pump.rs");
    let playing_arm = match_arm_body(&pump, "PlayerEvent::Playing");
    assert!(
        contains_playing_true_store(&playing_arm),
        "PlayerEvent::Playing must still establish IS_PLAYING"
    );
}

#[test]
fn pause_stop_teardown_and_player_clears_still_clear_playing() {
    let control = rust_src("player_control.rs");
    let pump = rust_src("player_event_pump.rs");
    let transport = rust_src("transport.rs");

    assert!(function_body(&control, "fn aural_playback_stop").contains("IS_PLAYING.store(false"));
    assert!(
        function_body(&control, "fn aural_playback_cleanup").contains("cleanup_player_globals()")
    );
    assert!(function_body(&control, "fn cleanup_player_globals").contains("IS_PLAYING.store(false"));
    assert!(
        function_body(&control, "fn aural_playback_transfer_playback")
            .contains("IS_PLAYING.store(false")
    );
    assert!(function_body(&transport, "fn publish_accepted_local_pause")
        .contains("IS_PLAYING.store(false"));
    assert!(match_arm_body(&pump, "PlayerEvent::Paused").contains("IS_PLAYING.store(false"));
    assert!(match_arm_body(&pump, "PlayerEvent::Stopped").contains("IS_PLAYING.store(false"));
    assert!(match_arm_body(&pump, "PlayerEvent::EndOfTrack").contains("IS_PLAYING.store(false"));
}
