# mam-point-spender

Spends MyAnonaMouse (MAM) bonus points for you. It tops up VIP and buys upload credit whenever your balance sits comfortably above a buffer you set.

Written in [Zig](https://ziglang.org).

## What it does

Each run reads your current point balance and VIP expiry, then:

1. Buys VIP up to the 12.8-week cap, if at least one full week can be added without going over.
2. Buys upload credit in 100 GB chunks while the balance stays above your buffer, then tries 50 GB chunks. Upload credit costs 500 points per GB.

The tool reads `MAM.cookies` from the current working directory on startup and rewrites it there on exit, so always run the binary from the same directory or it will create a fresh jar each time. If the jar is empty or stale, it falls back to the `MAMID` env var. Run it from cron or a systemd timer.

## Installation

### Pre-built binaries

Grab an archive for your platform from the [releases page](https://github.com/ansg191/mam-point-spender/releases). `.deb`, `.rpm`, and `.apk` packages are published too. The macOS binaries are signed and notarized by Apple, so they run without a Gatekeeper warning.

### Docker

```sh
docker pull ghcr.io/ansg191/mam-point-spender:latest
```

### From source

Needs Zig 0.16.0 or newer.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/mam-point-spender
```

## Configuration

Configuration comes from environment variables.

| Variable     | Required | Default | Description                                                           |
|--------------|----------|---------|-----------------------------------------------------------------------|
| `MAMID`      | yes      | none    | Your MAM session ID. Used as a fallback when the cookie jar is empty. |
| `MAM_BUFFER` | no       | `25000` | Minimum point balance to keep when buying upload credit.              |
| `MAM_VIP`    | no       | `true`  | Whether to maintain VIP (`true`/`false`/`1`/`0`).                     |

`MAM.cookies` is always created in the current working directory. Make sure to launch the binary from the directory you want the jar in (or `cd` there first in your cron/systemd unit), otherwise each run starts from scratch.

## Usage

```sh
export MAMID=your-mam-session-id
mam-point-spender
```

With Docker:

```sh
docker run --rm \
  -e MAMID=your-mam-session-id \
  -v "$PWD":/data -w /data \
  ghcr.io/ansg191/mam-point-spender:latest
```

## License

[AGPL-3.0-or-later](LICENSE).
