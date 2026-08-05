#!/bin/bash
#
# deploy.sh — three-attempt Ansible runner with hybrid retry scope.
#
# Attempt 1: full site.yml against every host
# Attempt 2: --limit @retry-file (failed hosts only) if a retry file exists
# Attempt 3: full playbook again (safety net if retry-scoped attempt didn't cover
#            a cross-host dependency)
#
# --forks 40 (up from Ansible default 5) so full sweeps parallelize
# aggressively across the ~30-host PowerPlant fleet. Controller has enough
# headroom (2-4 vCPU on the SimSpace VM); 40 concurrent workers is a
# comfortable middle ground and matches the airfield-range deploy.sh.

# site.yml = arbitr_pp_playbook.yaml (range baseline) followed by the six
# Security Onion phases. Run a single phase directly during development —
# re-running the full range playbook to test an SO change is slow.
PLAYBOOK="site.yml"
RETRY_FILE="retry/$PLAYBOOK.retry"
MAX_ATTEMPTS=3
FORKS=40

# --- Speed knobs -------------------------------------------------------------
# Trims 5-10 minutes off a full-fleet run vs Ansible defaults.
#   ANSIBLE_PIPELINING=True     — one SSH exec per task on Linux instead of
#                                 three (open/exec/close). Safe on SimSpace
#                                 images (requiretty is off by default).
#                                 No effect on Windows/WinRM.
#   ANSIBLE_GATHERING=smart     — Gather facts once per host per run; skip
#                                 subsequent plays that also gather. Ansible
#                                 remembers what it already gathered.
#   ANSIBLE_CACHE_PLUGIN=jsonfile + fact_cache dir + 24h TTL — persist facts
#                                 across runs, so back-to-back deploys don't
#                                 re-gather on unchanged hosts.
export ANSIBLE_PIPELINING=True
export ANSIBLE_GATHERING=smart
export ANSIBLE_CACHE_PLUGIN=jsonfile
export ANSIBLE_CACHE_PLUGIN_CONNECTION="$HOME/.ansible/fact_cache"
export ANSIBLE_CACHE_PLUGIN_TIMEOUT=86400
mkdir -p "$ANSIBLE_CACHE_PLUGIN_CONNECTION"

# --- Unattended prerequisites -------------------------------------------------
# This deploy is driven by the range BLUEPRINT: the platform spins the images,
# pulls the tarball from GitHub and extracts it, then runs this script. Nobody
# is at a keyboard. Anything that would previously have been a "now run these
# three commands by hand" instruction has to be done here instead.
#
# Two things the extraction leaves wrong:
#   * /etc/ansible/retry — the tarball extracts as root, so the ansible user
#     cannot write retry files. Previously every failed run printed
#     "Could not create retry file ... Permission denied" and attempt 2 lost
#     its retry-file scope, silently degrading to a full sweep.
#   * /home/simspace/.vault_pass — the password file and its value are placed
#     by the platform, but not necessarily with ownership and mode the ansible
#     user can read. 0600 root:root is unreadable to simspace, and every
#     vaulted variable in the repo resolves through it.
#
# `sudo -n` throughout: non-interactive, so a sudo password prompt FAILS
# immediately rather than hanging a headless deploy forever waiting on stdin.
ANSIBLE_OWNER="${ANSIBLE_OWNER:-simspace}"
VAULT_PASS_FILE="${VAULT_PASS_FILE:-/home/simspace/.vault_pass}"
RETRY_DIR="${RETRY_DIR:-/etc/ansible/retry}"

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo -n "$@"
	fi
}

# Fix only what is actually WRONG. Testing the behaviour we need -- can the
# deploy account write the retry dir, can it read the vault password -- rather
# than comparing ownership metadata, keeps the common case silent and avoids
# five spurious "sudo: a password is required" warnings on every clean run.
# It is also the right assertion: 0600 root:root is broken, but so is any
# other combination that leaves the file unreadable.
echo "=== Checking prerequisites the platform is responsible for ==="

