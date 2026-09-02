#!/bin/bash
#
# deploy.sh — three-attempt Ansible runner with hybrid retry scope.
#
# Attempt 1: full arbitr_pp_playbook.yaml against every host
# Attempt 2: --limit @retry-file (failed hosts only) if a retry file exists
# Attempt 3: full playbook again (safety net if retry-scoped attempt didn't cover
#            a cross-host dependency)
#
# --forks 52 (up from Ansible default 5) so full sweeps parallelize across the
# PowerPlant fleet without splitting any play into batches.
#
# 52 SPECIFICALLY, raised from 40 on 2026-08-20. Forks below the largest play
# target silently serialise its tail: with 40, the 45-host [windows] plays ran
# in two waves, which cost an extra init_wait_delay (15s) on the second and
# staggered every Windows sweep for no reason.
#
# 52 is the largest group any play targets. Measured, not guessed:
#
#     52  hosts: windows,linux      <- the `common` role, the heaviest sweep
#     47  hosts: splunk-forwarder
#     45  hosts: windows
#     42  hosts: sysmon
#     40  hosts: members
#
# 45 would have covered [windows] and still split the other two.
#
# TRADEOFF: each fork is a separate Python process, so this is a memory
# question rather than a CPU one -- the workers are almost always blocked on
# WinRM/SSH I/O, not computing. 40 forks already ran comfortably on this
# controller; 52 is ~30% more resident memory. If the controller starts
# swapping during a full sweep, drop this rather than assuming the deploy is
# slow for another reason.
#
# If the fleet grows, re-measure rather than incrementing: a play target one
# host above FORKS strands a single host running alone at the end of it.
PLAYBOOK="arbitr_pp_playbook.yaml"
RETRY_FILE="retry/$PLAYBOOK.retry"
MAX_ATTEMPTS=3
FORKS=52

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
# --- Elapsed-time accounting -------------------------------------------------
# Reported through an EXIT trap rather than at the bottom of the script, because
# the bottom is only reached on two of the three ways this ends. The third --
# someone killing a run that has stopped making progress -- is the one where
# knowing the elapsed time matters most, and it never reaches the last line.
#
# Two clocks, because they answer different questions:
#   ansible elapsed   what was asked for: first attempt start -> finish
#   pre-ansible       galaxy install + BOOT_DELAY, ~3 min of the wall clock that
#                     is not Ansible and should not be blamed on it
SCRIPT_START=$(date +%s)
ANSIBLE_START=""
DEPLOY_RESULT="interrupted before Ansible started"

