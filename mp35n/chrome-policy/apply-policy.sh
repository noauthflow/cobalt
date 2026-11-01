#!/usr/bin/env bash
# ~/cobalt/mp35n/chrome-policy/apply-policy.sh
# Install a machine-wide Chrome extension allowlist on Linux or macOS,
# generated from extensions.env. Everything not listed is blocked.
# Also locks the network: no proxy, no user-added CAs, no custom DNS.
#
#   apply-policy.sh                       generate, show, install (sudo)
#   apply-policy.sh --dev                 open briefly to "Load unpacked", then lock
#   apply-policy.sh --dry-run             generate and show, install nothing
#   apply-policy.sh --dry-run --os macos  preview the other OS's policy
#   apply-policy.sh --remove              uninstall the policy (sudo)
#
# Chrome disables "Load unpacked" entirely while everything is blocked by
# default (the "*" rule), allowlist or not. --dev installs the policy
# without the "*" rule, waits while you load your unpacked folders, then
# installs the locked policy again. Loaded extensions whose IDs are on the
# allowlist keep working under the locked policy.
#
# Linux: /etc/opt/chrome/policies/managed/mp35n-extensions.json (root 0644)
# macOS: /Library/Managed Preferences/com.google.Chrome.plist and
#        /Library/Preferences/com.google.Chrome.plist (root:wheel 0644)
#
# Only the final copy runs as root; parsing and generation run as you.
# Portable: bash 3.2 (macOS) and python3 >= 3.8.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HERE/extensions.env"

MODE=apply
OS=
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) MODE=dry ;;
		--dev)     MODE=dev ;;
		--remove)  MODE=remove ;;
		--os)      shift; OS="${1:-}" ;;
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ -z "$OS" ]; then
	case "$(uname -s)" in
		Linux)  OS=linux ;;
		Darwin) OS=macos ;;
		*) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
	esac
elif [ "$MODE" != dry ]; then
	echo "--os is only for --dry-run previews" >&2; exit 2
fi
case "$OS" in linux|macos) ;; *) echo "--os must be linux or macos" >&2; exit 2 ;; esac

LINUX_DIR="/etc/opt/chrome/policies/managed"
LINUX_DEST="$LINUX_DIR/mp35n-extensions.json"
MAC_MANAGED="/Library/Managed Preferences/com.google.Chrome.plist"
MAC_LEGACY="/Library/Preferences/com.google.Chrome.plist"

if [ "$MODE" = remove ]; then
	if [ "$OS" = linux ]; then
		sudo rm -f "$LINUX_DEST"
		echo "removed $LINUX_DEST"
	else
		sudo rm -f "$MAC_MANAGED" "$MAC_LEGACY"
		sudo killall cfprefsd 2>/dev/null || true
		echo "removed $MAC_MANAGED and $MAC_LEGACY"
	fi
	echo "Restart Chrome (or chrome://policy -> Reload policies)."
	exit 0
fi

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ENV_FILE" "$OS" "$TMP" <<'PY'
import base64, glob, hashlib, json, os, plistlib, re, sys

env_file, target_os, out_dir = sys.argv[1:4]

def expand(s):
    return os.path.expanduser(os.path.expandvars(s.strip()))

def read_env(path):
    vals = {}
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            sys.exit(f"{path}:{n}: expected KEY=VALUE")
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        vals[k.strip()] = v
    return vals

def chrome_id(data):
    """Chrome extension ID: first 128 bits of sha256, nibbles 0-f -> a-p."""
    return "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(data).hexdigest()[:32])

