// Defines the minimal fs.promises surface gitdb needs so browser and Electron
// runtimes can provide different backends without changing sync logic.
export interface FsClient {
  promises: {
    readFile(path: string, options?: unknown): Promise<unknown>;
    writeFile(path: string, data: unknown, options?: unknown): Promise<void>;
    unlink(path: string): Promise<void>;
    readdir(path: string, options?: unknown): Promise<unknown>;
    mkdir(path: string, options?: unknown): Promise<void>;
    rmdir(path: string, options?: unknown): Promise<void>;
    stat(path: string, options?: unknown): Promise<unknown>;
    lstat(path: string, options?: unknown): Promise<unknown>;
    readlink?(path: string): Promise<string>;
    symlink?(target: string, path: string): Promise<void>;
  };
}
