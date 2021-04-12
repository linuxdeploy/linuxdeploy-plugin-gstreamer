# linuxdeploy-plugin-gstreamer

GStreamer plugin for linuxdeploy. Copies GStreamer plugins into an AppDir, and installs an AppRun hook to make GStreamer load these instead of ones on the system.

## Usage

```bash
# get linuxdeploy and linuxdeploy-plugin-gstreamer.sh (see below for more information)
# call through linuxdeploy
> ./linuxdeploy-x86_64.AppImage --appdir AppDir --plugin gstreamer --output appimage --icon mypackage.png --desktop-file mypackage.desktop
```