fmt_elapsed() {
	local s=$1
	printf '%dh %02dm %02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

report_elapsed() {
	rc=$?
	now=$(date +%s)
	echo
	echo "================== deploy.sh timing =================="
	if [ -n "$ANSIBLE_START" ]; then
		printf '  ansible elapsed  : %s\n' "$(fmt_elapsed $((now - ANSIBLE_START)))"
		printf '  pre-ansible      : %s   (galaxy + BOOT_DELAY)\n' \
			"$(fmt_elapsed $((ANSIBLE_START - SCRIPT_START)))"
	else
		printf '  ansible elapsed  : never started\n'
	fi
	printf '  total wall clock : %s\n' "$(fmt_elapsed $((now - SCRIPT_START)))"
	printf '  outcome          : %s\n' "$DEPLOY_RESULT"
	echo "====================================================="
	exit $rc
}
trap report_elapsed EXIT
trap 'DEPLOY_RESULT="INTERRUPTED by signal"; exit 130' INT TERM

# --- Prerequisites the platform is responsible for ---------------------------
# Ported from ss-pp-so 2026-09-01. A blueprint-driven deploy extracts the
# tarball as root and then runs this script unattended, so anything that would
# otherwise be a "now run these commands by hand" instruction has to happen
# here.
#
# /etc/ansible/retry is the one that bites: extracted root-owned, so the
# ansible user cannot write retry files. Every failed run printed "Could not
# create retry file ... Permission denied" and attempt 2 silently lost its
# retry-file scope, degrading to a full sweep -- slower, and it hides which
# hosts actually failed.


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

# ASSERT THE END STATE UNCONDITIONALLY. An earlier version skipped the chown
# when the path merely looked fine for the CURRENT user -- and a
# blueprint-driven deploy runs as root, for whom everything is writable. The
# chown was therefore skipped on exactly the run it was written for, leaving
# /etc/ansible/retry as root:root (observed 2026-08-05).
#
# The requirement is an end state -- owned by the ansible user -- not "writable
# by whoever happens to be running". chown/chmod are idempotent and cost
# milliseconds; there is no reason to guess whether they are needed.
owner_of() {
	# GNU first (the controller is Ubuntu), BSD fallback so this is testable
	# on a developer Mac.
	stat -c %U "$1" 2>/dev/null || stat -f %Su "$1" 2>/dev/null || echo "unknown"
}

echo "=== Asserting prerequisites the platform is responsible for ==="

# retry dir — the tarball extracts as root, so this lands root-owned. Without
# the fix a failed attempt 1 cannot write its retry file, and attempt 2 loses
# retry-file scope and silently degrades to a full sweep.
as_root mkdir -p "$RETRY_DIR" 2>/dev/null || true
# Failures are deliberately silent here: what matters is the END STATE,
# checked immediately below. Reporting "chown failed" when the ownership was
# already correct is the same proxy-versus-claim mistake catalogued all
# through this log.
as_root chown -R "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$RETRY_DIR" 2>/dev/null || true
as_root chmod 0755 "$RETRY_DIR" 2>/dev/null || true

# Verify the END STATE, not that the commands ran.
retry_owner="$(owner_of "$RETRY_DIR")"
if [ "$retry_owner" = "$ANSIBLE_OWNER" ]; then
	echo "  $RETRY_DIR owned by $ANSIBLE_OWNER"
else
	echo "  WARN: $RETRY_DIR still owned by '$retry_owner', wanted '$ANSIBLE_OWNER'"
	echo "        Retry-file scoping will be lost on a failed attempt; deploy continues."
fi

# vault password file — placed by the blueprint with its value, but not
# necessarily with ownership and mode the ansible user can read.
if [ -f "$VAULT_PASS_FILE" ]; then
	as_root chown "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$VAULT_PASS_FILE" 2>/dev/null || true
	as_root chmod 0600 "$VAULT_PASS_FILE" 2>/dev/null || true
	vault_owner="$(owner_of "$VAULT_PASS_FILE")"
	if [ "$vault_owner" = "$ANSIBLE_OWNER" ]; then
		echo "  $VAULT_PASS_FILE owned by $ANSIBLE_OWNER, mode 0600"
	else
		echo "  WARN: $VAULT_PASS_FILE still owned by '$vault_owner'"
	fi
fi

# --- Vault guard (only where the repo actually uses a vault) -----------------
# THIS REPO STORES CREDENTIALS IN PLAINTEXT, in group_vars/all/main.yml. That is
# a deliberate, long-standing convention here -- domain_admin_password and
# splunk_admin_password have always been plaintext -- and there is no
# group_vars/all/vault.yml to check.
#
# The guard below was imported wholesale from ss-pp-so on 2026-09-01 along with
# the retry-directory prerequisites. ss-pp-so IS vaulted, so there the checks
# are correct; here they made deploy.sh exit 1 before Ansible ever started,
# with "group_vars/all/vault.yml not found. Refusing to deploy." Porting a
# prerequisite block between repos with different credential conventions
# carried an assertion that could never pass.
#
# Gated on an explicit flag rather than "skip if the file is absent". A
# file-absence short-circuit is exactly the bug the original comment warned
# about: in so-ansible the equivalent guard read
#   if [ -f <path> ] && ! head -1 <path> | grep -q '^$ANSIBLE_VAULT'
# so a MISSING vault made the whole test false and it passed on every run,
# having never once fired. An explicit flag cannot fail that way -- set it to
# true and every check below becomes fatal again.
REPO_USES_VAULT="${REPO_USES_VAULT:-false}"

if [ "$REPO_USES_VAULT" = "true" ]; then
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


# THE COLLECTIONS PATH IS PINNED AND EXPORTED, so ansible-galaxy and
# ansible-playbook cannot disagree about where collections live.
#
# ss-pp-stacked 2026-09-02, on a fresh controller. galaxy reported success:
#     Installing 'pfsensible.core:0.7.1' to
#     '/root/.ansible/collections/ansible_collections/pfsensible/core'
# and then all three deploy attempts died in two seconds with
#     ERROR! couldn't resolve module/action 'pfsensible.core.pfsense_setup'
#
# The install WORKED and the collection was still unusable, because the
# directory it landed in is not one the playbook run searches -- and is not
# readable by the deploy account anyway. "Installed" and "resolvable" are two
# different claims and only the second one matters here. requirements.yml's
# own header used to recommend `sudo ansible-galaxy ...`, which is precisely
# how a collection ends up in root's home; that line is corrected too.
#
# The other four collections masked the fault for months: they ship inside the
# ansible package in site-packages, so galaxy says "already installed,
# skipping" and they resolve at runtime regardless of this path.
# pfsensible.core is the only one that must actually be fetched, so it was the
# only one that could break.
#
# /usr/share/ansible/collections is kept on the path so a site-wide install
# still counts. Collections bundled in site-packages are found by the loader
# independently of this variable.
COLLECTIONS_DIR="${HOME}/.ansible/collections"
export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_DIR}:/usr/share/ansible/collections"

