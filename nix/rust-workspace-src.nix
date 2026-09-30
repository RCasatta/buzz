# Source for crane builds of the root Rust workspace: only what it compiles
# from, so desktop, web, and mobile edits do not rebuild server-side packages.
# `migrations/` is embedded by buzz-db.
{ lib }:

lib.fileset.toSource {
  root = ../.;
  fileset = lib.fileset.unions [
    ../Cargo.toml
    ../Cargo.lock
    ../.cargo/config.toml
    ../crates
    ../examples
    ../migrations
  ];
}
