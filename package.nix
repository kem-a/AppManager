{ lib
, stdenv
, meson
, ninja
, pkg-config
, vala
, desktop-file-utils
, wrapGAppsHook4
, gobject-introspection
, makeWrapper
, gtk4
, libadwaita
, glib
, json-glib
, libgee
, libsoup_3
, libsecret
, gnutls
, zstd
, squashfsTools
, squashfuse
, dwarfs
, zsync
}:

stdenv.mkDerivation(finalAttrs: {
  pname = "app-manager";
  version = let
  	match = builtins.match ".*version: '([0-9.]+)'.*" (builtins.readFile ./meson.build);
  in lib.head match;

  src = ./.;

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    vala
    desktop-file-utils
    gobject-introspection
    wrapGAppsHook4
    makeWrapper
  ];

  buildInputs = [
    gtk4
    libadwaita
    glib
    json-glib
    libgee
    libsoup_3
    libsecret
    gnutls
    zstd
  ];

  mesonFlags = [
    "-Dbundle_dwarfs=false"
    "-Dbundle_zsync=false"
    "-Dbundle_unsquashfs=false"
  ];

  dontWrapGApps = true;

  postFixup = let
    binPath = lib.makeBinPath [
      squashfsTools
      squashfuse
      dwarfs
      zsync
    ];
  in ''
    wrapProgram $out/bin/app-manager \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : "${binPath}:/run/wrappers/bin"
  '';

  meta = {
    description = "MacOS-style AppImage installer and manager for Linux";
    homepage = "https://github.com/kem-a/AppManager";
    license = lib.licenses.gpl3Plus;
    maintainers = [ ];
    platforms = lib.platforms.linux;
    mainProgram = "app-manager";
  };
})
