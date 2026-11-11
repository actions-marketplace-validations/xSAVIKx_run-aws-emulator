#!/usr/bin/env bash
# Start the AWS Emulator container and print the environment for AWS SDKs.
#
# Local use (prints "export" lines; evaluate them in your shell):
#   eval "$(./start-emulator.sh)"
#   ./start-emulator.sh --stop
#
# GitHub Actions use (writes the variables to $GITHUB_ENV):
#   ./start-emulator.sh --github-env
#
# Settings (environment variables):
#   EMULATOR_IMAGE      image to run   (default ghcr.io/xsavikx/aws-emulator:latest)
#   EMULATOR_PORT       port           (default 9297; the same on the host and in the container)
#   EMULATOR_NAME       container name (default aws-emulator-<port>)
#   EMULATOR_TELEMETRY  on or off      (default off)
#   EMULATOR_MEMORY     memory limit   (default 2g)
#   EMULATOR_REGION     AWS Region     (default us-east-1)
#   EMULATOR_WAIT       seconds to wait until healthy (default 60)
#   EMULATOR_PULL       "true" to pull the image before the start (default false)
#   EMULATOR_ENGINE     "docker" or "podman" (default: docker if present, else podman)
#
# Besides the emulator files, the script writes two trust files to
# ~/.aws/emulator-extra/<port>/: ca-bundle.pem (system CAs + emulator CA)
# and truststore.p12 (Java cacerts + emulator CA, password "changeit").
# SSL_CERT_FILE and JAVA_TOOL_OPTIONS point to these combined files, so
# package downloads from the internet keep working.
#
# Maintainer: Yurii Serhiichuk <yurii@serhiichuk.dev>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

IMAGE="${EMULATOR_IMAGE:-ghcr.io/xsavikx/aws-emulator:latest}"
PORT="${EMULATOR_PORT:-9297}"
NAME="${EMULATOR_NAME:-aws-emulator-$PORT}"
TELEMETRY="${EMULATOR_TELEMETRY:-off}"
MEMORY="${EMULATOR_MEMORY:-2g}"
REGION="${EMULATOR_REGION:-us-east-1}"
WAIT="${EMULATOR_WAIT:-60}"
DIR="$HOME/.aws/emulator"
RUN_DIR="$DIR/$PORT"
EXTRA="$HOME/.aws/emulator-extra/$PORT"

log() { echo "start-emulator: $*" >&2; }
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=Run AWS Emulator::$*" >&2; fi
  log "error: $*"; exit 1
}

# Container engine: Docker, or Podman (for example on self-hosted runners).
ENGINE="${EMULATOR_ENGINE:-}"
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null 2>&1; then ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then ENGINE=podman
  else ENGINE=docker
  fi
fi

if [ "${1:-}" = "--stop" ]; then
  "$ENGINE" stop -t 20 "$NAME" >/dev/null 2>&1 || true
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$EXTRA"
  log "stopped $NAME"
  exit 0
fi

# Checks before the start, with clear messages for unsupported runners.
command -v "$ENGINE" >/dev/null 2>&1 \
  || fail "$ENGINE is not installed. The AWS Emulator runs only as a Linux container. Use a Linux runner with Docker (for example ubuntu-latest or ubuntu-24.04-arm). GitHub-hosted macOS and Windows runners and ubuntu-slim have no Docker for Linux containers."
command -v curl >/dev/null 2>&1 || fail "curl is not installed."
if [ "$ENGINE" = podman ]; then
  ostype=$(podman info --format '{{.Host.OS}}' 2>/dev/null) || fail "podman does not work on this runner."
else
  ostype=$(docker info --format '{{.OSType}}' 2>/dev/null) \
    || fail "The Docker daemon is not reachable. Start Docker, or use a Linux runner with Docker (for example ubuntu-latest)."
fi
[ "$ostype" = linux ] \
  || fail "The container engine runs $ostype containers. The AWS Emulator needs Linux containers. GitHub-hosted Windows runners support only Windows containers; use a Linux runner."

# A rootless engine maps container root to the host user.
rootless=false
if [ "$ENGINE" = podman ]; then
  [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ] && rootless=true
elif docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  rootless=true
fi
if [ "$rootless" = true ]; then user="0:0"; else user="$(id -u):$(id -g)"; fi

mkdir -p "$DIR" "$EXTRA"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
if [ "${EMULATOR_PULL:-false}" = "true" ]; then
  log "pulling $IMAGE"
  "$ENGINE" pull -q "$IMAGE" >&2
