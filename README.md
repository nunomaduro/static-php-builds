# Static PHP Builds

- [Introduction](#introduction)
- [Installation](#installation)
- [Xdebug](#xdebug)
- [Verifying a Download](#verifying-a-download)
- [How Releases Are Built](#how-releases-are-built)
  - [Building Releases Manually](#building-releases-manually)
  - [Building Locally](#building-locally)
- [Release Layout](#release-layout)

## Introduction

Static PHP Builds provides precompiled PHP for [mise](https://mise.jdx.dev). With Static PHP Builds, installing PHP is a download instead of a compile — each release includes the PHP CLI, Composer, and Xdebug, for Linux x86_64 and Linux aarch64.

The builds are not tied to a framework. They include the extensions that Laravel, Symfony, WordPress, and most other PHP applications need: database drivers for MySQL, PostgreSQL, SQLite, and SQL Server, Redis and MongoDB clients, image processing with GD and Imagick, intl, sodium, and more.

The full list of extensions is in [`config/extensions.txt`](config/extensions.txt). A PHP branch that an extension does not support yet builds without it, as listed in [`config/extensions-excluded.txt`](config/extensions-excluded.txt). Linux builds run on any distribution with glibc 2.17 or newer.

## Installation

First, you should point mise's `php` tool at this repository:

```sh
mise tool-alias set php github:nunomaduro/static-php-builds
```

Once configured, you may install and use PHP like any other mise tool:

```sh
mise use --global php@8.5

php -v
composer --version
```

Projects that pin a PHP version in their `mise.toml` file use these builds as well:

```toml
[tools]
php = "8.4"
```

Alpha, beta, and release candidate versions of the next PHP release, such as `8.6.0beta3`, install the same way. `php@latest` always resolves to the newest stable release:

```sh
mise use --global php@8.6.0beta3
```

## Xdebug

Xdebug is loaded in every build, but it is turned off by default, so PHP runs at full speed. To enable it, set the `XDEBUG_MODE` environment variable to the [modes](https://xdebug.org/docs/all_settings#mode) you need, such as `debug` for step debugging or `coverage` for code coverage. `XDEBUG_MODE` always takes precedence over the bundled configuration, so you never need to edit files inside mise's install directory.

To enable Xdebug for a single command, set the variable inline:

```sh
XDEBUG_MODE=coverage vendor/bin/phpunit --coverage-text
```

To enable Xdebug for a project, add the variable to the project's `mise.toml` file. mise sets it whenever you are inside that directory:

```toml
[env]
XDEBUG_MODE = "debug"
```

To enable Xdebug everywhere, export the variable from your shell's startup file, such as `~/.bashrc`:

```sh
export XDEBUG_MODE=debug
```

You may enable several modes at once by separating them with commas, such as `XDEBUG_MODE=debug,coverage`.

### Step Debugging

With `XDEBUG_MODE=debug` set, start listening for debug connections in your editor (the "PHP Debug" extension in VS Code, or "Start Listening for PHP Debug Connections" in PhpStorm), then trigger a debugging session:

- **Console commands:** set the `XDEBUG_TRIGGER` environment variable, e.g. `XDEBUG_MODE=debug XDEBUG_TRIGGER=1 php script.php`.
- **Browser requests:** use a browser extension such as Xdebug Helper, which sets the `XDEBUG_SESSION` cookie. When using a server built on PHP's built-in web server, such as `php -S localhost:8000 -t public` or `php artisan serve`, set `XDEBUG_MODE` before starting the server so the requests it serves inherit it.

If you would like every request and command to connect to your editor without a trigger, also set `XDEBUG_CONFIG="start_with_request=yes"`.

The `bin/php` wrapper adds `etc/php/conf.d` to `PHP_INI_SCAN_DIR`, so any scan directory you configure yourself is still read.

## Verifying a Download

Every release file carries a GitHub build attestation, which mise verifies automatically. If you would like to verify a download yourself, you may use the `gh attestation verify` command:

```sh
gh attestation verify php-8.5.10-linux-x86_64.tar.gz --repo nunomaduro/static-php-builds
```

Each release also includes a `SHA256SUMS` file with the digest of every tarball:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

## How Releases Are Built

The **Release** workflow builds each release. For each branch in [`config/php-branches.txt`](config/php-branches.txt), it looks up the newest release on php.net and builds it only if this repository does not have a release for it yet. A branch without a stable release, such as 8.6 before its general availability, uses its newest pre-release from qa.php.net:

1. The PHP source is downloaded from php.net and verified against the SHA-256 that php.net publishes and against the GPG signature of a PHP release manager. The release manager keys are in [`config/php-release-keys.asc`](config/php-release-keys.asc).
2. PHP is compiled with a pinned, checksum-verified [static-php-cli](https://github.com/crazywhalecc/static-php-cli) on GitHub-hosted runners. A run that publishes compiles every library from source and restores no cache.
3. Each build is unpacked and smoke tested: the PHP version, the extensions, Xdebug, Composer, SQLite, intl, HTTPS with the system CA certificates, and the glibc baseline.
4. The files receive a build attestation and are published as a GitHub release named after the PHP version.

The pinned tools live in [`config/build.env`](config/build.env), and the exact URL or commit of each library lives in [`config/sources.pins`](config/sources.pins), so a new upstream release does not change a build. Every source that goes into a build, down to the compiler toolchain, must match its checksum or commit in [`config/sources.lock`](config/sources.lock), and the build stops when one differs. The release's `share/sources.txt` file records the same list.

### Running the Release Workflow

You run the **Release** workflow yourself. The `version` input accepts a PHP branch, an exact version, or `all`:

```sh
gh workflow run release.yml -f version=8.5
gh workflow run release.yml -f version=8.6.0beta3
gh workflow run release.yml -f version=all
```

`all` builds the newest release of every branch, including the releases that are already published. Leaving `version` empty builds only the releases that are missing.

By default, a run only builds and smoke tests. If you would like to publish the result as a GitHub release, pass the `publish` input as well. A version that is already published is left as it is, because releases in this repository cannot change after they are published:

```sh
gh workflow run release.yml -f version=all -f publish=true
```

### Building Locally

To check that a build works on your own Linux machine, run `bin/build` with a PHP branch or version. It resolves the newest release on php.net, builds it for your CPU architecture, and smoke tests the result:

```sh
bin/build 8.4
```

The tarball lands in `dist/`. The first run installs the build tools that static-php-cli needs, which may ask for your password.

## Release Layout

Each tarball unpacks to the following layout:

```
bin/php                          # runs libexec/php with the bundled ini files
bin/composer
libexec/php                      # the PHP binary
libexec/composer.phar
lib/php/extensions/xdebug.so
etc/php/conf.d/memory.ini
etc/php/conf.d/pcre.ini
etc/php/conf.d/xdebug.ini
share/licenses/                  # licenses of PHP and every bundled library
share/build-info.txt
share/sources.txt                # SHA-256 of every source archive and commit of every git source in the build
```
