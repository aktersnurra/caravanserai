#!/bin/sh
# Unprivileged OCaml worker for verified, privately staged immutable source and
# opam repository snapshots. Caller verifies both snapshots before execution.
# SOURCE PROJECT_SUBDIR DUNE_TARGET RELEASE OUTPUT COMPILER REPOSITORY [WEB]
# WEB, when given, is a flat web bundle the controller built; it ships as
# share/web beside bin/.
# SERAI_OPAM_ROOT, when set, is the build jail's opam root: created on first
# use, reused with its switch when the dependency cache restored it, and kept.
# Otherwise the root is private to this run and removed with it.
# No install, service operation, migration, or use of the user's switch.
set -eu
source_dir=${1:?source required}
project=${2:?project subdirectory required}
target=${3:?dune target required}
release=${4:?release name required}
output=${5:?output required}
compiler=${6:?exact compiler package required}
repository=${7:?verified repository snapshot required}
web=${8:-}
refuse() { echo 'OCaml worker: invalid or unsafe input' >&2; exit 1; }
relative_path() {
    case "$1" in ''|/*|*/|*//*|*[!a-zA-Z0-9_./-]*) return 1 ;; esac
    old_ifs=$IFS; IFS=/; set -- $1; IFS=$old_ifs
    for component do case "$component" in .|..) return 1 ;; esac; done
}
for path in "$source_dir" "$output" "$repository"; do
    case "$path" in /*) ;; *) refuse ;; esac
done
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] || refuse
[ -d "$repository" ] && [ ! -L "$repository" ] && [ -f "$repository/repo" ] || refuse
opam_root=${SERAI_OPAM_ROOT:-}
if [ -n "$opam_root" ]; then
    case "$opam_root" in /*) ;; *) refuse ;; esac
    if [ -e "$opam_root" ] || [ -L "$opam_root" ]; then
        [ -d "$opam_root" ] && [ ! -L "$opam_root" ] &&
            [ -d "$opam_root/artifact" ] && [ ! -L "$opam_root/artifact" ] || refuse
    fi
fi
if [ -n "$web" ]; then
    case "$web" in /*) ;; *) refuse ;; esac
    [ -d "$web" ] && [ ! -L "$web" ] || refuse
    # Regular files with plain names only: no directory, link or hidden file.
    [ -z "$(find "$web" -mindepth 1 \( ! -type f -o -name '.*' -o -name '*[!a-zA-Z0-9._-]*' \) -print)" ] || refuse
    [ -n "$(find "$web" -mindepth 1 -print)" ] || refuse
fi
[ ! -e "$output" ] && [ ! -L "$output" ] || refuse
[ "$project" = . ] || relative_path "$project" || refuse
relative_path "$target" || refuse
case "$release" in ''|*[!a-z0-9_]*) refuse ;; esac
case "$compiler" in ''|-*|*[!a-zA-Z0-9_.+-]*) refuse ;; esac
case "$compiler" in ocaml-base-compiler.[0-9]*|ocaml-variants.[0-9]*) ;; *) refuse ;; esac
[ "$(id -u)" -ne 0 ] || refuse
project_dir=$source_dir/$project
[ -d "$project_dir" ] && [ ! -L "$project_dir" ] && [ -f "$project_dir/dune-project" ] || refuse
file_sha256() {
    case "${SHA256_KIND:-freebsd}" in
        freebsd) sha256 -q "$1" ;;
        linux) set -- "$(sha256sum "$1")" && printf '%s\n' "${1%% *}" ;;
        *) return 1 ;;
    esac
}
umask 077
stage=$output.tmp.$$
mkdir "$stage"
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
OPAMROOT=${opam_root:-$stage/opam}
OPAMREQUIRECHECKSUMS=true
export OPAMROOT OPAMREQUIRECHECKSUMS
unset OPAMSWITCH OPAM_SWITCH_PREFIX OPAMROOTISOK SERAI_OPAM_ROOT
if [ ! -d "$OPAMROOT/artifact" ]; then
    opam init --bare --no-setup --disable-sandboxing -y default "$repository"
    opam switch create artifact "$compiler" --repos=default -y
fi
cd "$project_dir"
opam install . --deps-only --switch=artifact -y
opam exec --switch=artifact -- dune build --profile release "$target"
binary=$project_dir/_build/default/$target
[ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || refuse
mkdir -p "$stage/result" "$stage/payload/bin"
# Runtime shared libraries must be checked against the target's verified base
# and package closure by the host adapter. Never assume the executable static.
ldd "$binary" >"$stage/result/linkage"
if grep -Eq 'not found|undefined symbol|unresolved' "$stage/result/linkage"; then refuse; fi
# A resolved dependency is still unusable if cleanup removes its provider.
while IFS= read -r line; do
    case "$line" in *'=>'*)
        case "$line" in *"$stage/"*|*"$OPAMROOT/"*|*"$source_dir/"*|*"$repository/"*) refuse ;; esac ;;
    esac
done <"$stage/result/linkage"
opam list --switch=artifact --installed --columns=name,version --short \
    --separator="$(printf '\t')" --color=never >"$stage/opam-packages.raw"
# opam pads display columns even with --short and a tab separator.
awk 'BEGIN { OFS="\t" } NF != 2 { exit 1 } { print $1, $2 }' \
    "$stage/opam-packages.raw" >"$stage/result/opam-packages"
grep -Fx "${compiler%%.*}$(printf '\t')${compiler#*.}" "$stage/result/opam-packages" >/dev/null || refuse
mkdir "$stage/payload/.infra-build"
cp "$stage/result/opam-packages" "$stage/result/linkage" "$stage/payload/.infra-build/"
if [ -n "$web" ]; then
    mkdir -p "$stage/payload/share/web"
    for file in "$web"/*; do
        name=${file##*/}
        cp "$file" "$stage/payload/share/web/$name"
        chmod 644 "$stage/payload/share/web/$name"
        printf '%s\t%s\n' "$(file_sha256 "$file")" "$name" >>"$stage/payload/.infra-build/web-bundle"
    done
fi
cp "$binary" "$stage/payload/bin/$release"
chmod 755 "$stage/payload/bin/$release"
tar -cf "$stage/result/release.tar" -C "$stage/payload" .
archive_sha256=$(file_sha256 "$stage/result/release.tar") || refuse
case "$archive_sha256" in ''|*[!0-9a-f]*) refuse ;; esac
[ "${#archive_sha256}" -eq 64 ] || refuse
printf '%s\n' "$archive_sha256" >"$stage/result/release.sha256"
mv "$stage/result" "$output"
# The trap removes only this worker's new private opam root and payload stage.
