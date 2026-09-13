#!/usr/bin/env bash
# Shared configuration sourced by the other Sparkle scripts.
# Override any of these by exporting them before invoking a script, or by
# setting them in .env.release.local (loaded by local-release-build.sh).

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.6}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.nfarina.Brushy}"
SPARKLE_SITE_URL="${SPARKLE_SITE_URL:-https://nfarina.github.io/brushy}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-${SPARKLE_SITE_URL%/}/appcast.xml}"
SPARKLE_RELEASES_URL="${SPARKLE_RELEASES_URL:-https://github.com/nfarina/brushy/releases}"
SPARKLE_RELEASE_DOWNLOAD_BASE_URL="${SPARKLE_RELEASE_DOWNLOAD_BASE_URL:-https://github.com/nfarina/brushy/releases/download}"
SPARKLE_TOOLS_REPO="${SPARKLE_TOOLS_REPO:-sparkle-project/Sparkle}"
SPARKLE_TOOLS_ARCHIVE="${SPARKLE_TOOLS_ARCHIVE:-Sparkle-${SPARKLE_VERSION}.tar.xz}"
SPARKLE_TOOLS_CACHE_DIR="${SPARKLE_TOOLS_CACHE_DIR:-build/sparkle-tools/${SPARKLE_VERSION}}"
