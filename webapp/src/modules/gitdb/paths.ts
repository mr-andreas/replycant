// Shards manifest and pointer filenames so git tree fanout stays bounded as media count grows.
export const shardName = (name: string): string =>
  name.length < 5 ? name : `${name.slice(0, 2)}/${name.slice(2, 4)}/${name.slice(4)}`;

// Derives the binary pointer path for one manifest record so consumers can look up LFS pointer data
// without needing git tree access or knowledge of the repo layout.
export const deriveBinaryPointerPath = (
  deviceSpace: string,
  apiVersion: string,
  kind: string,
  name: string,
): string => `binary/${deviceSpace}/${apiVersion}/${kind}/${shardName(name)}`;
