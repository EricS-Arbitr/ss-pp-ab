#!/bin/bash

PLAYBOOK="arbitr_pp_playbook.yaml"
RETRY_FILE="retry/$PLAYBOOK.retry"
MAX_ATTEMPTS=3

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
