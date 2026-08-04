export type PlaybackStrategy = "directPlay" | "directStream" | "transcode";

// Centralizes playback mode selection so the app can switch strategies later without touching callsites.
export const selectPlaybackStrategy = (): PlaybackStrategy => "directPlay";
