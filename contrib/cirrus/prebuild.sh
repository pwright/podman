#!/bin/bash

set -eo pipefail

# This script attempts to confirm functional networking and
# connectivity to essential external servers.  It also verifies
# some basic environmental expectations and shell-script sanity.
# It's intended for use early on in the podman CI system, to help
# prevent wasting time on tests that can't succeed due to some
# outage, failure, or missed expectation.

set -a
source /etc/automation_environment
source $AUTOMATION_LIB_PATH/common_lib.sh
set +a

req_env_vars CI DEST_BRANCH IMAGE_SUFFIX TEST_FLAVOR TEST_ENVIRON \
             PODBIN_NAME PRIV_NAME DISTRO_NV AUTOMATION_LIB_PATH \
             SCRIPT_BASE CIRRUS_WORKING_DIR FEDORA_NAME \
             VM_IMAGE_NAME

# Defined by the CI system
# shellcheck disable=SC2154
cd $CIRRUS_WORKING_DIR

msg "Checking Cirrus YAML"
# Defined by CI config.
# shellcheck disable=SC2154
showrun $SCRIPT_BASE/cirrus_yaml_test.py

msg "Checking for leading tabs in system tests"
if grep -n ^$'\t' test/system/*; then
    die "Found leading tabs in system tests. Use spaces to indent, not tabs."
fi

# Lookup 'env' dict. string value from key specified as argument from YAML file.
get_env_key() {
    local yaml
    local script

    yaml="$CIRRUS_WORKING_DIR/.github/workflows/scan-secrets.yml"
    script="from yaml import safe_load; print(safe_load(open('$yaml'))['env']['$1'])"
    python -c "$script"
}

# Only need to check CI-stuffs on a single build-task, there's only ever
# one prior-fedora task so use that one.
# Envars all defined by CI config.
# shellcheck disable=SC2154
if [[ "${DISTRO_NV}" == "$PRIOR_FEDORA_NAME" ]]; then
    msg "Checking shell scripts"
    showrun ooe.sh dnf install -y ShellCheck  # small/quick addition
    showrun shellcheck --format=tty \
        --shell=bash --external-sources \
        --enable add-default-case,avoid-nullary-conditions,check-unassigned-uppercase \
        --exclude SC2046,SC2034,SC2090,SC2064 \
        --wiki-link-count=0 --severity=warning \
        $SCRIPT_BASE/*.sh \
        ./.github/actions/check_cirrus_cron/* \
        hack/get_ci_vm.sh

    # Tests for lib.sh
    showrun ${SCRIPT_BASE}/lib.sh.t

    msg "Checking renovate config."
    showrun podman run -it \
            -v ./.github/renovate.json5:/usr/src/app/renovate.json5:z \
            ghcr.io/renovatebot/renovate:latest \
            renovate-config-validator

    # Run this during daily cron job to prevent a GraphQL API change/breakage
    # from impacting every PR.  Down-side being if it does fail, a maintainer
    # will need to do some archaeology to find it.
    # Defined by CI system
    # shellcheck disable=SC2154
    if [[ "$CIRRUS_CRON" == "main" ]]; then
      export PREBUILD=1
      showrun bash ${CIRRUS_WORKING_DIR}/.github/actions/check_cirrus_cron/test.sh
    fi
fi

msg "Checking 3rd party network service connectivity"
# shellcheck disable=SC2154
cat ${CIRRUS_WORKING_DIR}/${SCRIPT_BASE}/required_host_ports.txt | \
    while read host port
    do
        if [[ "$port" -eq "443" ]]
        then
            echo "SSL/TLS to $host:$port"
            echo -n '' | \
                err_retry 9 1000 "" openssl s_client -quiet -no_ign_eof -connect $host:$port
        else
            echo "Connect to $host:$port"
            err_retry 9 1000 1 nc -zv -w 13 $host $port
        fi
    done
