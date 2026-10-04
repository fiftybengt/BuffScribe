#!/usr/bin/env bash
# Copy BuffScribe into a WoW 3.3.5a client.
# A plain copy rather than a symlink, which is the safer option under Wine.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_client() {
    if [[ -n "${WOW_DIR:-}" ]]; then
        printf '%s' "$WOW_DIR"
        return
    fi
    # Common spots for a 3.3.5a client; first one with an AddOns folder wins.
    local candidate
    for candidate in \
        "$HOME/World of Warcraft 3.3.5a" \
        "$HOME/Downloads/World of Warcraft 3.3.5a" \
        "$HOME/Games/World of Warcraft 3.3.5a" \
        "$HOME/.wine/drive_c/Program Files/World of Warcraft" \
        "/opt/World of Warcraft 3.3.5a"
    do
        if [[ -d "$candidate/Interface/AddOns" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done
}

WOW="$(find_client)"

if [[ -z "$WOW" || ! -d "$WOW/Interface/AddOns" ]]; then
    cat >&2 <<'MSG'
error: could not find a WoW client.

Point WOW_DIR at your client directory and retry, e.g.

    WOW_DIR="$HOME/Games/World of Warcraft 3.3.5a" ./deploy.sh
MSG
    exit 1
fi

DEST="$WOW/Interface/AddOns/BuffScribe"
mkdir -p "$DEST"
rsync -a --delete \
    --exclude 'deploy.sh' \
    --exclude 'README.md' \
    --exclude '.git' \
    --exclude '.gitignore' \
    "$SRC"/ "$DEST"/

echo "BuffScribe deployed to $DEST"
echo "Reload the UI with /reload, or restart the client if it was not running."