# retry dir — the tarball extracts as root, so this is root-owned and the
# ansible user cannot write retry files. Without it a failed attempt 1 loses
# its retry-file scope and attempt 2 silently degrades to a full sweep.
if [ ! -d "$RETRY_DIR" ] || [ ! -w "$RETRY_DIR" ]; then
	echo "  $RETRY_DIR not writable by $(id -un) — correcting"
	as_root mkdir -p "$RETRY_DIR" 2>/dev/null \
		|| echo "  WARN: could not create $RETRY_DIR"
	as_root chown -R "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$RETRY_DIR" 2>/dev/null \
		|| echo "  WARN: could not chown $RETRY_DIR"
	as_root chmod 0755 "$RETRY_DIR" 2>/dev/null \
		|| echo "  WARN: could not chmod $RETRY_DIR"
	[ -w "$RETRY_DIR" ] \
		&& echo "  $RETRY_DIR now writable" \
		|| echo "  WARN: $RETRY_DIR still not writable — retry scoping will be lost, deploy continues"
else
	echo "  $RETRY_DIR writable"
fi

# vault password file — placed by the blueprint, but not necessarily with
# ownership and mode this account can read.
if [ -f "$VAULT_PASS_FILE" ] && ! head -c1 "$VAULT_PASS_FILE" >/dev/null 2>&1; then
	echo "  $VAULT_PASS_FILE not readable by $(id -un) — correcting"
	as_root chown "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$VAULT_PASS_FILE" 2>/dev/null \
		|| echo "  WARN: could not chown $VAULT_PASS_FILE"
	as_root chmod 0600 "$VAULT_PASS_FILE" 2>/dev/null \
		|| echo "  WARN: could not chmod $VAULT_PASS_FILE"
elif [ -f "$VAULT_PASS_FILE" ]; then
	# Readable already. Still enforce 0600 -- a world-readable vault password
	# is a finding even though the deploy would work fine.
	as_root chmod 0600 "$VAULT_PASS_FILE" 2>/dev/null || true
	echo "  $VAULT_PASS_FILE readable"
fi

# --- Vault guard -------------------------------------------------------------
# Refuse to deploy if the vault is missing or plaintext. Written FAIL-CLOSED on
# purpose: the equivalent guard in so-ansible was
#   if [ -f <path> ] && ! head -1 <path> | grep -q '^$ANSIBLE_VAULT'
# and a MISSING file short-circuited the whole test to false, so it passed on
# every run and had never once fired. A plaintext vault would have shipped
# silently. Two separate checks here, both fatal.
VAULT_FILE="group_vars/all/vault.yml"

if [ ! -f "$VAULT_FILE" ]; then
	echo "ERROR: $VAULT_FILE not found. Refusing to deploy."
	echo "       Every credential in this repo resolves through it."
	exit 1
fi

if ! head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
	echo "ERROR: $VAULT_FILE is plaintext. Refusing to deploy."
	echo "       Re-encrypt: ansible-vault encrypt $VAULT_FILE"
	exit 1
fi

if [ ! -f "$VAULT_PASS_FILE" ]; then
	echo "ERROR: $VAULT_PASS_FILE not found. Refusing to deploy."
	echo "       The range blueprint is responsible for placing this file and"
	echo "       its value on the controller; it does NOT persist across"
	echo "       spin-ups. If the blueprint is not doing that, fix it there —"
	echo "       a hands-off deploy cannot prompt for it."
	exit 1
fi

