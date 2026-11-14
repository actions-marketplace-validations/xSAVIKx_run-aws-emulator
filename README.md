# Run AWS Emulator

[![Test](https://github.com/xSAVIKx/run-aws-emulator/actions/workflows/test.yml/badge.svg)](https://github.com/xSAVIKx/run-aws-emulator/actions/workflows/test.yml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Run%20AWS%20Emulator-orange?logo=github)](https://github.com/marketplace/actions/run-aws-emulator)

A GitHub Action that runs the [AWS Emulator](https://github.com/aws/aws-emulator), a local
emulator of the AWS APIs, and points the AWS CLI and SDKs at it. Your tests then call
STS, S3, DynamoDB, SQS, SNS, Secrets Manager and many other services without an AWS
account.

The action runs the multi-arch container image from
[xSAVIKx/aws-emulator-docker](https://github.com/xSAVIKx/aws-emulator-docker). That
image is tested on `linux/amd64` and `linux/arm64`, signed with cosign, and updated within
one hour of each upstream release.

Write-up with `docker run`, Compose, GitHub Actions and the gotchas:
[Running AWS Emulator in Docker, on any arch, in CI](https://serhiichuk.dev/blog/aws-emulator-container-image/)

> This is an unofficial community action. It is not affiliated with or endorsed by Amazon
> Web Services.

## Usage

```yaml
jobs:
  test:
    runs-on: ubuntu-latest   # any Linux runner with Docker or Podman, x64 or arm64
    steps:
      - uses: actions/checkout@v7
      - uses: xSAVIKx/run-aws-emulator@v1
      - run: aws sts get-caller-identity   # "Account": "000000000000"
      - run: make integration-test         # your SDK tests use the emulator
```

## Supported runners

| Runner | Result |
|---|---|
| `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04` and their `-arm` variants | Supported and tested in CI |
| Self-hosted Linux with Docker or Podman (also rootless) | Supported; Podman is tested on Ubuntu 24.04 and 26.04 |
| GitHub-hosted macOS, Windows and `ubuntu-slim` | Not supported: no Docker for Linux containers. The action stops at once with a clear message. |

Set `engine: podman` to force Podman. By default the action uses Docker if it is installed,
else Podman.

For reproducible runs, pin the image to a build tag or a digest:

```yaml
      - uses: xSAVIKx/run-aws-emulator@v1
        with:
          image: ghcr.io/xsavikx/aws-emulator:1.0.322.1
```

## Security

### Pin the action to a commit

A tag such as `v1` can move to a new commit. A full commit SHA cannot move. For the
strictest pin, use the commit of a release and keep the version in a comment:

```yaml
      - uses: xSAVIKx/run-aws-emulator@<commit-sha> # v1.1.1
```

To get the commit SHA of a release, run:

```sh
git ls-remote https://github.com/xSAVIKx/run-aws-emulator 'refs/tags/v1.1.1^{}'
```

Dependabot and Renovate update this form of pin and its comment. In this repository, a
ruleset blocks the deletion and the force push of `v*` tags. Only the repository admin can
bypass it, to move the `v1` tag to a new release.

### Verify the image signature

The [image](https://github.com/xSAVIKx/aws-emulator-docker) has a keyless cosign signature
from its release workflow. The `image-digest` output gives the exact image that runs. Verify
that digest before your tests use the emulator:

```yaml
      - uses: xSAVIKx/run-aws-emulator@v1
        id: emulator
      - uses: sigstore/cosign-installer@756fe2d284c7292c4e9b62c8a28f1e5629c59532 # v4.1.3
      - run: |
          cosign verify "${{ steps.emulator.outputs.image-digest }}" \
            --certificate-identity 'https://github.com/xSAVIKx/aws-emulator-docker/.github/workflows/release.yml@refs/heads/main' \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

If the signature is not correct, `cosign verify` fails and the job stops. The CI of this
action runs this check on each change.

### What a correct signature tells you

The image build checks the AWS signature on the upstream package, and the image has a
signature from this project's release workflow. Together they tell you that the emulator
binary comes from AWS and that the image comes from this repository. They do not tell you
that the emulator code is free of defects. Use the emulator for local and CI tests only.
Do not give it real AWS credentials or production data.

## Inputs

| Input | Default | Description |
|---|---|---|
| `image` | `ghcr.io/xsavikx/aws-emulator:latest` | The image. Use a `-debian` or `-distroless` tag for those variants. |
| `port` | `9297` | The port on `127.0.0.1`, from 1 to 65535. The container uses the same port. |
| `region` | `us-east-1` | The value of `AWS_REGION` and `AWS_DEFAULT_REGION`. |
| `telemetry` | `off` | Upstream emulator telemetry, `on` or `off`. `true`, `false`, `1` and `0` also work. |
| `memory` | `2g` | The container memory limit. |
| `wait-timeout` | `60` | Seconds to wait until the emulator is healthy. A whole number, 1 or more. |
| `pull` | `false` | Pull the image before the start, `true` or `false`. |
| `engine` | (auto) | `docker` or `podman`. Empty means Docker if it is installed, else Podman. |

The action checks all inputs before it starts a container. If an input is not valid, the
action stops with a clear message.

## Outputs

| Output | Description |
|---|---|
| `endpoint-url` | The endpoint, for example `https://127.0.0.1:9297`. |
| `ca-file` | The emulator CA certificate (PEM). |
| `container` | The container name (`aws-emulator-<port>`), for `docker logs`. The action sets it also when the start fails. |
| `image-digest` | The repository digest of the image that runs. Empty if the image has no digest for its repository. |

## Environment for the next steps

The action sets these variables, so the AWS CLI and the AWS SDKs use the emulator with no
code change:

| Variable | Value |
|---|---|
| `AWS_ENDPOINT_URL` | `https://127.0.0.1:<port>` |
| `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE` | The files that the emulator writes for this run |
| `AWS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `AWS_EMULATOR_CA` | The emulator CA certificate |
| `SSL_CERT_FILE` | The system CAs + the emulator CA (Rust, .NET, OpenSSL) |
| `JAVA_TOOL_OPTIONS`, `AWS_EMULATOR_JAVA_TRUSTSTORE` | A truststore with the JDK CAs + the emulator CA |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | The `region` input |
| `AWS_EC2_METADATA_DISABLED`, `AWS_DISABLE_HOST_PREFIX_INJECTION` | `true` |

`SSL_CERT_FILE` and `JAVA_TOOL_OPTIONS` point to combined trust files. Package downloads
from the internet (Maven, NuGet, crates.io) keep working in the same job.

The action sets these two variables only when it can make a complete file. If the runner
has no system CA bundle, the action does not set `SSL_CERT_FILE`. If the action cannot
find the JDK `cacerts` file (in `$JAVA_HOME/lib/security` or `$JAVA_HOME/jre/lib/security`)
or `keytool` fails, the action does not set `JAVA_TOOL_OPTIONS`. In each case, the log
shows a warning.

Do not set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` or `AWS_PROFILE` in the job. The
SDKs use these before the emulator credentials file.

## Notes for SDK code

- **S3:** use path-style addresses (`forcePathStyle`, `addressing_style: path`), because
  the endpoint is an IP address.
- **SQS with the AWS SDK for JavaScript v3:** set `useQueueUrlAsEndpoint: false`. The
  emulator returns queue URLs with the real AWS host, and without this option the SDK
  sends SQS requests to real AWS.
- **Use `127.0.0.1`, not `localhost`.** The certificate names `localhost` too, but some
  SDKs then use virtual-hosted S3 addresses such as `bucket.localhost`.
- **Other containers** cannot call the emulator by a service name, because the certificate
  names only `localhost`, `127.0.0.1` and `::1`.

## The container lifetime

A composite action has no post step. The container keeps running until the job ends.
GitHub-hosted runners remove it with the virtual machine. On a self-hosted runner, the
container stays after the job. On a self-hosted runner:

- Give each concurrent job a unique `port`. The container name contains the port.
- Stop the container at the end of the job:

```yaml
      - uses: xSAVIKx/run-aws-emulator@v1
        id: emulator
      # ... your test steps ...
      - if: always()
        run: docker rm -f "${{ steps.emulator.outputs.container }}" || true
```

You can also run `start-emulator.sh --stop` with the same `EMULATOR_PORT`. It removes the
container and the combined trust files.

Each container has the labels `run-aws-emulator.source` and
`run-aws-emulator.run-id` (the value of `GITHUB_RUN_ID`). Use them to find old containers.

Tested examples for Python, TypeScript, Java, Go, C# and Rust are in
[aws-emulator-docker/examples](https://github.com/xSAVIKx/aws-emulator-docker/tree/main/examples).

## Run the same script on your computer

```sh
out="$(./start-emulator.sh)" && eval "$out"   # start, wait, and export the variables
aws sts get-caller-identity
./start-emulator.sh --stop
```

Do not use `eval "$(./start-emulator.sh)"`. With that form, the shell ignores the exit
status of the script, and you do not see a failure.

The script reads the same settings as environment variables, for example
`EMULATOR_PORT=9298 EMULATOR_MEMORY=4g`. The comment at the top of `start-emulator.sh`
lists them. The default telemetry is `off`. `DO_NOT_TRACK=1` also gives `off` when
`EMULATOR_TELEMETRY` is not set. An explicit `EMULATOR_TELEMETRY=on` has priority.

The script detects rootless Docker and then runs the container as `0:0`, which maps to
your own user.

## License

Apache License 2.0. Copyright 2026 Yurii Serhiichuk.

The AWS Emulator itself is under CC0 1.0 Universal, with code in its `vendor/` directory
under the Apache License 2.0. "AWS" is a trademark of Amazon.com, Inc. or its affiliates.

## Author

Created and maintained by **Yurii Serhiichuk** ([serhiichuk.dev](https://serhiichuk.dev),
[@xSAVIKx](https://github.com/xSAVIKx)).