echo "=== Checking for Ansible Galaxy collections ==="

if [ -f requirements.yml ]; then
	echo "=== Installing/refreshing Ansible Galaxy collections ==="
	echo "    target: $COLLECTIONS_DIR"
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml -p "$COLLECTIONS_DIR" 2>&1 \
		|| echo "WARN: galaxy install returned non-zero; continuing"
fi

# --- Prove the playbook PARSES before spending hours on it -------------------
# This is the exact operation that failed on 2026-09-02, run here as a gate
# instead of being discovered three attempts later. A parse failure is
# deterministic -- it fails identically on attempts 2 and 3 -- so retrying it
# is pure waste. That run burned three attempts plus a 180s BOOT_DELAY to
# learn nothing, and the log could not even say what had gone wrong.
#
# Note the ordering: BEFORE the boot delay, so a broken tree costs seconds
# rather than three minutes.
echo "=== Syntax check ==="
if ! ansible-playbook "$PLAYBOOK" --syntax-check 2>&1; then
	cat <<-ERRMSG

	ERROR: $PLAYBOOK does not parse. No hosts were touched, and retrying
	       would fail identically, so this stops here.

	If the message above is "couldn't resolve module/action", a collection
	this repo needs is missing FROM THE SEARCH PATH -- which is not the same
	as missing from the machine. Compare where it landed against where
	ansible actually looks:

	    ansible-galaxy collection list
	    ansible-config dump | grep -i collections_path
	    echo "\$ANSIBLE_COLLECTIONS_PATH"

	requirements.yml lists every collection this repo needs.
	ERRMSG
	exit 1
fi

# --- Let a freshly provisioned range finish booting --------------------------
BOOT_DELAY="${BOOT_DELAY:-180}"
if [ "$BOOT_DELAY" -gt 0 ]; then
	echo "=== Waiting ${BOOT_DELAY}s for range VMs to finish booting ==="
	echo "    (override with BOOT_DELAY=0 ./deploy.sh on an already-up range)"
	sleep "$BOOT_DELAY"
fi

ANSIBLE_START=$(date +%s)
DEPLOY_RESULT="INCOMPLETE — interrupted mid-run"

for i in $(seq 1 $MAX_ATTEMPTS); do
	# Attempt 2 gets the retry-file scope IF the previous attempt actually
	# produced one. If the file is missing (e.g. deploy exited on a global
	# error before writing it), fall through to the full sweep.
	ATTEMPT_START=$(date +%s)

	if [ $i -eq 2 ] && [ -f "$RETRY_FILE" ]; then
		echo "=== Attempt $i (retry-file scope — failed hosts only) ==="
	# STDERR IS MERGED INTO STDOUT DELIBERATELY.
	#
	# ss-pp-stacked 2026-09-02: all three attempts failed in ~2 seconds and
	# /var/log/playbook_run.log contained nothing but "Attempt N failed after
	# 0h 00m 02s". Every ansible-playbook startup error -- a role that cannot
	# be found, an unparsable play, a vault secret that is missing, a bad
	# --limit -- is written to STDERR, and the log is produced by piping this
	# script's STDOUT into tee. So the log faithfully recorded THAT a deploy
	# failed while structurally being unable to record WHY.
	#
	# Merging here rather than taking over logging with `exec > >(tee ...)`:
	# the caller already owns the redirect, and a second writer to the same
	# file interleaves badly.
		if ansible-playbook $PLAYBOOK --forks $FORKS --limit @"$RETRY_FILE" "$@" 2>&1; then
			echo "Success on attempt $i (retry scope) after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"
			DEPLOY_RESULT="SUCCESS on attempt $i (retry scope)"
			break
		fi
	else
		echo "=== Attempt $i (full sweep) ==="
		if ansible-playbook $PLAYBOOK --forks $FORKS "$@" 2>&1; then
			echo "Success on attempt $i after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"
			DEPLOY_RESULT="SUCCESS on attempt $i"
			break
		fi
	fi

	echo "Attempt $i failed after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"

	# Preserve the retry file between attempts 1 and 2 (that's how attempt 2
	# knows which hosts to target). Clear it between 2 and 3 so a stale
	# retry list can't accidentally scope attempt 3 the same way attempt 2
	# was scoped.
	if [ $i -ge 2 ]; then
		rm -f "$RETRY_FILE"
	fi

	if [ $i -eq $MAX_ATTEMPTS ]; then
		echo "ERROR: Playbook failed after $MAX_ATTEMPTS attempts"
		DEPLOY_RESULT="FAILED after $MAX_ATTEMPTS attempts"
		exit 1
	fi
done
