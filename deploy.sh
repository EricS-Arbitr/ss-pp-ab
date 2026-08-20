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
