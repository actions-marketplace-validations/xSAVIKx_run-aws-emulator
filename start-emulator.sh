#!/usr/bin/env bash
# Start the AWS Emulator container and print the environment for AWS SDKs.
#
# Local use (prints "export" lines; evaluate them in your shell):
#   out="$(./start-emulator.sh)" && eval "$out"
#   ./start-emulator.sh --stop
#
# Do not use 'eval "$(./start-emulator.sh)"'. With that form, the shell
# ignores the exit status of the script, and a failure is not visible.
#
# GitHub Actions use (writes the variables to $GITHUB_ENV):
#   ./start-emulator.sh --github-env
#
# Settings (environment variables):
#   EMULATOR_IMAGE      image to run   (default ghcr.io/xsavikx/aws-emulator:latest)
#   EMULATOR_PORT       port 1-65535   (default 9297; the same on the host and in the container)
#   EMULATOR_NAME       container name (default aws-emulator-<port>)
#   EMULATOR_TELEMETRY  on or off      (default off; also true/false/1/0)
#   EMULATOR_MEMORY     memory limit   (default 2g)
#   EMULATOR_REGION     AWS Region     (default us-east-1)
#   EMULATOR_WAIT       seconds to wait until healthy (default 60)
#   EMULATOR_PULL       "true" to pull the image before the start (default false)
#   EMULATOR_ENGINE     "docker" or "podman" (default: docker if present, else podman)
#   DO_NOT_TRACK        "1" sets the telemetry to off when EMULATOR_TELEMETRY is not set
#
# Besides the emulator files, the script writes two trust files to
# ~/.aws/emulator-extra/<port>/: ca-bundle.pem (system CAs + emulator CA)
# and truststore.p12 (Java cacerts + emulator CA, password "changeit").
# SSL_CERT_FILE and JAVA_TOOL_OPTIONS point to these combined files, so
# package downloads from the internet keep working. If the script cannot
# make a complete file, it does not set the related variable.
#
# Maintainer: Yurii Serhiichuk <yurii@serhiichuk.dev>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

CR=$'\r'
NL=$'\n'
log() { echo "start-emulator: $*" >&2; }
# GitHub annotations need encoded line breaks.
annotate() {
  local kind="$1" msg="$2"
  msg="${msg//%/%25}"; msg="${msg//$CR/%0D}"; msg="${msg//$NL/%0A}"
  echo "::$kind title=Run AWS Emulator::$msg" >&2
}
warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then annotate warning "$*"; fi
  log "warning: $*"
}
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then annotate error "$*"; fi
  log "error: $*"; exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

MODE="print"
case "${1:-}" in
  "") ;;
  --stop) MODE=stop ;;
  --github-env) MODE=github ;;
  *) fail "unknown argument: $1. Use --stop, --github-env or no argument." ;;
esac

