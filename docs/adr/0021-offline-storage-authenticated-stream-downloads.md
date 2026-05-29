# ADR 0021: Offline Storage Uses Authenticated Direct Stream Downloads

## Status

Accepted

## Context

The initial offline storage implementation used a WebKit audio capture path to avoid relying on stream URL extraction. In practice, that path was fragile for premium playback and failed when WebKit did not surface an audio source in time.

`yt-dlp` resolves YouTube Music downloads by working from authenticated `player` responses, selecting audio formats directly, and using the account cookies to authorize the download request. That approach is more predictable than trying to capture decoded audio from the playback surface.

## Decision

Kaset's offline storage now uses authenticated `player` responses as the primary source of truth for downloadable audio.

- Fetch the raw `player` response through `YTMusicClient`.
- Select the best audio format from `streamingData`.
- Resolve `url` and simple `signatureCipher` variants into a downloadable URL.
- Download the media with the app's authenticated YT Music session.

The WebKit capture recorder remains in the tree for historical reference, but it is no longer the active offline save path.

## Consequences

- Offline saving is aligned with the way `yt-dlp` handles authenticated extraction.
- Premium accounts can reuse the session cookies already stored by the app.
- The implementation is simpler to reason about than a WebKit capture pipeline.
- The direct-download path still depends on YouTube returning a usable audio format in `streamingData`.

## Alternatives Considered

- WebKit audio capture: rejected because it depends on playback timing and UI/audio-source availability.
- External `yt-dlp` subprocess: rejected because it would add a Python/runtime dependency to the app.

