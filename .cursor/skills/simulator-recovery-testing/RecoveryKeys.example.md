# RecoveryKeys.md template

Copy this file to `RecoveryKeys.md` at the repo root and replace every
placeholder. `RecoveryKeys.md` is gitignored and must stay that way.

Each `## heading` is one key. Use the heading when referring to a key
in chat.

## small-repo
Description: ~50 photos, fast clone, good for quick UI checks
Server: http://EXAMPLE-HOST.local:8080
Path: ~/tmp/replycant-test-server-50-images
Password: EXAMPLE_PASSWORD
Link: replycant://recover?v=1&d=EXAMPLE_PAYLOAD

## big-repo
Description: 10k images, use for sync and timeline performance work
Server: http://EXAMPLE-HOST.local:9080
Path: ~/tmp/replycant-test-server-10000-images
Password: EXAMPLE_PASSWORD
Link: replycant://recover?v=1&d=EXAMPLE_PAYLOAD

## revoked-key
Description: deleted server-side, expect "Recovery Key Not Registered"
Server: http://EXAMPLE-HOST.local:8080
Path: ~/tmp/replycant-test-server-50-images
Password: EXAMPLE_PASSWORD
Link: replycant://recover?v=1&d=EXAMPLE_PAYLOAD

## remote-shared
Description: shared staging library, read-only, never patch
Server: https://EXAMPLE-HOST.example.com:8080
Path: (remote, no local checkout)
Password: EXAMPLE_PASSWORD
Link: replycant://recover?v=1&d=EXAMPLE_PAYLOAD
