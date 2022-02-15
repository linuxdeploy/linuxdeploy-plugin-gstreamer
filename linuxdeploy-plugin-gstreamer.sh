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
    # remove additional slash"/", to prevent duplicate slash output in AppRun-hook
    plugins_dir="${GSTREAMER_PLUGINS_DIR%"/"}"
else
    for i in "/lib" "/usr/lib"; do
        if [ -d "$i/$(uname -m)-linux-gnu/gstreamer-$GSTREAMER_VERSION" ]; then
	    plugins_dir=$i/$(uname -m)-linux-gnu/gstreamer-"$GSTREAMER_VERSION"
        elif [ -d $i/gstreamer-"$GSTREAMER_VERSION" ]; then
	    plugins_dir=$i/gstreamer-"$GSTREAMER_VERSION"
	fi
    done
    # if not found gstreamer plugin directory in /lib and /usr/lib,
    # try to find it in /lib32 and /usr/lib32(if using 32-bit linux), or /lib64 and /usr/lib64(if using 64-bit linux)
    if [ ! -d "$plugins_dir" ]; then
        # as far as I know, $(getconf LONG_BIT) indicates the default C compiling environment is 32 or 64 bit.
	# it is usually the same with kernel, but not always. I only tested in archlinux distro.
	# in this case, due to gstreamer is a C program,
	# if $(getconf LONG_BIT) output "32", we assume the default gstreamer is 32-bit version.
	for i in "/lib$(getconf LONG_BIT)" "/usr/lib$(getconf LONG_BIT)"; do
            [ -d "$i/gstreamer-$GSTREAMER_VERSION" ] && plugins_dir=$i/gstreamer-"$GSTREAMER_VERSION"
        done
    fi
fi

# /lib /usr/lib /lib32 /lib64 ... may be a symlink,
# convert to the realpath to keep the same structure between AppDir and local system.
plugins_dir=$(readlink -f "$plugins_dir")
if [ ! -d "$plugins_dir" ]; then
    echo "Error: could not find plugins directory: $plugins_dir"
    exit 1
fi

if [ "$GSTREAMER_HELPERS_DIR" != "" ]; then
    # remove additional slash"/", to prevent duplicate slash output in AppRun-hook
    helpers_dir="${GSTREAMER_HELPERS_DIR%"/"}"
else
    if [ -f "$plugins_dir/gstreamer-$GSTREAMER_VERSION/gst-plugin-scanner" ]; then
        helpers_dir=$plugins_dir/gstreamer-"$GSTREAMER_VERSION"
    elif [ -f "$plugins_dir/gst-plugin-scanner" ]; then
        helpers_dir=$plugins_dir
    else
        echo "Error: could not find gst-plugin-scanner"
        echo "Error: failed to locate gstreamer helpers directory automatically"
        echo "Error: please consider specifing \$GSTREAMER_HELPERS_DIR"
    fi
fi

# path may include symlink directory,
# convert to the realpath to keep the same structure between AppDir and local system.
helpers_dir=$(readlink -f "$helpers_dir")
if [ ! -d "$helpers_dir" ]; then
    echo "Error: could not find helpers directory: $helpers_dir"
    # in the original project, the process will exit if plugins_dir is not found,
    # but still process if only the helpers is not found.
    # I am not sure if this is correct, so I keep the same setting at this moment.
    #exit 1
fi

# below three statements are the same thing:
# "$APPDIR""$plugins_dir"
# "$APPDIR"/${plugins_dir#/}
# "$APPDIR"/${plugins_dir#"/"}
# I choose the third one because it can let me easily know the directory is under AppDir.
# same reason below when output the apprun-hook.
plugins_target_dir="$APPDIR"/${plugins_dir#"/"}
helpers_target_dir="$APPDIR"/${helpers_dir#"/"}

mkdir -p "$plugins_target_dir"

[ "$plugins_dir" != "$helpers_dir" ] && echo "Copying plugins into $plugins_target_dir"
[ "$plugins_dir" = "$helpers_dir" ] && echo "Copying plugins and helpers into $plugins_target_dir"
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

# $helpers_dir may be empty if helpers not found and $GSTREAMER_HELPERS_DIR not set in previous steps.
if [ -n "$helpers_dir" ] && [ "$helpers_dir" != "$plugins_dir" ]; then
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
fi

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
