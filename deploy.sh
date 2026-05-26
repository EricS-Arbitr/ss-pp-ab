#!/bin/bash

PLAYBOOK="arbitr_pp_playbook.yaml"
RETRY_FILE="retry/$PLAYBOOK.retry"
MAX_ATTEMPTS=3

# --- Install Galaxy collections (idempotent — skips already-installed ones) ---
# Required for the pfsensible.core collection that drives the pp-ot-firewall
# pfSense play. Pulled through the corp proxy because the Ansible VM doesn't
# have direct internet. Failure here doesn't abort the deploy — ansible-playbook
# will surface a clear "collection not found" error if anything's actually missing.
if [ -f requirements.yml ]; then
	echo "=== Installing/refreshing Ansible Galaxy collections ==="
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml \
		|| echo "WARN: galaxy install returned non-zero; continuing"
fi

for i in $(seq 1 $MAX_ATTEMPTS); do
	echo "=== Attempt $i ==="

	if ansible-playbook $PLAYBOOK "$@"; then
		echo "Success on attempt $i"
		break

	else
		echo "Attempt $i failed"

		rm -f "$RETRY_FILE"

		if [ $i -eq $MAX_ATTEMPTS ]; then
			echo "ERROR: Playbook failed after $MAX_ATTEMPTS attempts"
			exit 1
		fi
	fi
done
