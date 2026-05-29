# ADR-0020: Offline Storage for Library Playlists and Songs

## Status

Accepted

## Context

Kaset needs an offline storage mode that can preserve the user's library playlists and the songs inside them without depending on live network access at playback time.

The feature needs to support two different flows:

1. Automatic background sync when the setting is enabled.
2. Manual per-playlist and per-song saves even when automatic sync is disabled.

The stored data also needs to remain inspectable inside the app, so users can see what was downloaded and which playlists reference each saved song.

## Decision

Introduce a dedicated `OfflineStorageManager` that owns the offline cache manifest, downloaded audio files, and per-playlist/per-song mapping records.

The offline store uses the following layout under Application Support:

- `offline-storage/index.json` for the global manifest
- `offline-storage/playlists/<playlist-id>.json` for playlist mapping records
- `offline-storage/songs/<video-id>.json` for song records
- `offline-storage/media/<video-id>.<ext>` for downloaded audio media

The manager refreshes the user's library playlists on app launch and persists that list locally. When offline storage is enabled in Settings, the refresh path also syncs all library playlists by downloading their playable tracks.

Manual save actions are available in two places:

- Playlist detail views can save or refresh the current playlist offline.
- Song context menus can save or refresh an individual song offline.

If a song is already stored, saving another playlist that contains it reuses the existing audio file and only updates the playlist-to-song mapping data.

The app also exposes a dedicated sidebar page with separate tabs for saved playlists and saved songs.

## Consequences

### Positive

- Users can keep playlists and songs available offline without leaving the app.
- Automatic sync can run opportunistically at launch when enabled.
- Manual saves still work when automatic sync is off.
- Existing media can be reused across playlists instead of redownloading the same audio repeatedly.
- The offline cache is visible and inspectable from inside the app.

### Negative

- Offline sync adds more background work at launch and during playlist refreshes.
- The app now depends on an additional persistence layer and local media bookkeeping.
- Download failures or unavailable streams can leave partial offline state that needs to be reported clearly.

### Neutral

- Offline storage is additive and does not change the normal online playback path.
- The feature uses the existing YT Music API client for metadata and stream resolution rather than introducing a third-party download stack.
