#if NEG_CSTRING
    func negativeCString() {
        let callback: ConnectionStateCallback = { snapshot in
            let required: UnsafePointer<CChar> = snapshot.pointee.device_id
            _ = required
        }
        _ = callback
    }
#endif

#if NEG_MUT_CSTRING
    func negativeMutableCString() {
        let returned = spotty_playback_get_resume_context_uri()
        let required: UnsafeMutablePointer<CChar> = returned
        _ = required
    }
#endif

#if NEG_QUEUE_SNAPSHOT
    func negativeQueueSnapshot() {
        let returned = spotty_playback_get_queue_snapshot()
        let required: UnsafeMutablePointer<SpottyQueueSnapshot> = returned
        _ = required
    }
#endif

#if NEG_STRING_PAIR
    func negativeStringPair() {
        func inspect(_ track: SpottyProtocolQueueTrack) {
            let required: UnsafePointer<SpottyStringPair> = track.metadata
            _ = required
        }
        _ = inspect
    }
#endif

#if NEG_RESTRICTION
    func negativeRestriction() {
        func inspect(_ track: SpottyProtocolQueueTrack) {
            let required: UnsafePointer<SpottyRestriction> = track.restrictions
            _ = required
        }
        _ = inspect
    }
#endif

#if NEG_QUEUE_TRACK
    func negativeQueueTrack() {
        func inspect(_ snapshot: SpottyQueueSnapshot) {
            let required: UnsafePointer<SpottyProtocolQueueTrack> = snapshot.next_tracks
            _ = required
        }
        _ = inspect
    }
#endif

#if NEG_DEVICE
    func negativeDevice() {
        func inspect(_ snapshot: SpottyDevicesSnapshot) {
            let required: UnsafePointer<SpottyProtocolDevice> = snapshot.devices
            _ = required
        }
        _ = inspect
    }
#endif

#if NEG_STRING_ARRAY
    func negativeStringArray() {
        func inspect(_ restriction: SpottyRestriction) {
            let required: UnsafePointer<UnsafePointer<CChar>?> = restriction.reasons
            _ = required
        }
        _ = inspect
    }
#endif

#if NEG_FLOAT_SAMPLES
    func negativeFloatSamples() {
        let callback: AudioDataCallback = { samples, _ in
            let required: UnsafePointer<Float> = samples
            _ = required
        }
        _ = callback
    }
#endif

#if NEG_STRING_ARRAY_ELEMENT
    func negativeStringArrayElement() {
        func inspect(_ restriction: SpottyRestriction) {
            guard let reasons = restriction.reasons else { return }
            let required: UnsafePointer<CChar> = reasons.pointee
            _ = required
        }
        _ = inspect
    }
#endif
