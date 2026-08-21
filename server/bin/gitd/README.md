# gitd - Git HTTP Server with mTLS Authentication

A secure Git server that uses P-256 ECDSA client certificates for authentication. Keys are stored in the repository itself, making authorization self-contained and auditable.

## Quick Start

**Note:** You'll provide your client certificate during the clone command (step 4). No global configuration is required unless you want it.

### 1. Generate Your Client Key and Certificate

```bash
# Generate P-256 private key
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out client.key

# Create self-signed certificate (valid for 1 year)
openssl req -new -x509 -key client.key -out client.crt -days 365 \
  -subj "/CN=your-username"
```

### 2. Extract Your Public Key

Convert your private key to SSH public key format:

```bash
# Extract public key in SSH format
ssh-keygen -y -f client.key > client.pub
```

Your `client.pub` will look like:
```
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY... your-username
```

### 3. Register Your Key in the Repository

Add your public key to the repository's `pubkeys/` directory:

```bash
# Clone the repo (or get access through an existing admin)
git clone <repository-url>
cd <repository>

# Create pubkeys directory if it doesn't exist
mkdir -p pubkeys

# Copy your public key with your username as the filename
cp client.pub pubkeys/your-username.pub

# Commit and push
git add pubkeys/your-username.pub
git commit -m "Add public key for your-username"
git push origin main
```

**Note:** You'll need initial access to add your first key. The repository owner should add at least one admin key during initial setup.

### 4. Clone with Client Certificate

You need to provide the client certificate during the clone. Choose one of these approaches:

**Option A: Per-Repository (No Global Config)**

Use git's `-c` flag to pass configuration during clone:

```bash
# For self-signed server certificates (testing)
git -c http.sslVerify=false \
    -c http.sslCert=/absolute/path/to/client.crt \
    -c http.sslKey=/absolute/path/to/client.key \
    clone https://gitd.example.com:8443/repo.git

# For trusted server certificates (production)
git -c http.sslCAInfo=/absolute/path/to/gitd-server.crt \
    -c http.sslCert=/absolute/path/to/client.crt \
    -c http.sslKey=/absolute/path/to/client.key \
    clone https://gitd.example.com:8443/repo.git

# Then configure permanently for this repository
cd repo
git config http.sslVerify false  # or http.sslCAInfo for production
git config http.sslCert /absolute/path/to/client.crt
git config http.sslKey /absolute/path/to/client.key
```

**Option B: Global Configuration (All Repositories)**

```bash
# Configure globally once
git config --global http.sslVerify false  # WARNING: testing only
git config --global http.sslCert /absolute/path/to/client.crt
git config --global http.sslKey /absolute/path/to/client.key

# Then clone normally
git clone https://gitd.example.com:8443/repo.git
```

**Option C: Environment Variables**

```bash
# Set variables for the clone command
GIT_SSL_NO_VERIFY=1 \
GIT_SSL_CERT=/absolute/path/to/client.crt \
GIT_SSL_KEY=/absolute/path/to/client.key \
git clone https://gitd.example.com:8443/repo.git

# Configure for future operations
cd repo
git config http.sslVerify false
git config http.sslCert /absolute/path/to/client.crt
git config http.sslKey /absolute/path/to/client.key
```

**Getting the Server Certificate (For Production)**

To trust a self-signed server certificate instead of disabling verification:

```bash
# Download the server certificate
openssl s_client -connect gitd.example.com:8443 -showcerts < /dev/null 2>/dev/null | \
  openssl x509 -outform PEM > gitd-server.crt

# Use it in your git commands
git config http.sslCAInfo /absolute/path/to/gitd-server.crt
```

### 5. Normal Git Operations

```bash
# Once configured, git works normally
cd repo
git pull
git push
```

## Starting the Server

```bash
gitd --repo /path/to/repo.git \
     --addr :8443 \
     --cert /path/to/server.crt \
     --key /path/to/server.key
```

### Server Setup

Generate server certificate:

```bash
# Generate server key (P-256)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out server.key

# Create certificate signing request
openssl req -new -key server.key -out server.csr \
  -subj "/CN=gitd.example.com" \
  -addext "subjectAltName=DNS:gitd.example.com"

# Self-sign (or get signed by CA)
openssl x509 -req -in server.csr -signkey server.key \
  -out server.crt -days 365 -copy_extensions copyall
```

## Repository Structure

```
repo.git/
├── pubkeys/
│   ├── alice.pub
│   ├── bob.pub
│   └── admin.pub
└── (other git content)
```

Each `.pub` file contains a single P-256 ECDSA public key in SSH format.

## Key Management

### Adding a New User

1. User generates their key pair and certificate
2. User shares their `.pub` file with an admin
3. Admin adds the `.pub` file to `pubkeys/username.pub`
4. Admin commits and pushes to main branch
5. The new key is authorized on the next request after the push. The cache TTL is only a refresh bound when the repository has not changed.

### Revoking Access

```bash
# Remove the user's public key
git rm pubkeys/username.pub
git commit -m "Revoke access for username"
git push origin main
```

Access revocation takes effect on the next request after the push. The cache TTL is only a refresh bound when the repository has not changed.

### Key Rotation

