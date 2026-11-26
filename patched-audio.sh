#!/usr/bin/env bash
# Run a patched COSMIC sound applet (per-application volume sliders) in
# place of the system one, without touching /usr. No sudo needed.
#
#   ./patched-audio.sh install    build branch `app-volume` and switch the panel to it
#   ./patched-audio.sh update     move the patch onto the installed cosmic-applets
#                                 release tag, then rebuild and install
#   ./patched-audio.sh status     compare patched build with system cosmic-applets
#   ./patched-audio.sh uninstall  go back to the system applet
#
# How it works: cosmic-panel uses the first desktop entry it finds for an
# applet ID, and ~/.local/share/applications comes before /usr/share. A user
# copy of com.system76.CosmicAppletAudio.desktop pointing at the patched
# binary therefore replaces the system applet in the existing panel slot.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
branch="app-volume"
appid="com.system76.CosmicAppletAudio"
bin="$prefix/bin/cosmic-applet-audio-patched"
desktop="$prefix/share/applications/$appid.desktop"
stamp="$prefix/share/cosmic-applet-audio-patched.version"

system_version() {
    # "1:1.11.0-1.1" -> "1.11.0"
    pacman -Q cosmic-applets | awk '{print $2}' | sed -E 's/^[0-9]+://; s/-[^-]*$//'
}

restart_applet() {
    # cosmic-panel does not respawn a killed applet, but it re-reads desktop
    # entries and restarts applets when its applet list changes. Drop the
    # sound applet from the list for a moment, then put the file back.
    local wings="$HOME/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings"
    grep -q "\"$appid\"" "$wings" 2>/dev/null || return 0
    local saved
    saved="$(cat "$wings")"
    sed -i "/\"$appid\",/d" "$wings"
    sleep 1.5
    printf '%s' "$saved" > "$wings"
}

install_patched() {
    git -C "$repo" switch -q "$branch"
    cargo build --release --manifest-path "$repo/Cargo.toml" -p cosmic-applet-audio
    install -Dm0755 "$repo/target/release/cosmic-applet-audio" "$bin"
    install -Dm0644 "/usr/share/applications/$appid.desktop" "$desktop"
    sed -i "s|^Exec=.*|Exec=$bin|" "$desktop"
    git -C "$repo" describe --tags --abbrev=0 HEAD > "$stamp"
    restart_applet
    echo "Installed patched sound applet ($(cat "$stamp"))."
}

case "${1:-}" in
    install)
        install_patched
        ;;
    update)
        ver="$(system_version)"
        tag="epoch-$ver"
        git -C "$repo" fetch -q --depth 1 origin tag "$tag"
        if [[ "$(git -C "$repo" describe --tags --abbrev=0 "$branch")" == "$tag" ]]; then
            echo "Patch already on $tag."
        else
            patch="$(git -C "$repo" rev-parse "$branch")"
            git -C "$repo" switch -q --detach "$tag"
            if ! git -C "$repo" cherry-pick "$patch"; then
                echo "Patch conflicts with $tag. Resolve, then: git cherry-pick --continue &&" \
                    "git branch -f $branch HEAD && git switch $branch && $0 install" >&2
                exit 1
            fi
            git -C "$repo" branch -f "$branch" HEAD
            echo "Patch moved onto $tag."
        fi
        install_patched
        ;;
    status)
        built="$(cat "$stamp" 2>/dev/null || echo none)"
        sys="epoch-$(system_version)"
        echo "patched build: $built"
        echo "system:        $sys"
        [[ "$built" == "$sys" ]] && echo "Up to date." || echo "Out of date: run $0 update"
        ;;
    uninstall)
        rm -f "$bin" "$desktop" "$stamp"
        restart_applet
        echo "Removed. Panel uses the system sound applet again."
        ;;
    *)
        sed -n '2,13p' "$0"
        exit 1
        ;;
esac