# Validate all settings before the script starts anything.
IMAGE="${EMULATOR_IMAGE:-ghcr.io/xsavikx/aws-emulator:latest}"
PORT="${EMULATOR_PORT:-9297}"
MEMORY="${EMULATOR_MEMORY:-2g}"
REGION="${EMULATOR_REGION:-us-east-1}"
WAIT="${EMULATOR_WAIT:-60}"
for setting in EMULATOR_IMAGE EMULATOR_REGION EMULATOR_NAME EMULATOR_MEMORY EMULATOR_ENGINE; do
  value="${!setting:-}"
  case "$value" in
    *"$NL"* | *"$CR"*) fail "$setting must not contain a line break." ;;
  esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "${#PORT}" -gt 5 ] || [ $((10#$PORT)) -lt 1 ] || [ $((10#$PORT)) -gt 65535 ]; then
  fail "EMULATOR_PORT (the port input) must be a number from 1 to 65535. The value is '$PORT'."
fi
PORT=$((10#$PORT))
if ! [[ "$WAIT" =~ ^[0-9]+$ ]] || [ "${#WAIT}" -gt 6 ] || [ $((10#$WAIT)) -lt 1 ]; then
  fail "EMULATOR_WAIT (the wait-timeout input) must be a number of seconds from 1 to 999999. The value is '$WAIT'."
fi
WAIT=$((10#$WAIT))

if [ -z "${EMULATOR_TELEMETRY:-}" ]; then
  # The default is off. DO_NOT_TRACK=1 (the console convention) also gives off.
  TELEMETRY=off
else
  case "$(lower "$EMULATOR_TELEMETRY")" in
    on | true | 1) TELEMETRY=on ;;
    off | false | 0) TELEMETRY=off ;;
    *) fail "EMULATOR_TELEMETRY (the telemetry input) must be 'on' or 'off'. The value is '$EMULATOR_TELEMETRY'." ;;
  esac
fi

case "$(lower "${EMULATOR_PULL:-false}")" in
  true) PULL=true ;;
  false | "") PULL=false ;;
  *) fail "EMULATOR_PULL (the pull input) must be 'true' or 'false'. The value is '$EMULATOR_PULL'." ;;
esac

ENGINE="$(lower "${EMULATOR_ENGINE:-}")"
case "$ENGINE" in
  "" | docker | podman) ;;
  *) fail "EMULATOR_ENGINE (the engine input) must be empty, 'docker' or 'podman'. The value is '$EMULATOR_ENGINE'." ;;
esac

NAME="${EMULATOR_NAME:-aws-emulator-$PORT}"
DIR="$HOME/.aws/emulator"
RUN_DIR="$DIR/$PORT"
EXTRA="$HOME/.aws/emulator-extra/$PORT"

# Container engine: Docker, or Podman (for example on self-hosted runners).
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null 2>&1; then ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then ENGINE=podman
  else ENGINE=docker
  fi
fi
# The podman-docker package installs a "docker" command that runs Podman.
if [ "$ENGINE" = docker ] && command -v docker >/dev/null 2>&1 && command -v podman >/dev/null 2>&1 \
  && docker --version 2>/dev/null | grep -qi podman; then
  ENGINE=podman
fi

if [ "$MODE" = stop ]; then
  "$ENGINE" stop -t 20 "$NAME" >/dev/null 2>&1 || true
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$EXTRA"
  log "stopped $NAME"
  exit 0
fi

if [ "$MODE" = github ]; then
  : "${GITHUB_ENV:?GITHUB_ENV is not set}"
  # Write the container name now, so that a later step can read the logs after a failure.
  echo "container=$NAME" >> "${GITHUB_OUTPUT:-/dev/null}"
fi

# Checks before the start, with clear messages for unsupported runners.
command -v "$ENGINE" >/dev/null 2>&1 \
  || fail "$ENGINE is not installed. The AWS Emulator runs only as a Linux container. Use a Linux runner with Docker (for example ubuntu-latest or ubuntu-24.04-arm). GitHub-hosted macOS and Windows runners and ubuntu-slim have no Docker for Linux containers."
command -v curl >/dev/null 2>&1 || fail "curl is not installed."
if [ "$ENGINE" = podman ]; then
  info=$(podman info --format '{{.Host.OS}} {{.Host.Security.Rootless}}' 2>/dev/null) \
    || fail "podman does not work on this runner."
  ostype="${info%% *}"
  rootless=false
  [ "${info#* }" = true ] && rootless=true
else
  info=$(docker info --format '{{.OSType}} {{json .SecurityOptions}}' 2>/dev/null) \
    || fail "The Docker daemon is not reachable. Start Docker, or use a Linux runner with Docker (for example ubuntu-latest)."
  ostype="${info%% *}"
  rootless=false
  case "${info#* }" in *rootless*) rootless=true ;; esac
fi
[ "$ostype" = linux ] \
  || fail "The container engine runs $ostype containers. The AWS Emulator needs Linux containers. GitHub-hosted Windows runners support only Windows containers; use a Linux runner."

# A rootless engine maps container root to the host user.
if [ "$rootless" = true ]; then user="0:0"; else user="$(id -u):$(id -g)"; fi

errfile="$(mktemp "${TMPDIR:-/tmp}/start-emulator.XXXXXX")"
trap 'rm -f "$errfile"' EXIT

mkdir -p "$DIR" "$EXTRA"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
if [ "$PULL" = true ]; then
  log "pulling $IMAGE"
  "$ENGINE" pull -q "$IMAGE" >&2 \
    || fail "could not pull the image $IMAGE. Check the image name and tag, and the access to the registry."
fi
log "starting $IMAGE as $NAME on 127.0.0.1:$PORT ($ENGINE, user $user)"
run_emulator() {
  "$ENGINE" run -d --name "$NAME" "$@" \
    -p "127.0.0.1:$PORT:$PORT" --user "$user" \
    --label "run-aws-emulator.source=https://github.com/xSAVIKx/run-aws-emulator" \
    --label "run-aws-emulator.run-id=${GITHUB_RUN_ID:-local}" \
    -e HOME="$HOME" -e EMULATOR_TELEMETRY="$TELEMETRY" -e EMULATOR_HEALTHCHECK_PORT="$PORT" \
    -v "$DIR:$DIR" "$IMAGE" -p "$PORT" >/dev/null 2>"$errfile"
}
if ! run_emulator --memory="$MEMORY" --memory-swap="$MEMORY"; then
  err="$(cat "$errfile")"
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
  # Some rootless setups cannot set memory limits (no cgroup delegation).
  if printf '%s' "$err" | grep -qiE 'memory|cgroup|swap'; then
    warn "the start with a memory limit failed; starting without a memory limit. The error was: $err"
    if ! run_emulator; then
      err="$(cat "$errfile")"
      "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
      fail "the container did not start: $err"
    fi
  else
    fail "the container did not start: $err"
  fi
fi

healthy=false
running=true
deadline=$((SECONDS + WAIT))
while :; do
  if [ -s "$RUN_DIR/ca.pem" ] && curl -sf --max-time 2 --cacert "$RUN_DIR/ca.pem" \
    "https://127.0.0.1:$PORT/__admin/health" >/dev/null 2>&1; then
    healthy=true; break
  fi
  if [ "$("$ENGINE" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    running=false; break
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 0.5
done
if [ "$healthy" != true ]; then
  echo "start-emulator: the last lines of the container log:" >&2
  "$ENGINE" logs --tail 50 "$NAME" >&2 2>&1 || true
  if [ "$running" = false ]; then
    state="$("$ENGINE" inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}}' "$NAME" 2>/dev/null || true)"
    code="${state%% *}"
    if [ "${state#* }" = true ] || [ "$code" = 137 ]; then
      if [ "${state#* }" = true ]; then oom="OOM killed"; else oom="killed, possibly OOM"; fi
      fail "the container exited (code ${code:-unknown}, $oom). Increase the memory input (EMULATOR_MEMORY, now $MEMORY)."
    fi
    fail "the container exited (code ${code:-unknown}). See the log lines above."
  fi
  fail "the emulator did not become healthy in ${WAIT}s"
fi
log "healthy"

vars=(
  "AWS_ENDPOINT_URL=https://127.0.0.1:$PORT"
  "AWS_SHARED_CREDENTIALS_FILE=$RUN_DIR/emulator_credentials"
  "AWS_CONFIG_FILE=$RUN_DIR/config"
  "AWS_CA_BUNDLE=$RUN_DIR/ca.pem"
  "NODE_EXTRA_CA_CERTS=$RUN_DIR/ca.pem"
  "AWS_EMULATOR_CA=$RUN_DIR/ca.pem"
  "AWS_EC2_METADATA_DISABLED=true"
  "AWS_DISABLE_HOST_PREFIX_INJECTION=true"
  "AWS_REGION=$REGION"
  "AWS_DEFAULT_REGION=$REGION"
)

# Combined PEM bundle: system CAs + emulator CA.
# A bundle with only the emulator CA breaks internet TLS, so the script does not set it.
sys_bundle=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -s "$f" ]; then sys_bundle="$f"; break; fi
done
rm -f "$EXTRA/ca-bundle.pem"
if [ -n "$sys_bundle" ]; then
  cat "$sys_bundle" "$RUN_DIR/ca.pem" > "$EXTRA/ca-bundle.pem"
  vars+=("SSL_CERT_FILE=$EXTRA/ca-bundle.pem")
else
  warn "no system CA bundle found; SSL_CERT_FILE is not set."
fi

# Combined Java truststore: JDK cacerts + emulator CA.
# The script sets JAVA_TOOL_OPTIONS only if both imports succeed.
rm -f "$EXTRA/truststore.p12"
keytool_bin=""
java_home=""
if [ -n "${JAVA_HOME:-}" ]; then
  java_home="$JAVA_HOME"
  if [ -x "$JAVA_HOME/bin/keytool" ]; then keytool_bin="$JAVA_HOME/bin/keytool"; fi
fi
if [ -z "$keytool_bin" ] && command -v keytool >/dev/null 2>&1; then
  keytool_bin="$(command -v keytool)"
  if [ -z "$java_home" ]; then
    java_home="$(dirname "$(dirname "$(readlink -f "$keytool_bin" 2>/dev/null || echo "$keytool_bin")")")"
  fi
fi
if [ -n "$keytool_bin" ]; then
  cacerts=""
  for f in "$java_home/lib/security/cacerts" "$java_home/jre/lib/security/cacerts"; do
    if [ -f "$f" ]; then cacerts="$f"; break; fi
  done
  store="$EXTRA/truststore.p12"
  if [ -z "$cacerts" ]; then
    warn "no Java cacerts file found in $java_home (JAVA_HOME); JAVA_TOOL_OPTIONS is not set."
  elif ! "$keytool_bin" -importkeystore -noprompt -srckeystore "$cacerts" -srcstorepass changeit \
    -destkeystore "$store" -deststoretype PKCS12 -deststorepass changeit >/dev/null 2>&1; then
    rm -f "$store"
    warn "keytool could not read $cacerts; JAVA_TOOL_OPTIONS is not set."
  elif ! "$keytool_bin" -importcert -noprompt -alias aws-emulator -file "$RUN_DIR/ca.pem" \
    -keystore "$store" -storetype PKCS12 -storepass changeit >/dev/null 2>&1; then
    rm -f "$store"
    warn "keytool could not add the emulator CA to the Java truststore; JAVA_TOOL_OPTIONS is not set."
  else
    # JDK 9 and later accept a quoted option in JAVA_TOOL_OPTIONS. JDK 8 does not,
    # so the script adds quotes only when the path contains a space.
    case "$store" in
      *" "*) store_opt="\"-Djavax.net.ssl.trustStore=$store\"" ;;
      *) store_opt="-Djavax.net.ssl.trustStore=$store" ;;
    esac
    java_opts="$store_opt -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit"
    vars+=("AWS_EMULATOR_JAVA_TRUSTSTORE=$store" "JAVA_TOOL_OPTIONS=$java_opts")
  fi
fi

# Select the repository digest that matches the image repository.
normalize_repo() {
  local r="$1" first
  r="${r%%@*}"
  case "${r##*/}" in *:*) r="${r%:*}" ;; esac
  first="${r%%/*}"
  if [ "$first" = "$r" ]; then r="docker.io/library/$r"
  else
    case "$first" in
      *.* | *:* | localhost) ;;
      *) r="docker.io/$r" ;;
    esac
  fi
  printf '%s' "$r"
}
image_digest() {
  local want d
  want="$(normalize_repo "$IMAGE")"
  "$ENGINE" image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null \
    | while IFS= read -r d; do
        if [ -n "$d" ] && [ "$(normalize_repo "$d")" = "$want" ]; then
          printf '%s\n' "$d"; break
        fi
      done || true
}

if [ "$MODE" = github ]; then
  printf '%s\n' "${vars[@]}" >> "$GITHUB_ENV"
  {
    echo "endpoint-url=https://127.0.0.1:$PORT"
    echo "ca-file=$RUN_DIR/ca.pem"
    echo "image-digest=$(image_digest)"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE"
  for v in "${vars[@]}"; do printf 'export %s=%q\n' "${v%%=*}" "${v#*=}"; done
fi