```bash
# Generate new key pair
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out client-new.key
openssl req -new -x509 -key client-new.key \
  -out client-new.crt -days 365 -subj "/CN=username"

# Extract new public key
ssh-keygen -y -f client-new.key > pubkeys/username.pub

# Commit the new key
git add pubkeys/username.pub
git commit -m "Rotate key for username"
git push

# Update git config to use new credentials
git config http.sslCert client-new.crt
git config http.sslKey client-new.key

# Verify access with new key
git pull
```

## Security Notes

- **Private Key Protection:** Keep your `client.key` secure (chmod 600)
- **Certificate Verification:** Use proper CA-signed server certificates in production (not self-signed)
- **Absolute Paths:** Git requires absolute paths for `http.sslCert`, `http.sslKey`, and `http.sslCAInfo`
- **Key Storage:** Consider using `git-credential` helpers for key management
- **Audit Trail:** All key additions/removals are tracked in Git history
- **SSL Verification:** Never disable `http.sslVerify` in production environments

## Troubleshooting

### SSL Certificate Verification Error

If you see errors like `SSL certificate problem: self signed certificate`:

```bash
# Quick fix: Disable SSL verification
git config --global http.sslVerify false

# Or: Trust the specific server certificate
git config --global http.sslCAInfo /path/to/gitd-server.crt

# Or: Use environment variable for single command
GIT_SSL_NO_VERIFY=1 git clone https://gitd.example.com:8443/repo.git
```

### Authentication Failed

```bash
# Check your certificate is valid
openssl x509 -in client.crt -text -noout

# Verify public key matches private key
ssh-keygen -y -f client.key

# Ensure your key is in the repository
git log --all -- pubkeys/your-username.pub

# Check that client cert/key are configured
git config --get http.sslCert
git config --get http.sslKey
```

### Connection Refused

```bash
# Test server connectivity (note: -k disables cert verification for testing)
curl -k --cert client.crt --key client.key \
  https://gitd.example.com:8443/info/refs

# Check if server is running
netstat -tlnp | grep 8443
```

### Wrong Branch

gitd reads keys from the `main` branch. Ensure your key is committed to `main`:

```bash
git checkout main
git pull origin main
ls pubkeys/
```

## Advanced Usage

### Multiple Repositories with Different Certificates

**Option A: Per-Repository Configuration (Recommended)**

Each repository stores its own configuration in `.git/config`:

```bash
# Clone first repo with cert A
git -c http.sslVerify=false \
    -c http.sslCert=/path/to/cert-A.crt \
    -c http.sslKey=/path/to/cert-A.key \
    clone https://gitd.example.com:8443/repo-A.git

cd repo-A
git config http.sslVerify false
git config http.sslCert /path/to/cert-A.crt
git config http.sslKey /path/to/cert-A.key

# Clone second repo with cert B
cd ..
git -c http.sslVerify=false \
    -c http.sslCert=/path/to/cert-B.crt \
    -c http.sslKey=/path/to/cert-B.key \
    clone https://gitd.example.com:8443/repo-B.git

cd repo-B
git config http.sslVerify false
git config http.sslCert /path/to/cert-B.crt
git config http.sslKey /path/to/cert-B.key
```

**Option B: Git Config Conditionals (Global Config with Per-Directory Override)**

```bash
# In ~/.gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work

[includeIf "gitdir:~/personal/"]
    path = ~/.gitconfig-personal

# In ~/.gitconfig-work
[http]
    sslCert = /absolute/path/to/work-client.crt
    sslKey = /absolute/path/to/work-client.key
    sslVerify = false

# In ~/.gitconfig-personal
[http]
    sslCert = /absolute/path/to/personal-client.crt
    sslKey = /absolute/path/to/personal-client.key
    sslVerify = false
```

### Automating Key Generation

```bash
#!/bin/bash
USERNAME=$1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out ${USERNAME}.key
openssl req -new -x509 -key ${USERNAME}.key -out ${USERNAME}.crt \
  -days 365 -subj "/CN=${USERNAME}"
ssh-keygen -y -f ${USERNAME}.key > ${USERNAME}.pub
echo "Created ${USERNAME}.key, ${USERNAME}.crt, ${USERNAME}.pub"
```

### Helper Script for Cloning

Create a wrapper script to simplify per-repository cloning:

```bash
#!/bin/bash
# gitd-clone.sh - Clone a gitd repository with client certificate

CERT_DIR="$HOME/.gitd"
URL="$1"

if [ -z "$URL" ]; then
    echo "Usage: $0 <repository-url>"
    exit 1
fi

# Clone with client certificate
git -c http.sslVerify=false \
    -c http.sslCert="$CERT_DIR/client.crt" \
    -c http.sslKey="$CERT_DIR/client.key" \
    clone "$URL"

# Extract repo name from URL
REPO_NAME=$(basename "$URL" .git)

# Configure the repository
cd "$REPO_NAME" || exit 1
git config http.sslVerify false
git config http.sslCert "$CERT_DIR/client.crt"
git config http.sslKey "$CERT_DIR/client.key"

echo "Repository cloned and configured successfully"
```

Usage:
```bash
chmod +x gitd-clone.sh
./gitd-clone.sh https://gitd.example.com:8443/repo.git
```
