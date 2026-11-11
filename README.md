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

> This is an unofficial community action. It is not affiliated with or endorsed by Amazon
> Web Services.

## Usage

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04   # or ubuntu-24.04-arm, or any runner with Docker
    steps:
      - uses: actions/checkout@v5
      - uses: xSAVIKx/run-aws-emulator@v1
      - run: aws sts get-caller-identity   # "Account": "000000000000"
      - run: make integration-test         # your SDK tests use the emulator
```

For reproducible runs, pin the image to a build tag or a digest:

```yaml
      - uses: xSAVIKx/run-aws-emulator@v1
        with:
          image: ghcr.io/xsavikx/aws-emulator:1.0.322.1
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `image` | `ghcr.io/xsavikx/aws-emulator:latest` | The image. Use a `-debian` tag for the Debian variant. |
| `port` | `9297` | The port on `127.0.0.1`. The container uses the same port. |
| `region` | `us-east-1` | The value of `AWS_REGION` and `AWS_DEFAULT_REGION`. |
| `telemetry` | `off` | Upstream emulator telemetry, `on` or `off`. |
| `memory` | `2g` | The container memory limit. |
| `wait-timeout` | `60` | Seconds to wait until the emulator is healthy. |
| `pull` | `false` | Pull the image before the start. |

## Outputs

| Output | Description |
|---|---|
| `endpoint-url` | The endpoint, for example `https://127.0.0.1:9297`. |
| `ca-file` | The emulator CA certificate (PEM). |
| `container` | The container name, for `docker logs`. |
| `image-digest` | The repository digest of the image that runs. |

## Environment for the next steps

The action sets these variables, so the AWS CLI and the AWS SDKs use the emulator with no
code change:

| Variable | Value |
|---|---|
| `AWS_ENDPOINT_URL` | `https://127.0.0.1:<port>` |
| `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE` | The files that the emulator writes for this run |
| `AWS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `AWS_EMULATOR_CA` | The emulator CA certificate |
| `SSL_CERT_FILE` | The system CAs + the emulator CA (Rust, .NET, OpenSSL) |
| `JAVA_TOOL_OPTIONS` | A truststore with the JDK CAs + the emulator CA |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | The `region` input |
| `AWS_EC2_METADATA_DISABLED`, `AWS_DISABLE_HOST_PREFIX_INJECTION` | `true` |

`SSL_CERT_FILE` and `JAVA_TOOL_OPTIONS` point to combined trust files. Package downloads
from the internet (Maven, NuGet, crates.io) keep working in the same job.

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

Tested examples for Python, TypeScript, Java, Go, C# and Rust are in
[aws-emulator-docker/examples](https://github.com/xSAVIKx/aws-emulator-docker/tree/main/examples).

## Run the same script on your computer

```sh
eval "$(./start-emulator.sh)"     # start, wait, and export the variables
aws sts get-caller-identity
./start-emulator.sh --stop
```

The script detects rootless Docker and then runs the container as `0:0`, which maps to
your own user.

## License

Apache License 2.0. Copyright 2026 Yurii Serhiichuk.

The AWS Emulator itself is under CC0 1.0 Universal, with code in its `vendor/` directory
under the Apache License 2.0. "AWS" is a trademark of Amazon.com, Inc. or its affiliates.

## Author

Created and maintained by **Yurii Serhiichuk** ([serhiichuk.dev](https://serhiichuk.dev),
[@xSAVIKx](https://github.com/xSAVIKx)).
