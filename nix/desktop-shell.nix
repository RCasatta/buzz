# Development shell for the native Tauri desktop app (`just desktop-standalone`)
# on NixOS. Mirrors the Hermit toolchain (bin/) and the Linux libraries CI
# installs for Tauri (.github/workflows/_ci-desktop.yml) that this build links.
# CI also installs libayatana-appindicator and librsvg; neither is linked, and
# the tray that would dlopen appindicator is only created on macOS.
{
  mkShell,
  rustToolchain,
  pnpm,
  nodejs_24,
  just,
  git,
  python3,
  pkg-config,
  gtk3,
  glib,
  glib-networking,
  gsettings-desktop-schemas,
  webkitgtk_4_1,
  libsoup_3,
  alsa-lib,
  dbus,
  libopus,
  gst_all_1,
}:

mkShell {
  packages = [
    rustToolchain
    nodejs_24
    pnpm
    just
    git
    # scripts/instance-env.sh derives per-worktree ports with python3.
    python3
  ];

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [
    # Tauri / wry
    gtk3
    glib
    webkitgtk_4_1
    libsoup_3
    gsettings-desktop-schemas
    # Native crates in desktop/src-tauri: cpal (ALSA), keyring (D-Bus Secret
    # Service), audiopus_sys (system opus via pkg-config, so no CMake build).
    alsa-lib
    dbus
    libopus
    # WebKitGTK plays notification sounds and attachments and records voice
    # notes through GStreamer; its setup hook fills GST_PLUGIN_SYSTEM_PATH_1_0.
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-libav
  ];

  # Tells Justfile recipes to keep this shell's toolchain instead of Hermit's
  # downloaded binaries, which cannot run on NixOS.
  BUZZ_NIX_DEV_SHELL = "1";

  # TLS for WebKit's network stack.
  GIO_EXTRA_MODULES = "${glib-networking}/lib/gio/modules";

  # GTK needs the GSettings schemas (file chooser, settings portal) that the
  # glib setup hook collected for the buildInputs above.
  #
  # A host LD_LIBRARY_PATH (for example a NixOS session exporting a system
  # alsa-lib) overrides the binaries' RUNPATH and loads libraries built against
  # a different glibc, so the app fails to start. Everything here resolves
  # through RUNPATH, so drop it.
  shellHook = ''
    unset LD_LIBRARY_PATH
    export XDG_DATA_DIRS="$GSETTINGS_SCHEMAS_PATH''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
  '';
}
