#!/usr/bin/env bash
#
# Container-side entry point: build the fixture home, then run one case.

set -uo pipefail

case_name=${1:?usage: run-case.sh <case>}
export SNAPSHOT=${SNAPSHOT:-/opt/src/omarchy-snapshot}

if ! bash /opt/src/test/fixture.sh > /tmp/fixture.log 2>&1; then
  echo "fixture failed:"
  cat /tmp/fixture.log
  exit 1
fi

exec bash "/opt/src/test/cases/${case_name}.sh"
