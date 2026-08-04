// Reads hash params through one path so hash consumers stay consistent.
export const readHashParams = (): URLSearchParams => {
  if (!window.location.hash.startsWith("#")) return new URLSearchParams();
  return new URLSearchParams(window.location.hash.slice(1));
};

// Writes one hash param without creating a browser history entry.
export const writeHashParam = (key: string, value: string | null): void => {
  const params = readHashParams();
  if (value === null) {
    params.delete(key);
  } else {
    params.set(key, value);
  }
  history.replaceState(null, "", params.size > 0 ? `#${params.toString()}` : "#");
};
