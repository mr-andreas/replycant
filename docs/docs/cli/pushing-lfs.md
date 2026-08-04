# Pushing an LFS Repository to a Backup Remote

This tutorial shows how to back up an LFS-enabled Replycant repository to a second Git remote and a second LFS server.

## Important Behavior

`git-replycant pre-push` uploads LFS objects using `lfs.url` from your local Git config.

Changing only the Git remote URL does not change the LFS upload target.

## 1) Add a Second Git Remote

```bash
git remote add backup https://git.backup-host.example.com/my-repo.git
```

You can verify:

```bash
git remote -v
```

## 2) Point LFS to the Backup LFS Server

```bash
git config lfs.url https://lfs.new-host.example.com/my-repo.git/info/lfs
```

You can verify:

```bash
git config --get lfs.url
```

## 3) Push to the Backup Remote

```bash
git push backup main
```

During push, the Replycant pre-push hook runs `git-replycant pre-push` and uploads required `binary/**` objects to the configured `lfs.url` endpoint before refs are updated.

## 4) Restore the Primary LFS Endpoint

After backup push succeeds, restore your primary LFS server URL:

```bash
git config lfs.url https://lfs.primary-host.example.com/my-repo.git/info/lfs
```

## Notes

- This assumes the repo was cloned with `git-replycant clone --lfs-url ...` so the pre-push hook is already installed.
- `lfs.url` is a single local repo setting. If you push to multiple remotes with different LFS servers, switch this value before each push target.
- If your default branch is not `main`, push your active branch name instead.
