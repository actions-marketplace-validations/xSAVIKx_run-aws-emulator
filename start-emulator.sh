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

if [ "${1:-}" = "--stop" ]; then
  docker stop -t 20 "$NAME" >/dev/null 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$EXTRA"
  log "stopped $NAME"
  exit 0
fi

# Rootless Docker maps container root to the host user.
if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  user="0:0"
else
  user="$(id -u):$(id -g)"
fi

mkdir -p "$DIR" "$EXTRA"
docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ "${EMULATOR_PULL:-false}" = "true" ]; then
  log "pulling $IMAGE"
  docker pull -q "$IMAGE" >&2
fi
log "starting $IMAGE as $NAME on 127.0.0.1:$PORT (user $user)"
docker run -d --name "$NAME" --memory="$MEMORY" --memory-swap="$MEMORY" \
  -p "127.0.0.1:$PORT:$PORT" --user "$user" \
  -e HOME="$HOME" -e EMULATOR_TELEMETRY="$TELEMETRY" -e EMULATOR_HEALTHCHECK_PORT="$PORT" \
  -v "$DIR:$DIR" "$IMAGE" -p "$PORT" >/dev/null

healthy=false
for _ in $(seq $((WAIT * 2))); do
  if [ -s "$RUN_DIR/ca.pem" ] && curl -sf --cacert "$RUN_DIR/ca.pem" "https://127.0.0.1:$PORT/__admin/health" >/dev/null 2>&1; then
    healthy=true; break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then break; fi
  sleep 0.5
done
if [ "$healthy" != true ]; then
  log "the emulator did not become healthy"; docker logs "$NAME" >&2 || true; exit 1
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
    echo "image-digest=$(docker inspect -f '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE"
  for v in "${vars[@]}"; do printf 'export %s=%q\n' "${v%%=*}" "${v#*=}"; done
fi
