# Chrome extension policy (Linux + macOS, machine-wide)

Allowlist for Chrome extensions. Anything not listed is blocked, so malware
that edits your profile (`Default/Preferences`, `Secure Preferences`, or an
`External Extensions/*.json` drop-in), the usual persistence trick, cannot
add a working extension. The policy files are root-owned, so a process
running as you cannot change them.

## Files

| file | what |
|---|---|
| `extensions.env` | the allowlist: Web Store IDs (shared) + unpacked dirs (per OS) |
| `apply-policy.sh` | generates the policy for the current OS and installs it |

## Usage

```sh
~/cobalt/mp35n/chrome-policy/apply-policy.sh --dry-run   # show, install nothing
~/cobalt/mp35n/chrome-policy/apply-policy.sh             # install (sudo)
~/cobalt/mp35n/chrome-policy/apply-policy.sh --dev       # open briefly to Load unpacked, then lock
~/cobalt/mp35n/chrome-policy/apply-policy.sh --remove    # uninstall (sudo)
~/cobalt/mp35n/chrome-policy/apply-policy.sh --dry-run --os macos   # preview other OS
```

Re-run after editing `extensions.env`, or after moving or renaming an
unpacked extension folder. Then restart Chrome or open `chrome://policy` →
**Reload policies** and check that `ExtensionSettings` and
`ExtensionInstallBlocklist` show **OK**. The "managed by your organization"
banner is expected.

The dry run also lists the extensions Chrome has installed on this machine
and marks each `ALLOWED` or `WILL BE BLOCKED`, so you can see what breaks
before installing.

## Loading unpacked extensions (`--dev`)

While everything is blocked by default (the `*` rule), Chrome disables
**Load unpacked** completely: *"Loading of unpacked extensions is disabled by
the administrator"*, even for allowlisted IDs. Chrome only checks whether
everything is blocked by default; it never consults the allowlist for this.
The same goes for the **Reload** button on an unpacked extension.

`--dev` installs the policy without the `*` rule (listed IDs allowed,
nothing blocked by default), waits while you load or reload your folders in
`chrome://extensions`, then installs the locked policy again, even if you
press Ctrl-C. The allowlist only *permits* extensions; it never installs
them. Chrome cannot auto-install unpacked folders, and Web Store ones only
with `WEBSTORE_MODE=force_installed`.

## extensions.env

```sh
WEBSTORE_1PASSWORD=aeblfdkhhhdcdjpifhhbdiojplfjncoa
UNPACKED_LINUX=~/cobalt/stellite:~/cobalt/stellite/template-theme
UNPACKED_MACOS=~/dev/uBlock:~/dev/cobalt/stellite:~/dev/cobalt/stellite/template-theme
```

- `WEBSTORE_<NAME>=<id>`: any number of them. Web Store IDs come from the
  extension's signing key, so they are **the same on every OS**. Get one
  from the extension's Web Store URL or `chrome://extensions`.
- `WEBSTORE_MODE`: `allowed` (you may install them) or `force_installed`
  (Chrome installs them itself; you cannot remove or disable them).
- `UNPACKED_LINUX` / `UNPACKED_MACOS`: colon-separated folders. The ID is
  computed per machine (see below), so the same extension has a different
  ID on each machine.

The file is parsed, not executed by a shell; only `~` and `$HOME` expand.

## Where it lands

| OS | path | owner |
|---|---|---|
| Linux | `/etc/opt/chrome/policies/managed/mp35n-extensions.json` | `root:root 0644` |
| macOS | `/Library/Managed Preferences/com.google.Chrome.plist` | `root:wheel 0644` |
| macOS | `/Library/Preferences/com.google.Chrome.plist` (legacy domain, still read) | `root:wheel 0644` |

On macOS, user-domain prefs (`defaults write com.google.Chrome …` without
sudo) are not read as policy. If you ever enroll in MDM, remove these and
let the profile own the policy. Optional extra on macOS:
`sudo chflags schg` on the managed copy (`chflags noschg` before updating).

## What the policy contains

- `ExtensionSettings["*"].installation_mode = blocked`, plus `allowed` for
  each listed ID
- `ExtensionInstallBlocklist = ["*"]` + `ExtensionInstallAllowlist` (legacy pair)
- `BlockExternalExtensions = true` (kills the `External Extensions/*.json` drop-in)
- `ProxyMode = direct`: Chrome ignores every proxy (env vars, flags,
  extensions, settings)
- `CAPlatformIntegrationEnabled = false`: Chrome only trusts its built-in
  CAs, not ones added under your user (`~/.pki/nssdb`, login keychain)
- `DnsOverHttpsMode = off`: system DNS only, not a server set in the profile

The last three stop malware from reading your traffic and cookies with its
own proxy or DNS plus its own CA. Burp: use its built-in browser (Proxy →
Open browser); it has its own proxy and CA and is not affected.

Chrome's built-in component extensions (e.g. Web Store Payments) are not
affected.

## How unpacked extension IDs are derived

Chrome IDs are 32 characters from `[a-p]`: the first 32 hex digits of a
SHA-256, each nibble `0–f` mapped to `a–p`. The input is:

- **no `key` in manifest.json** → the folder's absolute path after
  `realpath()` (symlinks resolved). Different home directories mean
  different IDs per machine, and moving or renaming the folder silently
  changes the ID. Re-run the script.
- **`key` in manifest.json** (all Web Store extensions, or one you pin
  yourself) → the decoded public key. Same ID everywhere, regardless of path.

The script handles both and accepts Chrome-style manifests with `//`
comments and trailing commas.

To pin a dev extension so its ID stops depending on the path:

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ~/.keys/stellite.pem
openssl pkey -in ~/.keys/stellite.pem -pubout -outform DER | base64 | tr -d '\n'
```

Paste the output into manifest.json as `"key": "…"`. The ID then changes
**once** to the key-derived value and is the same on every machine.
`chrome.storage` is keyed by ID and won't carry over. Keep the `.pem`
private; the manifest only holds the public half.

## Limits

- Admin/root can change or remove the policy.
- `--load-extension` on the command line is ignored by branded Chrome
  137+; `mp35n` also refuses to hand the cookie key to a Chrome launched
  with it. `DeveloperToolsAvailability = 2` would close it in policy too, but
  also disables DevTools, so it is not set.
- Chromium (`/etc/chromium/policies/managed/`) is not covered; Google Chrome only.
