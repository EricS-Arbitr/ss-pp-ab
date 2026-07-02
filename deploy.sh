#!/bin/bash
#
# deploy.sh — three-attempt Ansible runner with hybrid retry scope.
#
# Attempt 1: full arbitr_pp_playbook.yaml against every host
# Attempt 2: --limit @retry-file (failed hosts only) if a retry file exists
# Attempt 3: full playbook again (safety net if retry-scoped attempt didn't cover
#            a cross-host dependency)
#
# --forks 40 (up from Ansible default 5) so full sweeps parallelize
# aggressively across the ~30-host PowerPlant fleet. Controller has enough
# headroom (2-4 vCPU on the SimSpace VM); 40 concurrent workers is a
# comfortable middle ground and matches the airfield-range deploy.sh.

PLAYBOOK="arbitr_pp_playbook.yaml"
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

# --- Install Galaxy collections (idempotent — skips already-installed ones) ---
# Required for the pfsensible.core collection that drives the pp-ot-firewall
# pfSense play. Pulled through the corp proxy because the Ansible VM doesn't
# have direct internet. Failure here doesn't abort the deploy — ansible-playbook
# will surface a clear "collection not found" error if anything's actually missing.
#
# NOTE: The historical `sleep 120` before this section was removed 2026-07-02
# as part of the speed pass. It was a defensive delay to let fresh-provisioned
# VMs finish booting before the deploy started, but the retry loop already
# handles any "host unreachable" from a VM that isn't ready. On iterative
# deploys the sleep is pure wasted wall clock.
echo "=== Checking for Ansible Galaxy collections ==="

if [ -f requirements.yml ]; then
	echo "=== Installing/refreshing Ansible Galaxy collections ==="
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml \
		|| echo "WARN: galaxy install returned non-zero; continuing"
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
