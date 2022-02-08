#! /bin/bash

# abort on all errors
set -e

if [ "$DEBUG" != "" ]; then
    set -x
fi

script=$(readlink -f "$0")

show_usage() {
    echo "Usage: $script --appdir <path to AppDir>"
    echo
    echo "Bundles GStreamer plugins into an AppDir"
    echo
    echo "Required variables:"
    echo "  LINUXDEPLOY=\".../linuxdeploy\" path to linuxdeploy (e.g., AppImage); set automatically when plugin is run directly by linuxdeploy"
    echo
    echo "Optional variables:"
    echo "  GSTREAMER_INCLUDE_BAD_PLUGINS=\"1\" (default: disabled; set to empty string or unset to disable)"
    echo "  GSTREAMER_PLUGINS_DIR=\"...\" (directory containing GStreamer plugins; default: guessed based on main distro architecture)"
    echo "  GSTREAMER_HELPERS_DIR=\"...\" (directory containing GStreamer helper tools like gst-plugin-scanner; default: guessed based on main distro architecture)"
    echo "  GSTREAMER_VERSION=\"1.0\" (default: 1.0)"
}

while [ "$1" != "" ]; do
    case "$1" in
        --plugin-api-version)
            echo "0"
            exit 0
            ;;
        --appdir)
            APPDIR="$2"
            shift
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Invalid argument: $1"
            echo
            show_usage
            exit 1
            ;;
    esac
done

if [ "$APPDIR" == "" ]; then
    show_usage
    exit 1
fi

if ! which patchelf &>/dev/null && ! type patchelf &>/dev/null; then
    echo "Error: patchelf not found"
    echo
    show_usage
    exit 2
fi

if [[ "$LINUXDEPLOY" == "" ]]; then
    echo "Error: \$LINUXDEPLOY not set"
    echo
    show_usage
    exit 3
fi

mkdir -p "$APPDIR"

export GSTREAMER_VERSION="${GSTREAMER_VERSION:-1.0}"

if [ "$GSTREAMER_PLUGINS_DIR" != "" ]; then
    plugins_dir="${GSTREAMER_PLUGINS_DIR}"
else
    for i in "/lib" "/usr/lib"; do
        if [ -d "$i/$(uname -m)-linux-gnu/gstreamer-$GSTREAMER_VERSION" ]; then
	    plugins_dir=$i/$(uname -m)-linux-gnu/gstreamer-"$GSTREAMER_VERSION"
        elif [ -d $i/gstreamer-"$GSTREAMER_VERSION" ]; then
	    plugins_dir=$i/gstreamer-"$GSTREAMER_VERSION"
	fi
    done
    if [ ! -d "$plugins_dir" ]; then
	for i in "/lib$(getconf LONG_BIT)" "/usr/lib$(getconf LONG_BIT)"; do
            [ -d "$i/gstreamer-$GSTREAMER_VERSION" ] && plugins_dir=$i/gstreamer-"$GSTREAMER_VERSION"
        done
    fi
fi

if [ ! -d "$plugins_dir" ]; then
    echo "Error: could not find plugins directory: $plugins_dir"
    exit 1
else
    plugins_dir=$(readlink -f "$plugins_dir")
fi

if [ "$GSTREAMER_HELPERS_DIR" != "" ]; then
    helpers_dir="${GSTREAMER_HELPERS_DIR}"
else
    helpers_dir=$plugins_dir/gstreamer-"$GSTREAMER_VERSION"
fi

plugins_target_dir="$APPDIR"/${plugins_dir#"/"}
helpers_target_dir="$APPDIR"/${helpers_dir#"/"}

mkdir -p "$plugins_target_dir"

echo "Copying plugins into $plugins_target_dir"
for i in "$plugins_dir"/*; do
    [ -d "$i" ] && continue
    [ ! -f "$i" ] && echo "File does not exist: $i" && continue

    echo "Copying plugin: $i"
    cp "$i" "$plugins_target_dir"
done

"$LINUXDEPLOY" --appdir "$APPDIR"

for i in "$plugins_target_dir"/*; do
    [ -d "$i" ] && continue
    [ ! -f "$i" ] && echo "File does not exist: $i" && continue
    (file "$i" | grep -v ELF --silent) && echo "Ignoring non ELF file: $i" && continue

    echo "Manually setting rpath for $i"
    patchelf --set-rpath '$ORIGIN/..:$ORIGIN' "$i"
done

mkdir -p "$helpers_target_dir"

echo "Copying helpers in $helpers_target_dir"
for i in "$helpers_dir"/*; do
    [ -d "$i" ] && continue
    [ ! -f "$i" ] && echo "File does not exist: $i" && continue

    echo "Copying helper: $i"
    cp "$i" "$helpers_target_dir"
done

for i in "$helpers_target_dir"/*; do
    [ -d "$i" ] && continue
    [ ! -f "$i" ] && echo "File does not exist: $i" && continue
    (file "$i" | grep -v ELF --silent) && echo "Ignoring non ELF file: $i" && continue

    echo "Manually setting rpath for $i"
    patchelf --set-rpath '$ORIGIN/../..' "$i"
done

echo "Installing AppRun hook"
mkdir -p "$APPDIR"/apprun-hooks

if [ "$GSTREAMER_VERSION" == "1.0" ]; then
    cat > "$APPDIR"/apprun-hooks/linuxdeploy-plugin-gstreamer.sh <<EOF
#! /bin/bash

export GST_REGISTRY_REUSE_PLUGIN_SCANNER="no"
export GST_PLUGIN_SYSTEM_PATH_1_0="\${APPDIR}/${plugins_dir#"/"}"
export GST_PLUGIN_PATH_1_0="\${APPDIR}/${plugins_dir#"/"}"

export GST_PLUGIN_SCANNER_1_0="\${APPDIR}/${helpers_dir#"/"}/gst-plugin-scanner"
export GST_PTP_HELPER_1_0="\${APPDIR}/${helpers_dir#"/"}/gst-ptp-helper"
EOF
elif [ "$GSTREAMER_VERSION" == "0.10" ]; then
    cat > "$APPDIR"/apprun-hooks/linuxdeploy-plugin-gstreamer.sh <<EOF
#! /bin/bash

export GST_REGISTRY_REUSE_PLUGIN_SCANNER="no"
export GST_PLUGIN_SYSTEM_PATH_0_10="\${APPDIR}/${plugins_dir#"/"}"

export GST_PLUGIN_SCANNER_0_10="\${APPDIR}/${helpers_dir#"/"}/gst-plugin-scanner"
export GST_PTP_HELPER_0_10="\${APPDIR}/${helpers_dir#"/"}/gst-ptp-helper"
EOF
else
    echo "Warning: unknown GStreamer version: $GSTREAMER_VERSION, cannot install AppRun hook"
fi