def strip_jsonc(text):
    """Chrome accepts // and /* */ comments and trailing commas in
    manifest.json; strict JSON does not."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True; out.append(c); i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

def unpacked_id(path):
    """(id, how, problem). Chrome resolves the directory with realpath()
    before hashing it; a manifest "key" overrides the path."""
    real = os.path.realpath(path)
    manifest = os.path.join(real, "manifest.json")
    if not os.path.isdir(real):
        return chrome_id(real.encode()), "path", "directory missing"
    if not os.path.isfile(manifest):
        return chrome_id(real.encode()), "path", "no manifest.json"
    try:
        m = json.loads(strip_jsonc(open(manifest, encoding="utf-8").read()))
    except Exception as e:
        return chrome_id(real.encode()), "path", f"manifest unreadable: {e}"
    if m.get("key"):
        try:
            return chrome_id(base64.b64decode(m["key"])), "manifest key", None
        except Exception as e:
            return None, "manifest key", f"bad key: {e}"
    return chrome_id(real.encode()), "path", None

env = read_env(env_file)
webstore = [(k[len("WEBSTORE_"):].lower(), v) for k, v in env.items()
            if k.startswith("WEBSTORE_") and k != "WEBSTORE_MODE" and v]
for name, eid in webstore:
    if not re.fullmatch(r"[a-p]{32}", eid):
        sys.exit(f"WEBSTORE_{name.upper()}={eid!r} is not a Chrome extension ID")

key = "UNPACKED_" + target_os.upper()
dirs = [expand(p) for p in env.get(key, "").split(":") if p.strip()]

allowed = []  # (id, label)
print(f"--- allowlist for {target_os} (from {os.path.basename(env_file)})")
if (target_os == "linux") != sys.platform.startswith("linux"):
    print("  (preview: ~ expands to THIS machine's home, so unpacked IDs below\n"
          "   differ from what the other machine will compute for itself)")
for name, eid in webstore:
    allowed.append((eid, name))
    print(f"  {eid}  web store     {name}")
for d in dirs:
    eid, how, problem = unpacked_id(d)
    if eid is None:
        print(f"  ERROR {d}: {problem}"); sys.exit(1)
    allowed.append((eid, d))
    note = f"   <-- WARNING: {problem}" if problem else ""
    print(f"  {eid}  unpacked/{how:4}  {d}{note}")

ids = []
for eid, _ in allowed:
    if eid not in ids:
        ids.append(eid)

store_mode = env.get("WEBSTORE_MODE", "allowed")
if store_mode not in ("allowed", "force_installed"):
    sys.exit(f"WEBSTORE_MODE={store_mode!r}: use allowed or force_installed")
store_ids = {eid for _, eid in webstore}

def build(locked):
    """locked: everything else blocked ("*"), which also disables Load
    unpacked. open: only the listed IDs get settings; nothing is blocked by
    default, so Load unpacked works."""
    settings = {"*": {"installation_mode": "blocked"}} if locked else {}
    for eid in ids:
        if eid in store_ids and store_mode == "force_installed":
            settings[eid] = {"installation_mode": "force_installed",
                             "update_url": "https://clients2.google.com/service/update2/crx"}
        else:
            settings[eid] = {"installation_mode": "allowed"}
    policy = {"ExtensionSettings": settings}
    if locked:
        policy["ExtensionInstallBlocklist"] = ["*"]
        policy["ExtensionInstallAllowlist"] = ids
    # kills the External Extensions/*.json drop-in vector
    policy["BlockExternalExtensions"] = True
    # Network lock: no proxy, no user-added CAs, no profile-set DNS server.
    # Together these stop a same-user process from reading traffic (and
    # cookies) through a proxy or DNS redirect plus its own CA. For Burp,
    # use its built-in browser.
    policy["ProxyMode"] = "direct"
    policy["CAPlatformIntegrationEnabled"] = False
    policy["DnsOverHttpsMode"] = "off"
    return policy

for name, locked in (("policy", True), ("policy-open", False)):
    if target_os == "linux":
        with open(os.path.join(out_dir, name + ".json"), "w") as f:
            json.dump(build(locked), f, indent=2); f.write("\n")
    else:
        with open(os.path.join(out_dir, name + ".plist"), "wb") as f:
            plistlib.dump(build(locked), f)

# Compare against what this machine's Chrome has installed.
if (target_os == "linux") == sys.platform.startswith("linux"):
    base = os.path.expanduser("~/.config/google-chrome" if target_os == "linux"
                              else "~/Library/Application Support/Google/Chrome")
    # Locations 5 (component) and 10 (external component) are built into
    # Chrome and not subject to this policy.
    loc = {1: "webstore", 2: "external", 3: "external", 4: "unpacked",
           6: "external", 7: "policy", 8: "cmdline", 9: "policy"}
    found = {}
    for f in glob.glob(base + "/*/Secure Preferences") + glob.glob(base + "/*/Preferences"):
        try:
            prefs = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        profile = os.path.basename(os.path.dirname(f))
        for eid, v in prefs.get("extensions", {}).get("settings", {}).items():
            if isinstance(v, dict) and v.get("location") in loc:
                name = (v.get("manifest") or {}).get("name") or v.get("path", "")
                found[(profile, eid)] = (loc[v["location"]], name)
    print(f"--- installed in {base}")
    if not found:
        print("  (no user-installed extensions)")
    for (profile, eid), (where, name) in sorted(found.items()):
        verdict = "ALLOWED" if eid in ids else "WILL BE BLOCKED"
        print(f"  {verdict:16} {eid}  {where:9} {profile}  {name}")
PY

if [ "$MODE" = dry ]; then
	echo "--- generated policy (not installed)"
	if [ "$OS" = linux ]; then cat "$TMP/policy.json"; else cat "$TMP/policy.plist"; fi
	exit 0
fi

# install_policy <name>: copy $TMP/<name>.{json,plist} into place as root
install_policy() {
	if [ "$OS" = linux ]; then
		sudo install -d -m 0755 -o root -g root "$LINUX_DIR"
		sudo install -m 0644 -o root -g root "$TMP/$1.json" "$LINUX_DEST"
		ls -l "$LINUX_DEST"
	else
		plutil -lint "$TMP/$1.plist" >/dev/null
		sudo mkdir -p "/Library/Managed Preferences"
		sudo install -m 0644 -o root -g wheel "$TMP/$1.plist" "$MAC_MANAGED"
		sudo install -m 0644 -o root -g wheel "$TMP/$1.plist" "$MAC_LEGACY"
		# flush the preferences cache, else Chrome may read stale values
		sudo killall cfprefsd 2>/dev/null || true
		ls -l "$MAC_MANAGED" "$MAC_LEGACY"
	fi
}

if [ "$MODE" = dev ]; then
	# Whatever happens (Enter, Ctrl-C, error), end in the locked state.
	lock_again() {
		echo
		echo "--- locking again"
		install_policy policy
		rm -rf "$TMP"
		echo "Reload policies again in chrome://policy (or restart Chrome)."
		echo "Check:  $0 --dry-run   (your unpacked extensions should say ALLOWED)"
	}
	trap lock_again EXIT
	trap 'exit 130' INT TERM
	echo "--- OPEN policy: extensions are NOT restricted until this finishes"
	install_policy policy-open
	echo
	echo "1. chrome://policy -> Reload policies"
	echo "2. chrome://extensions -> Load unpacked -> pick the folders listed above"
	read -r -p "3. press Enter to lock again " _ || true
	exit 0
fi

echo "--- installed"
install_policy policy
echo
echo "Restart Chrome, or open chrome://policy -> Reload policies, and check"
echo "that ExtensionSettings / ExtensionInstallBlocklist show status OK."
echo "To load an unpacked extension: $0 --dev"