# READABILITY, not existence. The chown/chmod above may have failed (sudo -n
# is deliberately non-interactive), and a file that exists but cannot be read
# fails later as a confusing vault decrypt error on the first vaulted variable
# rather than here. Test what actually matters: can THIS process read it?
if ! head -c1 "$VAULT_PASS_FILE" >/dev/null 2>&1; then
	echo "ERROR: $VAULT_PASS_FILE exists but is not readable by $(id -un)."
	echo "       Ownership/mode could not be corrected — check that the"
	echo "       deploy account has passwordless sudo, or have the blueprint"
	echo "       place the file as $ANSIBLE_OWNER:$ANSIBLE_OWNER mode 0600."
	ls -l "$VAULT_PASS_FILE" 2>&1 | sed 's/^/       /'
	exit 1
fi

# And that it is not empty -- an empty password file decrypts nothing and the
# error surfaces far from here.
if [ ! -s "$VAULT_PASS_FILE" ]; then
	echo "ERROR: $VAULT_PASS_FILE is empty. Refusing to deploy."
	exit 1
fi

# --- Install Galaxy collections (idempotent — skips already-installed ones) ---
# Required for the pfsensible.core collection that drives the pp-ot-firewall
# pfSense play. Pulled through the corp proxy because the Ansible VM doesn't
# have direct internet. Failure here doesn't abort the deploy — ansible-playbook
# will surface a clear "collection not found" error if anything's actually missing.
#
# NOTE: a `sleep 120` here was removed 2026-07-02 in a speed pass, reasoning
# that the retry loop already handles a VM that is not ready yet. RESTORED
# 2026-08-05 at 180s, because that reasoning did not survive contact with a
# fresh range: the first two attempts of a from-scratch deploy both failed on
# hosts that had not finished booting, and "the retry loop handles it" meant
# paying for two full multi-hour sweeps to discover that. A three-minute wait
# is cheap against a ~5-hour deploy; two wasted passes are not.
#
# BOOT_DELAY is overridable so iterative deploys need not pay it -- which was
# the legitimate half of the 2026-07-02 argument:
#     BOOT_DELAY=0 ./deploy.sh
echo "=== Checking for Ansible Galaxy collections ==="

if [ -f requirements.yml ]; then
	echo "=== Installing/refreshing Ansible Galaxy collections ==="
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml \
		|| echo "WARN: galaxy install returned non-zero; continuing"
fi

# --- Let a freshly provisioned range finish booting --------------------------
BOOT_DELAY="${BOOT_DELAY:-180}"
if [ "$BOOT_DELAY" -gt 0 ]; then
	echo "=== Waiting ${BOOT_DELAY}s for range VMs to finish booting ==="
	echo "    (override with BOOT_DELAY=0 ./deploy.sh on an already-up range)"
	sleep "$BOOT_DELAY"
fi

for i in $(seq 1 $MAX_ATTEMPTS); do
	# Attempt 2 gets the retry-file scope IF the previous attempt actually
	# produced one. If the file is missing (e.g. deploy exited on a global
	# error before writing it), fall through to the full sweep.
	if [ $i -eq 2 ] && [ -f "$RETRY_FILE" ]; then
		echo "=== Attempt $i (retry-file scope — failed hosts only) ==="
		if ansible-playbook $PLAYBOOK --forks $FORKS --limit @"$RETRY_FILE" "$@"; then
			echo "Success on attempt $i (retry scope)"
			break
		fi
	else
		echo "=== Attempt $i (full sweep) ==="
		if ansible-playbook $PLAYBOOK --forks $FORKS "$@"; then
			echo "Success on attempt $i"
			break
		fi
	fi

	echo "Attempt $i failed"

	# Preserve the retry file between attempts 1 and 2 (that's how attempt 2
	# knows which hosts to target). Clear it between 2 and 3 so a stale
	# retry list can't accidentally scope attempt 3 the same way attempt 2
	# was scoped.
	if [ $i -ge 2 ]; then
		rm -f "$RETRY_FILE"
	fi

	if [ $i -eq $MAX_ATTEMPTS ]; then
		echo "ERROR: Playbook failed after $MAX_ATTEMPTS attempts"
		exit 1
	fi
done
