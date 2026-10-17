import type { Session, WebRequestFilter } from "electron";

// The public tile server blocks clients that identify as a browser. The
// desktop shell names itself on those requests only.
export const OSM_TILE_URL_FILTER = "https://tile.openstreetmap.org/*";

const registeredSessions = new WeakSet<Session>();

export const mapTileUserAgent = (version: string): string =>
  `Replycant/${version} (+https://github.com/mr-andreas/replycant)`;

export const registerMapTileRequests = (electronSession: Session, version: string): void => {
  if (registeredSessions.has(electronSession)) return;
  registeredSessions.add(electronSession);
  const filter: WebRequestFilter = { urls: [OSM_TILE_URL_FILTER] };
  electronSession.webRequest.onBeforeSendHeaders(filter, (details, callback) => {
    const requestHeaders = {
      ...details.requestHeaders,
      "User-Agent": mapTileUserAgent(version),
    };
    callback({ requestHeaders });
  });
};
