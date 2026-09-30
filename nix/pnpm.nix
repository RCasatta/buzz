# pnpm at the exact version package.json pins through `packageManager`.
# nixpkgs lags behind, and pnpm-workspace.yaml uses pnpm 11 settings
# (`allowBuilds`) that older releases ignore.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs_24,
}:

let
  packageManager = (lib.importJSON ../package.json).packageManager;
  version = lib.removePrefix "pnpm@" packageManager;
in
assert lib.assertMsg (
  version == "11.4.0"
) "package.json now pins ${packageManager}; update the version and hash in nix/pnpm.nix";
stdenvNoCC.mkDerivation {
  pname = "pnpm";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
    hash = "sha256-50EGpaDrJWn0WDUEQg6tX8HCY+QXoyFsqxy+DM3LTq4=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules/pnpm $out/bin
    cp -r . $out/lib/node_modules/pnpm
    for bin in pnpm pnpx; do
      makeWrapper ${lib.getExe nodejs_24} $out/bin/$bin \
        --add-flags $out/lib/node_modules/pnpm/bin/$bin.mjs
    done
    runHook postInstall
  '';

  meta = {
    description = "Fast, disk space efficient package manager";
    homepage = "https://pnpm.io";
    license = lib.licenses.mit;
    mainProgram = "pnpm";
  };
}
