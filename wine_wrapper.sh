#!/usr/bin/env bash
#
# Launch Xiaomi PC Manager from an unpacked payload under Wine.
#
# The app is not installed into the prefix — it runs from the deployed payload
# directory, so only that directory needs to exist alongside the prefix.
#
# Note: the wtsapi32 compatibility DLL is a third-party artefact and is not
# included here. Drop it in as $APP_DIR/wtsapi32.dll before running, or the
# host-model check will fail.
set -euo pipefail

BASE="${MIPC_BASE:-$HOME/.local/share/mipcmanager}"
WINE_PREFIX="${BASE}/wine"
APP_DIR="${BASE}/app"
# Point this at the unpacked 05_main segment from the installer.
SRC_DIR="${MIPC_SRC:-}"

log() { echo -e "\033[0;32m[mipc]\033[0m $*"; }
err() { echo -e "\033[0;31m[mipc]\033[0m $*" >&2; }

setup() {
    [[ -n "$SRC_DIR" ]] || { err "set MIPC_SRC to the unpacked 05_main directory"; exit 1; }

    log "Creating minimal Wine prefix at $WINE_PREFIX"
    export WINEPREFIX="$WINE_PREFIX" WINEARCH=win64
    wineboot --init 2>/dev/null || true

    log "Deploying payload"
    mkdir -p "$APP_DIR"
    rsync -a "$SRC_DIR/" "$APP_DIR/"

    log "Deploying wtsapi32 compatibility DLL, if present"
    for cand in "$SRC_DIR/wtsapi32.dll" "${BASE}/wtsapi32.dll"; do
        if [[ -f "$cand" ]]; then
            cp "$cand" "$APP_DIR/wtsapi32.dll"
            log "  <- $cand"
            break
        fi
    done

    find "$APP_DIR" -name '*.exe' -exec chmod +x {} +
    log "Setup complete"
}

run_app() {
    export WINEPREFIX="$WINE_PREFIX"
    export WINEARCH=win64
    export WINEDEBUG=-all
    # wtsapi32: host-model check. msimg32: version/model probe.
    export WINEDLLOVERRIDES="wtsapi32=n,b;msimg32=n,b;${WINEDLLOVERRIDES:-}"

    cd "$APP_DIR"
    log "Starting XiaomiPcManager.exe (expect an abort on NtCreateWaitCompletionPacket)"
    exec wine XiaomiPcManager.exe "$@"
}

case "${1:-run}" in
    setup)    setup ;;
    run)      run_app "$@" ;;
    uninstall) rm -rf "$WINE_PREFIX" "$APP_DIR"; log "Removed" ;;
    *)        echo "Usage: $0 {setup|run|uninstall}"; exit 1 ;;
esac
