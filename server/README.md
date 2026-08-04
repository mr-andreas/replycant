# Replycant

A secure, self-contained Git-based storage system for device-owned data.

## gitd - Authentication & Access Control

This repository is served by `gitd`, a Git HTTP server with mTLS authentication using P-256 ECDSA client certificates. Authorization keys are stored in the repository itself at `pubkeys/`, making access control self-contained and auditable through Git history.

See [bin/gitd/README.md](bin/gitd/README.md) for detailed setup instructions.

### Bootstrap Mode for Empty Repositories

When working with a completely empty repository (no branches at all), gitd operates in **bootstrap mode**:

- Any valid P-256 client certificate can push to the repository
- This solves the chicken-and-egg problem: you can't push keys without access, but you need keys to get access
- After the first push that creates any branch, normal key-based authentication immediately resumes
- Only keys in `pubkeys/` on the main branch will be authorized

**Note:** A repository is only considered empty if it has no branches at all. If any branch exists (even if it's not "main"), normal authentication applies.

**To initialize a new repository:**

```bash
# Clone the empty repository
git clone https://gitd-server/repo.git
cd repo

# Add your public key
mkdir pubkeys
cp your-username.pub pubkeys/

# Push to main (bootstrap mode allows this)
git add pubkeys/your-username.pub
git commit -m "Initial commit: add authorized key"
git push origin main
```

After this initial push, only authorized keys can access the repository.

**Security Note:** The first user to push gains control. Initialize repositories in a controlled environment.

## Repository layout

## Device space

The root of the repository may only contain directories. Each directory is the
root represents a _device space_. A device space is owned by a single device,
such as a webapp or mobile app. At the root of the device space, there is public
key stored as _devicekey.pub_. All commits to the device space must be signed by
this key. The private part of the key should be stored in the owning app, but
not be commited to the repository. This guarantees that the owning app is the
only party who may ever commit to the device space.

Manifests are stored 

## Serialization

YAML is used over JSON, protobuf etc as it makes a `git diff` much easier to
read when debugging a repository.

# Encryption

Binary media files are encrypted. Should we use identical IV for identical
files? This would allow for git-lfs to dedup the binary files. It should be
safe. An attacker with a copy of the same unencrypted file will not be able to
prove that the victim has ownership of this file, as the encryption key is not
known.

https://stackoverflow.com/questions/58177786/get-the-current-pushed-tag-in-github-actions
https://crypto.stackexchange.com/questions/729/is-convergent-encryption-really-secure
