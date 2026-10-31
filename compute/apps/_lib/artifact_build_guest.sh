#!/bin/sh
# A guest workload's unprivileged Linux adapter. Caller verifies helper bytes
# before use. PROJECT, TARGET and RELEASE are the guest's declared workload;
# artifact_build_ocaml.sh validates them.
# SOURCE INVENTORY INVENTORY_SHA REPOSITORY REPO_INVENTORY REPO_SHA COMPILER OUTPUT
#   PROJECT TARGET RELEASE
set -eu
[ "$#" -eq 11 ] || exit 1
source_dir=$1
inventory=$2
inventory_sha=$3
repository=$4
repository_inventory=$5
repository_sha=$6
compiler=$7
output=$8
project=$9
target=${10}
release=${11}
refuse() { echo 'guest artifact build: invalid or unsafe input' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || refuse
[ "$(uname -s)" = Linux ] || refuse
case "$compiler" in ocaml-variants.[0-9]*) ;; *) refuse ;; esac
case "$compiler" in *[!a-zA-Z0-9_.+-]*) refuse ;; esac
case "$output" in /*) ;; *) refuse ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || refuse
script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SHA256_KIND=linux SHA256_BIN=sha256sum STAT_KIND=linux \
 sh "$script_dir/artifact_verify_source.sh" "$source_dir" "$inventory" "$inventory_sha"
SHA256_KIND=linux SHA256_BIN=sha256sum STAT_KIND=linux \
 sh "$script_dir/artifact_verify_source.sh" "$repository" "$repository_inventory" "$repository_sha"
architecture=$(uname -m)
case "$architecture" in x86_64|aarch64) ;; *) refuse ;; esac
libc=$(getconf GNU_LIBC_VERSION) || refuse
case "$libc" in 'glibc '[0-9]*) libc=${libc#glibc } ;; *) refuse ;; esac
case "$libc" in *[!0-9.]*) refuse ;; esac
# Never use the guest's existing opam switch, home build tree or service.
SHA256_KIND=linux sh "$script_dir/artifact_build_ocaml.sh" "$source_dir" "$project" \
 "$target" "$release" "$output" "$compiler" "$repository"
printf 'Linux:%s:glibc_%s\n' "$architecture" "$libc" >"$output/target-abi"
# Repository input identity, not a fabricated package archive/version.
IFS= read -r header <"$repository_inventory"
commit=${header#*"$(printf '\t')"}
printf 'opam-repository\t%s\t%s\n' "$commit" "$repository_sha" >"$output/dependencies"