fi
log "starting $IMAGE as $NAME on 127.0.0.1:$PORT ($ENGINE, user $user)"
run_emulator() {
  "$ENGINE" run -d --name "$NAME" "$@" \
    -p "127.0.0.1:$PORT:$PORT" --user "$user" \
    -e HOME="$HOME" -e EMULATOR_TELEMETRY="$TELEMETRY" -e EMULATOR_HEALTHCHECK_PORT="$PORT" \
    -v "$DIR:$DIR" "$IMAGE" -p "$PORT" >/dev/null
}
if ! run_emulator --memory="$MEMORY" --memory-swap="$MEMORY"; then
  # Some rootless setups cannot set memory limits (no cgroup delegation).
  log "warning: the start with a memory limit failed; starting without a memory limit"
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
  run_emulator || fail "the container did not start"
fi

healthy=false
for _ in $(seq $((WAIT * 2))); do
  if [ -s "$RUN_DIR/ca.pem" ] && curl -sf --cacert "$RUN_DIR/ca.pem" "https://127.0.0.1:$PORT/__admin/health" >/dev/null 2>&1; then
    healthy=true; break
  fi
  if [ "$("$ENGINE" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then break; fi
  sleep 0.5
done
if [ "$healthy" != true ]; then
  "$ENGINE" logs "$NAME" >&2 || true
  fail "the emulator did not become healthy in ${WAIT}s"
fi
log "healthy"

# Combined PEM bundle: system CAs + emulator CA.
sys_bundle=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -s "$f" ]; then sys_bundle="$f"; break; fi
done
cat ${sys_bundle:+"$sys_bundle"} "$RUN_DIR/ca.pem" > "$EXTRA/ca-bundle.pem"

# Combined Java truststore: JDK cacerts + emulator CA.
java_opts=""
if command -v keytool >/dev/null 2>&1; then
  java_home="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v keytool)")")")}"
  cacerts="$java_home/lib/security/cacerts"
  rm -f "$EXTRA/truststore.p12"
  if [ -f "$cacerts" ]; then
    keytool -importkeystore -noprompt -srckeystore "$cacerts" -srcstorepass changeit \
      -destkeystore "$EXTRA/truststore.p12" -deststoretype PKCS12 -deststorepass changeit >/dev/null 2>&1 || true
  fi
  keytool -importcert -noprompt -alias aws-emulator -file "$RUN_DIR/ca.pem" \
    -keystore "$EXTRA/truststore.p12" -storetype PKCS12 -storepass changeit >/dev/null 2>&1
  java_opts="-Djavax.net.ssl.trustStore=$EXTRA/truststore.p12 -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit"
fi

vars=(
  "AWS_ENDPOINT_URL=https://127.0.0.1:$PORT"
  "AWS_SHARED_CREDENTIALS_FILE=$RUN_DIR/emulator_credentials"
  "AWS_CONFIG_FILE=$RUN_DIR/config"
  "AWS_CA_BUNDLE=$RUN_DIR/ca.pem"
  "NODE_EXTRA_CA_CERTS=$RUN_DIR/ca.pem"
  "SSL_CERT_FILE=$EXTRA/ca-bundle.pem"
  "AWS_EMULATOR_CA=$RUN_DIR/ca.pem"
  "AWS_EC2_METADATA_DISABLED=true"
  "AWS_DISABLE_HOST_PREFIX_INJECTION=true"
  "AWS_REGION=$REGION"
  "AWS_DEFAULT_REGION=$REGION"
)
if [ -n "$java_opts" ]; then
  vars+=("AWS_EMULATOR_JAVA_TRUSTSTORE=$EXTRA/truststore.p12" "JAVA_TOOL_OPTIONS=$java_opts")
fi

if [ "${1:-}" = "--github-env" ]; then
  : "${GITHUB_ENV:?GITHUB_ENV is not set}"
  printf '%s\n' "${vars[@]}" >> "$GITHUB_ENV"
  {
    echo "endpoint-url=https://127.0.0.1:$PORT"
    echo "ca-file=$RUN_DIR/ca.pem"
    echo "container=$NAME"
    echo "image-digest=$("$ENGINE" image inspect -f '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE"
  for v in "${vars[@]}"; do printf 'export %s=%q\n' "${v%%=*}" "${v#*=}"; done
fi
