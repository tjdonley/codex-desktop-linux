#!/bin/bash
# Bundled-plugin staging — Browser Use, Chrome, Linux Computer Use, manifests, marketplace.
#
# Sourced by install.sh. Do not run directly.
# shellcheck shell=bash

# Resolve sibling helpers from this source file instead of the caller's
# working directory. The update-builder copies the helpers together.
BUNDLED_PLUGIN_CONTAINMENT_HELPER="$(
    CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)/plugin-containment.js"

remove_bundled_plugin_tree_safely() {
    local path="$1"

    if declare -F remove_tree_safely >/dev/null 2>&1; then
        remove_tree_safely "$path"
        return
    fi

    [ -e "$path" ] || [ -L "$path" ] || return 0
    chmod -R u+w "$path" 2>/dev/null || true
    rm -rf -- "$path"
}

# ---- Install Linux-safe bundled plugin resources ----
list_portable_bundled_plugins() {
    local marketplace="$1"

    node - "$marketplace" <<'NODE'
const fs = require("fs");
const path = require("path");

const marketplacePath = process.argv[2];
const marketplace = JSON.parse(fs.readFileSync(marketplacePath, "utf8"));
const plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];
const portableNames = new Set(["sites", "deep-research", "visualize"]);
const emittedNames = new Set();

for (const plugin of plugins) {
  if (plugin == null || typeof plugin !== "object" || !portableNames.has(plugin.name)) {
    continue;
  }
  const source = plugin.source;
  if (source == null || source.source !== "local" || typeof source.path !== "string") {
    continue;
  }
  const normalized = path.posix.normalize(source.path.replace(/\\/g, "/"));
  if (normalized === `plugins/${plugin.name}` && !emittedNames.has(plugin.name)) {
    emittedNames.add(plugin.name);
    process.stdout.write(`${plugin.name}\n`);
  }
}
NODE
}

validate_portable_bundled_plugin() {
    local plugin_dir="$1"
    local expected_name="$2"

    python3 - "$plugin_dir" "$expected_name" <<'PY'
import json
import os
from pathlib import Path
import re
import stat
import sys

root = Path(sys.argv[1])
expected_name = sys.argv[2]
manifest_path = root / ".codex-plugin" / "plugin.json"

if root.is_symlink():
    print("plugin root cannot be a symlink", file=sys.stderr)
    sys.exit(1)
if not root.is_dir():
    print("plugin root must be a directory", file=sys.stderr)
    sys.exit(1)
if manifest_path.is_symlink():
    print("plugin manifest cannot be a symlink", file=sys.stderr)
    sys.exit(1)

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    print(f"invalid plugin manifest: {exc}", file=sys.stderr)
    sys.exit(1)

if manifest.get("name") != expected_name:
    print("plugin manifest name does not match its marketplace entry", file=sys.stderr)
    sys.exit(1)
version = manifest.get("version")
if not isinstance(version, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", version.strip()) is None:
    print("plugin manifest version is missing or invalid", file=sys.stderr)
    sys.exit(1)

native_suffixes = {
    ".app",
    ".dll",
    ".dylib",
    ".exe",
    ".framework",
    ".node",
    ".so",
}
native_magics = {
    b"\x7fELF",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
}

def fail_walk(error):
    print(f"cannot inspect plugin tree: {error}", file=sys.stderr)
    sys.exit(1)


for current_root, directories, files in os.walk(root, followlinks=False, onerror=fail_walk):
    current = Path(current_root)
    for name in directories:
        path = current / name
        if path.is_symlink():
            print(f"symlink is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            metadata = path.lstat()
        except OSError as exc:
            print(f"cannot inspect {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if not stat.S_ISDIR(metadata.st_mode):
            print(f"non-directory entry is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if metadata.st_mode & 0o6000:
            print(f"privileged mode is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if path.suffix.lower() in native_suffixes:
            print(f"native bundle is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)

    for name in files:
        path = current / name
        if path.is_symlink():
            print(f"symlink is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            metadata = path.lstat()
        except OSError as exc:
            print(f"cannot inspect {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if not stat.S_ISREG(metadata.st_mode):
            print(f"non-regular file is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if metadata.st_mode & 0o6000:
            print(f"privileged mode is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if path.suffix.lower() in native_suffixes:
            print(f"native file is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            with path.open("rb") as stream:
                header = stream.read(4)
        except OSError as exc:
            print(f"cannot read {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if header in native_magics or header[:2] == b"MZ":
            print(f"native executable is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
PY
}

stage_portable_bundled_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local plugin_name="$3"
    local target_plugin="$target_plugins/$plugin_name"
    local staging_plugin=""
    local backup_plugin="$target_plugins/.${plugin_name}.backup.$$"

    if [ ! -d "$source_plugin" ]; then
        info "Portable bundled plugin $plugin_name not present in upstream app; skipping"
        return 1
    fi
    if ! validate_portable_bundled_plugin "$source_plugin" "$plugin_name"; then
        warn "Portable bundled plugin $plugin_name contains unsupported content; skipping"
        return 1
    fi

    if ! staging_plugin="$(mktemp -d "$target_plugins/.${plugin_name}.tmp.XXXXXX")"; then
        warn "Failed to create staging directory for portable bundled plugin $plugin_name"
        return 1
    fi
    if ! cp -R "$source_plugin/." "$staging_plugin/"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to stage portable bundled plugin $plugin_name"
        return 1
    fi
    if ! remove_macos_sidecar_files "$staging_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to clean macOS sidecar files for portable bundled plugin $plugin_name"
        return 1
    fi
    if ! validate_portable_bundled_plugin "$staging_plugin" "$plugin_name"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Portable bundled plugin $plugin_name failed post-copy validation"
        return 1
    fi

    if ! rm -rf -- "$backup_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to prepare backup for portable bundled plugin $plugin_name"
        return 1
    fi
    if [ -e "$target_plugin" ] || [ -L "$target_plugin" ]; then
        if ! mv -- "$target_plugin" "$backup_plugin"; then
            rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
            warn "Failed to preserve existing portable bundled plugin $plugin_name"
            return 1
        fi
    else
        backup_plugin=""
    fi
    if ! mv -- "$staging_plugin" "$target_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        if [ -n "$backup_plugin" ]; then
            if mv -- "$backup_plugin" "$target_plugin"; then
                warn "Failed to install portable bundled plugin $plugin_name; previous target was restored"
            else
                warn "Failed to install portable bundled plugin $plugin_name and previous target could not be restored"
            fi
        else
            warn "Failed to install portable bundled plugin $plugin_name"
        fi
        return 1
    fi
    if [ -n "$backup_plugin" ] && ! rm -rf -- "$backup_plugin"; then
        warn "Failed to clean previous portable bundled plugin backup: $backup_plugin"
    fi
    info "Portable bundled plugin $plugin_name staged from upstream DMG"
    return 0
}

find_cargo_for_linux_computer_use() {
    if command -v cargo >/dev/null 2>&1; then
        command -v cargo
        return 0
    fi

    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        echo "$HOME/.cargo/bin/cargo"
        return 0
    fi

    return 1
}

find_system_computer_use_binary() {
    local name="$1"
    local candidate

    for candidate in \
        "$HOME/.cargo/bin/$name" \
        "$HOME/.local/bin/$name"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    candidate="$(command -v "$name" 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

build_linux_computer_use_backend() {
    local crate_dir="$SCRIPT_DIR/computer-use-linux"
    local backend_binary="$SCRIPT_DIR/target/release/codex-computer-use-linux"
    local cosmic_helper_binary="$SCRIPT_DIR/target/release/codex-computer-use-cosmic"
    local cargo_cmd=""
    local system_backend=""
    local system_cosmic=""

    # Step 1: Environment override
    if [ -n "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || [ -n "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ]; then
        [ -n "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || warn "CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE is not set"
        [ -n "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ] || warn "CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE is not set"
        [ -x "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || return 1
        [ -x "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ] || return 1
        info "Using prebuilt Linux Computer Use backend"
        printf '%s\n%s\n' "$CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE" "$CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE"
        return 0
    fi

    # Steps 2-3 are opt-in: the vendored build stays the default so the
    # repository only ships code it is responsible for. Set
    # CODEX_LINUX_COMPUTER_USE_SYSTEM_INSTALL=1 to reuse a system-installed
    # computer-use-linux (or install it from crates.io) instead of building
    # the vendored crate.
    if [ "${CODEX_LINUX_COMPUTER_USE_SYSTEM_INSTALL:-}" = "1" ]; then
        # Step 2: System-installed binaries
        if system_backend="$(find_system_computer_use_binary computer-use-linux)" &&
            system_cosmic="$(find_system_computer_use_binary computer-use-linux-cosmic)"; then
            info "Using system computer-use-linux MCP binaries: $system_backend"
            printf '%s\n%s\n' "$system_backend" "$system_cosmic"
            return 0
        fi

        # Step 3: Install from crates.io
        if cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
            info "Installing computer-use-linux MCP from crates.io..."
            if "$cargo_cmd" install --locked computer-use-linux >&2; then
                if system_backend="$(find_system_computer_use_binary computer-use-linux)" &&
                    system_cosmic="$(find_system_computer_use_binary computer-use-linux-cosmic)"; then
                    printf '%s\n%s\n' "$system_backend" "$system_cosmic"
                    return 0
                fi
                warn "computer-use-linux binaries missing after crates.io install"
            else
                warn "Failed to install computer-use-linux from crates.io; falling back to vendored build"
            fi
        else
            warn "cargo not found for crates.io install; falling back to vendored build"
        fi
    fi

    # Step 4: Vendored build fallback
    if [ ! -d "$crate_dir" ]; then
        warn "Linux Computer Use backend source not found at $crate_dir"
        return 1
    fi

    if ! cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
        warn "cargo not found; Linux Computer Use plugin will be unavailable"
        return 1
    fi

    info "Building Linux Computer Use backend from vendored source..."
    if ! (cd "$SCRIPT_DIR" && "$cargo_cmd" build --release -p codex-computer-use-linux >&2); then
        warn "Failed to build Linux Computer Use backend"
        return 1
    fi

    [ -x "$backend_binary" ] || {
        warn "Linux Computer Use backend binary missing after build: $backend_binary"
        return 1
    }

    [ -x "$cosmic_helper_binary" ] || {
        warn "Linux Computer Use COSMIC helper binary missing after build: $cosmic_helper_binary"
        return 1
    }

    printf '%s\n%s\n' "$backend_binary" "$cosmic_helper_binary"
}

stage_linux_computer_use_plugin() {
    local target_plugins="$1"
    local plugin_template="$SCRIPT_DIR/plugins/openai-bundled/plugins/computer-use"
    local build_outputs=""
    local backend_binary=""
    local cosmic_helper_binary=""
    local target_plugin="$target_plugins/computer-use"

    if [ ! -d "$plugin_template" ]; then
        warn "Linux Computer Use plugin template not found at $plugin_template"
        return 1
    fi

    if ! build_outputs="$(build_linux_computer_use_backend)"; then
        return 1
    fi
    backend_binary="$(printf '%s\n' "$build_outputs" | sed -n '1p')"
    cosmic_helper_binary="$(printf '%s\n' "$build_outputs" | sed -n '2p')"

    rm -rf "$target_plugin"
    mkdir -p "$target_plugin"
    cp -R "$plugin_template/." "$target_plugin/"
    mkdir -p "$target_plugin/bin"
    cp "$backend_binary" "$target_plugin/bin/codex-computer-use-linux"
    cp "$cosmic_helper_binary" "$target_plugin/bin/codex-computer-use-cosmic"
    chmod 0755 "$target_plugin/bin/codex-computer-use-linux"
    chmod 0755 "$target_plugin/bin/codex-computer-use-cosmic"
    if [ "${backend_binary##*/}" = "computer-use-linux" ]; then
        # The published backend resolves its COSMIC helper by this sibling name.
        cp "$cosmic_helper_binary" "$target_plugin/bin/computer-use-linux-cosmic"
        chmod 0755 "$target_plugin/bin/computer-use-linux-cosmic"
    fi

    local plugin_icon_source="${LINUX_ICON_SOURCE:-$ICON_SOURCE}"
    if [ -f "$plugin_icon_source" ]; then
        mkdir -p "$target_plugin/assets"
        cp "$plugin_icon_source" "$target_plugin/assets/app-icon.png"
    fi

    find "$target_plugin" \( -name '*:com.apple.*' -o -name '.gitkeep' \) -delete
    return 0
}

browser_use_node_repl_elf_arch_profile() {
    local arch="$1"

    # Keep raw uname architecture names here. The first field is EI_CLASS,
    # followed by e_machine and the expected glibc interpreter when the full
    # ELF64 compatibility parser is available.
    case "$arch" in
        x86_64)
            printf '%s\n' '2|62|/lib64/ld-linux-x86-64.so.2'
            ;;
        aarch64)
            printf '%s\n' '2|183|/lib/ld-linux-aarch64.so.1'
            ;;
        armv7l|armv6l|armhf)
            printf '%s\n' '1|40|'
            ;;
        *)
            return 1
            ;;
    esac
}

is_host_linux_elf_executable() {
    local file="$1"
    local profile
    local expected_class
    local expected_machine
    local _expected_interpreter

    profile="$(browser_use_node_repl_elf_arch_profile "$ARCH")" || return 1
    IFS='|' read -r expected_class expected_machine _expected_interpreter <<< "$profile"

    python3 - "$file" "$expected_class" "$expected_machine" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
expected_class = int(sys.argv[2])
expected_machine = int(sys.argv[3])

try:
    size = path.stat().st_size
    if size > 128 * 1024 * 1024:
        sys.exit(1)
    with path.open("rb") as source:
        header = source.read(20)
except OSError:
    sys.exit(1)

if len(header) < 20 or header[:4] != b"\x7fELF":
    sys.exit(1)
if header[4] != expected_class or header[5] != 1 or header[6] != 1:
    sys.exit(1)

elf_type, machine = struct.unpack_from("<HH", header, 16)
sys.exit(0 if elf_type in (2, 3) and machine == expected_machine else 1)
PY
}

install_linux_executable_resource() {
    local source="$1"
    local destination="$2"
    local label="$3"
    local log_level="${4:-warn}"

    if [ ! -f "$source" ]; then
        if [ "$log_level" = "info" ]; then
            info "Browser Use $label not found in upstream resources; skipping"
        else
            warn "Browser Use $label not found in upstream resources; skipping"
        fi
        return 1
    fi

    if ! is_host_linux_elf_executable "$source"; then
        if [ "$log_level" = "info" ]; then
            info "Browser Use $label is not a Linux executable for $ARCH; skipping"
        else
            warn "Browser Use $label is not a Linux executable for $ARCH; skipping"
        fi
        return 1
    fi

    install -m 0755 "$source" "$destination"
}

patch_browser_use_node_repl_glibc_pidfd_symbols() {
    local file="$1"
    python3 - "$file" <<'PY'
import pathlib
import struct
import sys

# node_repl only needs these pidfd symbols opportunistically. Keeping their
# GLIBC_2.39 version binding makes the whole binary fail to load on glibc
# 2.34-2.38.

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def read_cstr(blob, offset):
    if offset < 0 or offset >= len(blob):
        return ""
    end = blob.find(b"\0", offset)
    if end == -1:
        end = len(blob)
    return blob[offset:end].decode("utf-8", "replace")


def elf_hash(name):
    value = 0
    for byte in name.encode("utf-8"):
        value = (value << 4) + byte
        high = value & 0xF0000000
        if high:
            value ^= high >> 24
            value &= ~high
    return value & 0xFFFFFFFF


if len(data) < 64 or data[:4] != b"\x7fELF":
    sys.exit(0)
if data[4] != 2 or data[5] != 1:
    sys.exit(0)

e_machine = struct.unpack_from("<H", data, 18)[0]
if e_machine != 62:
    sys.exit(0)

e_shoff = struct.unpack_from("<Q", data, 40)[0]
e_shentsize = struct.unpack_from("<H", data, 58)[0]
e_shnum = struct.unpack_from("<H", data, 60)[0]
e_shstrndx = struct.unpack_from("<H", data, 62)[0]

if e_shoff == 0 or e_shentsize < 64 or e_shnum == 0 or e_shstrndx >= e_shnum:
    sys.exit(0)
if e_shoff + (e_shnum * e_shentsize) > len(data):
    fail("ELF section table is outside file bounds")

sections = []
for index in range(e_shnum):
    offset = e_shoff + (index * e_shentsize)
    fields = struct.unpack_from("<IIQQQQIIQQ", data, offset)
    sections.append(
        {
            "name_offset": fields[0],
            "type": fields[1],
            "offset": fields[4],
            "size": fields[5],
            "link": fields[6],
            "entsize": fields[9],
        }
    )

shstr = sections[e_shstrndx]
shstr_data = data[shstr["offset"] : shstr["offset"] + shstr["size"]]
by_name = {
    read_cstr(shstr_data, section["name_offset"]): section for section in sections
}

dynsym = by_name.get(".dynsym")
dynstr = by_name.get(".dynstr")
versym = by_name.get(".gnu.version")
verneed = by_name.get(".gnu.version_r")
if not dynsym or not dynstr or not versym or not verneed:
    sys.exit(0)
if dynsym["entsize"] < 24:
    fail("ELF dynamic symbol table has an unsupported entry size")

dynstr_data = data[dynstr["offset"] : dynstr["offset"] + dynstr["size"]]
glibc_234_offset = dynstr_data.find(b"GLIBC_2.34\0")
if glibc_234_offset < 0:
    sys.exit(0)
glibc_234_name_offset = glibc_234_offset
glibc_234_hash = elf_hash("GLIBC_2.34")

version_names = {}
version_aux_offsets = {}
cursor = verneed["offset"]
end = verneed["offset"] + verneed["size"]
while cursor and cursor + 16 <= end:
    vn_version, vn_cnt, _vn_file, vn_aux, vn_next = struct.unpack_from(
        "<HHIII", data, cursor
    )
    if vn_version == 0 or vn_cnt == 0:
        break
    aux_cursor = cursor + vn_aux
    for _ in range(vn_cnt):
        if aux_cursor + 16 > end:
            fail("ELF version need auxiliary record is outside section bounds")
        _hash, _flags, other, name_offset, aux_next = struct.unpack_from(
            "<IHHII", data, aux_cursor
        )
        version_names[other] = read_cstr(dynstr_data, name_offset)
        version_aux_offsets[other] = aux_cursor
        if aux_next == 0:
            break
        aux_cursor += aux_next
    if vn_next == 0:
        break
    cursor += vn_next

target_names = {"pidfd_spawnp", "pidfd_getpid"}
target_version_ids = set()
non_target_glibc_239_refs = []
patched_symbols = 0
symbol_count = dynsym["size"] // dynsym["entsize"]
for index in range(symbol_count):
    symbol_offset = dynsym["offset"] + (index * dynsym["entsize"])
    if symbol_offset + 24 > len(data):
        fail("ELF dynamic symbol entry is outside file bounds")
    name_offset, info, _other, shndx = struct.unpack_from("<IBBH", data, symbol_offset)
    name = read_cstr(dynstr_data, name_offset)
    if not name:
        continue
    versym_offset = versym["offset"] + (index * 2)
    if versym_offset + 2 > versym["offset"] + versym["size"]:
        fail("ELF version symbol entry is outside section bounds")
    raw_version = struct.unpack_from("<H", data, versym_offset)[0]
    version_id = raw_version & 0x7FFF
    if version_names.get(version_id) != "GLIBC_2.39":
        continue
    bind = info >> 4
    is_weak_undefined = bind == 2 and shndx == 0
    if name in target_names and is_weak_undefined:
        struct.pack_into("<H", data, versym_offset, 1)
        target_version_ids.add(version_id)
        patched_symbols += 1
    else:
        non_target_glibc_239_refs.append(name)

if non_target_glibc_239_refs:
    fail(
        "non-pidfd GLIBC_2.39 references remain: "
        + ", ".join(sorted(set(non_target_glibc_239_refs)))
    )

if patched_symbols == 0:
    sys.exit(0)

for version_id in target_version_ids:
    aux_offset = version_aux_offsets.get(version_id)
    if aux_offset is None:
        fail("GLIBC_2.39 version need record was not found")
    struct.pack_into("<I", data, aux_offset, glibc_234_hash)
    struct.pack_into("<I", data, aux_offset + 8, glibc_234_name_offset)

path.write_bytes(data)
print("patched")
PY
}

validate_browser_use_node_repl_elf_compatibility() {
    local file="$1"
    local arch="$2"
    local profile
    local expected_class
    local expected_machine
    local expected_interpreter
    local ldconfig_path=""

    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "ELF compatibility validation unavailable: python3 is required" >&2
        return 2
    fi
    if ! profile="$(browser_use_node_repl_elf_arch_profile "$arch")"; then
        printf '%s\n' "ELF compatibility validation unavailable for architecture $arch" >&2
        return 2
    fi
    IFS='|' read -r expected_class expected_machine expected_interpreter <<< "$profile"
    ldconfig_path="$(command -v ldconfig 2>/dev/null || true)"
    case "$ldconfig_path" in
        /*) ;;
        *) ldconfig_path="" ;;
    esac

    # Parse the staged ELF as data. ldd may execute a target with an unusual
    # interpreter, so it must never be used on a DMG- or cache-provided binary.
    python3 - \
        "$file" \
        "$arch" \
        "$expected_class" \
        "$expected_machine" \
        "$expected_interpreter" \
        "$ldconfig_path" <<'PY'
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


class ValidationError(Exception):
    pass


class ValidationUnavailable(Exception):
    pass


def reject(message):
    raise ValidationError(message)


def unavailable(message):
    raise ValidationUnavailable(message)


def checked_range(data, offset, size, label):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        reject(f"{label} is outside file bounds")


def checked_slice(data, offset, size, label):
    checked_range(data, offset, size, label)
    return data[offset : offset + size]


def read_cstr(blob, offset, label):
    if offset < 0 or offset >= len(blob):
        reject(f"{label} string offset is outside the dynamic string table")
    end = blob.find(b"\0", offset, min(len(blob), offset + 513))
    if end < 0:
        reject(f"{label} is not NUL-terminated within 512 bytes")
    try:
        return blob[offset:end].decode("ascii")
    except UnicodeDecodeError as exc:
        reject(f"{label} is not ASCII: {exc}")


def parse_version(value, prefix):
    match = re.fullmatch(
        rf"{re.escape(prefix)}(\d{{1,6}})\.(\d{{1,6}})(?:\.(\d{{1,6}}))?",
        value,
    )
    if match is None:
        return None
    return tuple(int(part or 0) for part in match.groups())


def elf_hash(value):
    result = 0
    for byte in value.encode("ascii"):
        result = (result << 4) + byte
        high = result & 0xF0000000
        if high:
            result ^= high >> 24
            result &= ~high
    return result & 0xFFFFFFFF


def read_elf_identity(path):
    try:
        with Path(path).open("rb") as source:
            header = source.read(20)
    except OSError:
        return None
    if (
        len(header) < 20
        or header[:4] != b"\x7fELF"
        or header[5] != 1
        or header[6] != 1
    ):
        return None
    elf_type, machine = struct.unpack_from("<HH", header, 16)
    if elf_type not in (2, 3):
        return None
    return header[4], machine


def resolve_host_dependencies(dependencies, ldconfig_path, expected_class, expected_machine):
    if not ldconfig_path:
        unavailable("ldconfig is not available to query the host loader cache")

    environment = os.environ.copy()
    for name in (
        "LD_AUDIT",
        "LD_DEBUG",
        "LD_DEBUG_OUTPUT",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
    ):
        environment.pop(name, None)
    environment["LC_ALL"] = "C"

    try:
        result = subprocess.run(
            [ldconfig_path, "-p"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        unavailable(f"cannot query the host loader cache with ldconfig -p: {exc}")
    if result.returncode != 0:
        detail = result.stderr[:512].decode("utf-8", "replace").strip()
        unavailable(
            "cannot query the host loader cache with ldconfig -p"
            + (f": {detail}" if detail else f" (exit {result.returncode})")
        )
    if len(result.stdout) > 16 * 1024 * 1024:
        unavailable("ldconfig -p output exceeds the 16 MiB metadata limit")

    cache_entries = {}
    for line in result.stdout.decode("utf-8", "surrogateescape").splitlines():
        left, separator, right = line.partition(" => ")
        if not separator:
            continue
        fields = left.split()
        if not fields:
            continue
        candidate = right.strip()
        if not os.path.isabs(candidate):
            continue
        cache_entries.setdefault(fields[0], []).append(candidate)

    resolved = {}
    for dependency in dependencies:
        for candidate in cache_entries.get(dependency, ()):
            if read_elf_identity(candidate) == (expected_class, expected_machine):
                resolved[dependency] = candidate
                break
        if dependency not in resolved:
            reject(
                f"shared-library dependency {dependency!r} is not available "
                "for the target architecture in the host loader cache"
            )
    return resolved


def validate(path, arch):
    expected_class = int(sys.argv[3])
    expected_machine = int(sys.argv[4])
    expected_interpreter = sys.argv[5]
    ldconfig_path = sys.argv[6]
    maximum_size = 128 * 1024 * 1024
    with path.open("rb") as source:
        size = os.fstat(source.fileno()).st_size
        if size > maximum_size:
            reject("file exceeds the 128 MiB executable limit")
        data = source.read(maximum_size + 1)
    if len(data) > maximum_size:
        reject("file grew beyond the 128 MiB executable limit while being read")
    if len(data) != size:
        reject("file size changed while compatibility metadata was being read")
    if len(data) < 24 or data[:4] != b"\x7fELF":
        reject("file is not a complete ELF executable")
    if data[4] != expected_class or data[5] != 1 or data[6] != 1:
        reject("ELF class, byte order, or identification version does not match the host")

    e_type, e_machine, e_version = struct.unpack_from("<HHI", data, 16)
    if e_type not in (2, 3) or e_machine != expected_machine or e_version != 1:
        reject("ELF type, architecture, or version does not match the host")
    if expected_class == 1:
        unavailable(
            f"full static dependency validation is unavailable for ELF32 {arch}; "
            "the architecture header was verified"
        )
    if expected_class != 2 or len(data) < 64:
        reject("file is not a complete ELF64 executable")

    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_ehsize = struct.unpack_from("<H", data, 52)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    e_shstrndx = struct.unpack_from("<H", data, 62)[0]
    if e_ehsize != 64 or e_phentsize != 56 or not 1 <= e_phnum <= 256:
        reject("ELF program header table is missing or malformed")
    if e_shentsize != 64 or not 1 <= e_shnum <= 256 or e_shstrndx >= e_shnum:
        reject("ELF section header table is missing or malformed")
    checked_range(data, e_phoff, e_phentsize * e_phnum, "ELF program header table")
    checked_range(data, e_shoff, e_shentsize * e_shnum, "ELF section header table")

    interpreters = []
    load_segments = []
    dynamic_segments = []
    for index in range(e_phnum):
        offset = e_phoff + (index * e_phentsize)
        p_type, _flags, p_offset, _vaddr, _paddr, p_filesz, _memsz, _align = struct.unpack_from(
            "<IIQQQQQQ", data, offset
        )
        checked_range(data, p_offset, p_filesz, f"ELF program segment {index}")
        if p_filesz > _memsz:
            reject(f"ELF program segment {index} has a file size larger than its memory size")
        if p_type == 3:
            if interpreters or p_filesz != len(expected_interpreter) + 1:
                reject("ELF contains duplicate or unexpected-sized interpreter metadata")
            segment = checked_slice(data, p_offset, p_filesz, "ELF interpreter")
            if not segment.endswith(b"\0") or b"\0" in segment[:-1]:
                reject("ELF interpreter is not a single NUL-terminated path")
            try:
                interpreters.append(segment[:-1].decode("ascii"))
            except UnicodeDecodeError as exc:
                reject(f"ELF interpreter is not ASCII: {exc}")
        elif p_type == 1:
            load_segments.append((p_offset, _vaddr, p_filesz))
        elif p_type == 2:
            dynamic_segments.append((p_offset, _vaddr, p_filesz))
    if interpreters != [expected_interpreter]:
        reject(f"unexpected ELF interpreter: {interpreters!r}")
    if len(dynamic_segments) != 1:
        reject("ELF must contain exactly one dynamic program segment")
    if len(load_segments) == 0:
        reject("ELF has no loadable program segments")

    sections = []
    for index in range(e_shnum):
        offset = e_shoff + (index * e_shentsize)
        fields = struct.unpack_from("<IIQQQQIIQQ", data, offset)
        section = {
            "type": fields[1],
            "address": fields[3],
            "offset": fields[4],
            "size": fields[5],
            "link": fields[6],
            "entsize": fields[9],
        }
        if section["type"] != 8:
            checked_range(
                data,
                section["offset"],
                section["size"],
                f"ELF section {index}",
            )
        sections.append(section)

    def require_unambiguous_load_mapping(section, label):
        mappings = []
        for load_offset, load_address, load_size in load_segments:
            if (
                section["address"] >= load_address
                and section["size"] <= load_size - (section["address"] - load_address)
            ):
                mappings.append(load_offset + section["address"] - load_address)
        if mappings != [section["offset"]]:
            reject(f"{label} does not have one unambiguous file-backed load mapping")

    dynamic_indexes = [index for index, section in enumerate(sections) if section["type"] == 6]
    if len(dynamic_indexes) != 1:
        reject("ELF must contain exactly one dynamic section")
    dynamic = sections[dynamic_indexes[0]]
    dynamic_segment_offset, dynamic_segment_address, dynamic_segment_size = dynamic_segments[0]
    if (
        dynamic["offset"] != dynamic_segment_offset
        or dynamic["address"] != dynamic_segment_address
        or dynamic["size"] != dynamic_segment_size
        or dynamic["entsize"] != 16
    ):
        reject("ELF dynamic section does not exactly match its program segment")
    require_unambiguous_load_mapping(dynamic, "ELF dynamic section")
    if dynamic["link"] >= len(sections) or sections[dynamic["link"]]["type"] != 3:
        reject("ELF dynamic section does not reference a string table")
    dynstr = sections[dynamic["link"]]
    # This is a resource ceiling, not a fingerprint of the current upstream
    # artifact. It remains below the overall 128 MiB executable limit while
    # allowing substantially larger future runtime builds.
    if dynstr["size"] > 64 * 1024 * 1024:
        reject("ELF dynamic string table exceeds the 64 MiB metadata limit")
    require_unambiguous_load_mapping(dynstr, "ELF dynamic string table")
    dynstr_data = checked_slice(data, dynstr["offset"], dynstr["size"], "ELF dynamic string table")
    if dynamic["size"] % dynamic["entsize"] != 0 or dynamic["size"] // 16 > 4096:
        reject("ELF dynamic section has an invalid entry size")

    dangerous_tags = {
        15: "RPATH",
        29: "RUNPATH",
        0x6FFFFEFB: "DEPAUDIT",
        0x6FFFFEFC: "AUDIT",
        0x7FFFFFFD: "AUXILIARY",
        0x7FFFFFFF: "FILTER",
    }
    needed_offsets = []
    singleton_tags = {
        5: "STRTAB",
        10: "STRSZ",
        0x6FFFFFFE: "VERNEED",
        0x6FFFFFFF: "VERNEEDNUM",
    }
    singleton_values = {}
    saw_null = False
    for offset in range(dynamic["offset"], dynamic["offset"] + dynamic["size"], dynamic["entsize"]):
        tag, value = struct.unpack_from("<qQ", data, offset)
        if tag == 0:
            saw_null = True
            break
        if tag == 1:
            needed_offsets.append(value)
        if tag in dangerous_tags:
            reject(f"ELF dynamic section contains unsafe {dangerous_tags[tag]}")
        if tag in singleton_tags:
            if tag in singleton_values:
                reject(f"ELF dynamic section contains duplicate {singleton_tags[tag]}")
            singleton_values[tag] = value
    if not saw_null:
        reject("ELF dynamic section has no terminating NULL entry")
    missing_singletons = [
        name for tag, name in singleton_tags.items() if tag not in singleton_values
    ]
    if missing_singletons:
        reject("ELF dynamic section is missing " + ", ".join(missing_singletons))
    if (
        singleton_values[5] != dynstr["address"]
        or singleton_values[10] != dynstr["size"]
    ):
        reject("loader-visible dynamic string table does not match section metadata")

    needed = [read_cstr(dynstr_data, offset, "DT_NEEDED") for offset in needed_offsets]
    if len(needed) != len(set(needed)):
        reject("ELF contains duplicate shared-library dependencies")
    for dependency in needed:
        if (
            not dependency
            or len(dependency) > 255
            or "/" in dependency
            or any(
                character.isspace()
                or ord(character) < 0x20
                or ord(character) == 0x7F
                for character in dependency
            )
        ):
            reject(f"unsafe shared-library dependency name {dependency!r}")

    verneed_indexes = [
        index for index, section in enumerate(sections) if section["type"] == 0x6FFFFFFE
    ]
    if len(verneed_indexes) != 1:
        reject("ELF must contain exactly one version-needs section")
    verneed = sections[verneed_indexes[0]]
    if verneed["link"] != dynamic["link"]:
        reject("ELF version-needs section does not reference the dynamic string table")
    if singleton_values[0x6FFFFFFE] != verneed["address"]:
        reject("loader-visible version-needs table does not match section metadata")
    if not 1 <= singleton_values[0x6FFFFFFF] <= 256:
        reject("ELF version-needs record count exceeds the metadata limit")
    require_unambiguous_load_mapping(verneed, "ELF version-needs section")
    start = verneed["offset"]
    end = start + verneed["size"]
    cursor = start
    versions = []
    records = 0
    total_versions = 0
    while True:
        if cursor + 16 > end:
            reject("ELF version-needs record is outside section bounds")
        vn_version, vn_count, file_offset, vn_aux, vn_next = struct.unpack_from(
            "<HHIII", data, cursor
        )
        if vn_version != 1 or vn_count == 0 or vn_count > 4096:
            reject("ELF version-needs record is malformed")
        total_versions += vn_count
        if total_versions > 4096:
            reject("ELF version-needs entries exceed the metadata limit")
        dependency = read_cstr(dynstr_data, file_offset, "version dependency")
        if dependency not in needed:
            reject(f"version-needs record references undeclared dependency {dependency!r}")
        aux_cursor = cursor + vn_aux
        if vn_aux < 16 or aux_cursor + 16 > end:
            reject("ELF version auxiliary table is outside section bounds")
        for aux_index in range(vn_count):
            if aux_cursor + 16 > end:
                reject("ELF version auxiliary record is outside section bounds")
            version_hash, _flags, _other, name_offset, aux_next = struct.unpack_from(
                "<IHHII", data, aux_cursor
            )
            version_name = read_cstr(dynstr_data, name_offset, "required version")
            if version_hash != elf_hash(version_name):
                reject(f"required version {version_name!r} has an invalid ELF hash")
            versions.append((dependency, version_name))
            if aux_index + 1 < vn_count:
                if aux_next < 16 or aux_cursor + aux_next + 16 > end:
                    reject("ELF version auxiliary chain is malformed")
                aux_cursor += aux_next
            elif aux_next != 0:
                reject("ELF version auxiliary chain exceeds its declared count")
        records += 1
        if records > singleton_values[0x6FFFFFFF]:
            reject("ELF version-needs chain exceeds its declared count")
        if vn_next == 0:
            break
        if vn_next < 16 or cursor + vn_next + 16 > end:
            reject("ELF version-needs chain is malformed")
        cursor += vn_next

    if records != singleton_values[0x6FFFFFFF]:
        reject("ELF version-needs chain does not match its declared count")

    try:
        host_glibc = os.confstr("CS_GNU_LIBC_VERSION")
    except (AttributeError, OSError, ValueError) as exc:
        unavailable(f"cannot determine host glibc version: {exc}")
    match = re.fullmatch(r"glibc\s+(\d+)\.(\d+)(?:\.(\d+))?", host_glibc or "")
    if match is None:
        unavailable(f"cannot parse host glibc version {host_glibc!r}")
    host_glibc_version = tuple(int(part or 0) for part in match.groups())

    for dependency, version in versions:
        glibc_version = parse_version(version, "GLIBC_")
        if glibc_version is not None:
            if glibc_version > host_glibc_version:
                reject(
                    f"required {version} exceeds host GLIBC_{'.'.join(map(str, host_glibc_version))}"
                )
            continue
        if version == "GLIBC_ABI_DT_RELR":
            if host_glibc_version < (2, 36, 0):
                reject("GLIBC_ABI_DT_RELR requires glibc 2.36 or newer")
            continue
        # Non-glibc provider versions (for example GCC_, GLIBCXX_, CXXABI_,
        # or ZLIB_) are upstream/toolchain contracts, not a fixed node_repl
        # fingerprint. The exact provider SONAME is resolved below without
        # executing the target.

    resolve_host_dependencies(
        needed,
        ldconfig_path,
        expected_class,
        expected_machine,
    )


try:
    validate(Path(sys.argv[1]), sys.argv[2])
except ValidationUnavailable as exc:
    print(f"ELF compatibility validation unavailable: {exc}", file=sys.stderr)
    sys.exit(2)
except (OSError, OverflowError, ValueError, struct.error, ValidationError) as exc:
    print(f"unsafe or incompatible ELF metadata: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

install_browser_use_node_repl_executable_resource() {
    local source="$1"
    local destination="$2"
    local label="$3"
    local log_level="${4:-warn}"
    local compatibility_error
    local compatibility_status=0
    local patch_status

    if ! command -v python3 >/dev/null 2>&1; then
        warn "Browser Use $label validation is unavailable: python3 is required; preserving any existing runtime"
        return 2
    fi

    if ! install_linux_executable_resource "$source" "$destination" "$label" "$log_level"; then
        return 1
    fi

    if ! patch_status="$(patch_browser_use_node_repl_glibc_pidfd_symbols "$destination" 2>&1)"; then
        warn "Browser Use $label has unsupported GLIBC_2.39 runtime references; skipping"
        [ -z "$patch_status" ] || warn "$patch_status"
        rm -f "$destination"
        return 1
    fi

    if [ "$patch_status" = "patched" ]; then
        info "Patched Browser Use $label for glibc 2.34+ compatibility"
    fi

    compatibility_error="$(
        validate_browser_use_node_repl_elf_compatibility "$destination" "$ARCH" 2>&1
    )" || compatibility_status=$?
    case "$compatibility_status" in
        0)
            return 0
            ;;
        2)
            warn "Browser Use $label compatibility validation is unavailable; retaining the statically verified runtime"
            [ -z "$compatibility_error" ] || warn "$compatibility_error"
            return 0
            ;;
        *)
            if [ "$log_level" = "info" ]; then
                info "Browser Use $label is not compatible with this host runtime; skipping"
            else
                warn "Browser Use $label is not compatible with this host runtime; skipping"
            fi
            [ -z "$compatibility_error" ] || warn "$compatibility_error"
            rm -f "$destination"
            return 1
            ;;
    esac
}

browser_use_node_repl_runtime_url() {
    case "$ARCH" in
        x86_64)
            echo "${CODEX_BROWSER_USE_NODE_REPL_RUNTIME_URL:-https://persistent.oaistatic.com/codex-primary-runtime/26.426.12240/codex-primary-runtime-linux-x64-26.426.12240.tar.xz}"
            ;;
        *)
            return 1
            ;;
    esac
}

browser_use_node_repl_runtime_sha256() {
    case "$ARCH" in
        x86_64)
            echo "${CODEX_BROWSER_USE_NODE_REPL_RUNTIME_SHA256:-db5624eb6efa36b66ec6f6dd0488cefb966e49636862aab6209a4336c1ca90c4}"
            ;;
        *)
            return 1
            ;;
    esac
}

install_node_repl_from_primary_runtime_archive() {
    local destination="$1"
    local url
    local expected_sha
    local cache_dir
    local archive
    local extract_dir
    local source

    if ! url="$(browser_use_node_repl_runtime_url)"; then
        warn "Browser Use node_repl primary-runtime fallback is unavailable for $ARCH"
        return 1
    fi
    expected_sha="$(browser_use_node_repl_runtime_sha256)"

    cache_dir="${CODEX_BROWSER_USE_RUNTIME_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop/browser-use}"
    archive="$cache_dir/$(basename "$url")"
    extract_dir="$WORK_DIR/browser-use-node-repl-runtime"
    source="$extract_dir/codex-primary-runtime/dependencies/bin/node_repl"

    mkdir -p "$cache_dir" "$extract_dir"
    if [ ! -f "$archive" ]; then
        info "Downloading Browser Use node_repl fallback runtime..."
        if ! curl -L --fail --progress-bar -o "$archive.part" "$url"; then
            rm -f "$archive.part"
            warn "Failed to download Browser Use node_repl fallback runtime"
            return 1
        fi
        mv "$archive.part" "$archive"
    else
        info "Using cached Browser Use node_repl fallback runtime: $archive"
    fi

    if ! printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$archive"
        warn "Browser Use node_repl fallback runtime checksum mismatch; removed cached archive"
        return 1
    fi

    if ! tar -xJf "$archive" -C "$extract_dir" codex-primary-runtime/dependencies/bin/node_repl; then
        warn "Failed to extract Browser Use node_repl from fallback runtime"
        return 1
    fi

    install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl fallback runtime"
}

install_browser_use_node_repl_resource() {
    local upstream_resources="$1"
    local destination="$2"
    local source

    for source in \
        "${CODEX_LINUX_NODE_REPL_SOURCE:-}" \
        "${CODEX_NODE_REPL_PATH:-}"
    do
        [ -n "$source" ] || continue
        if install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime"; then
            return 0
        fi
    done

    source="${XDG_CACHE_HOME:-$HOME/.cache}/codex-runtimes/codex-primary-runtime/dependencies/bin/node_repl"
    if [ -f "$source" ] && install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime"; then
        return 0
    fi

    for source in \
        "$upstream_resources/cua_node/bin/node_repl" \
        "$upstream_resources/node_repl"
    do
        [ -f "$source" ] || continue
        if install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime" "info"; then
            return 0
        fi
    done

    install_node_repl_from_primary_runtime_archive "$destination"
}

remove_macos_sidecar_files() {
    local root="$1"
    find "$root" -type f -name '*:com.apple.*' -delete
}

validate_upstream_bundled_skills() {
    local skills_dir="$1"

    python3 - "$skills_dir" <<'PY'
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])

try:
    root_metadata = root.lstat()
except OSError as exc:
    print(f"cannot inspect bundled skills root: {exc}", file=sys.stderr)
    sys.exit(1)

if stat.S_ISLNK(root_metadata.st_mode):
    print("bundled skills root cannot be a symlink", file=sys.stderr)
    sys.exit(1)
if not stat.S_ISDIR(root_metadata.st_mode):
    print("bundled skills root must be a directory", file=sys.stderr)
    sys.exit(1)

try:
    resolved_root = root.resolve(strict=True)
except (OSError, RuntimeError) as exc:
    print(f"cannot resolve bundled skills root: {exc}", file=sys.stderr)
    sys.exit(1)


def fail_walk(error):
    print(f"cannot inspect bundled skills tree: {error}", file=sys.stderr)
    sys.exit(1)


for current_root, directories, files in os.walk(root, followlinks=False, onerror=fail_walk):
    current = Path(current_root)
    for name in directories + files:
        path = current / name
        relative_path = path.relative_to(root)
        try:
            metadata = path.lstat()
        except OSError as exc:
            print(f"cannot inspect {relative_path}: {exc}", file=sys.stderr)
            sys.exit(1)

        if stat.S_ISLNK(metadata.st_mode):
            try:
                target = os.readlink(path)
            except OSError as exc:
                print(f"cannot read symlink {relative_path}: {exc}", file=sys.stderr)
                sys.exit(1)
            if os.path.isabs(target):
                print(f"absolute symlink is not allowed: {relative_path}", file=sys.stderr)
                sys.exit(1)
            try:
                resolved_target = path.resolve(strict=True)
            except (OSError, RuntimeError) as exc:
                print(f"cannot resolve symlink {relative_path}: {exc}", file=sys.stderr)
                sys.exit(1)
            try:
                resolved_target.relative_to(resolved_root)
            except ValueError:
                print(f"symlink escapes bundled skills root: {relative_path}", file=sys.stderr)
                sys.exit(1)
            try:
                target_metadata = resolved_target.stat()
            except OSError as exc:
                print(f"cannot inspect symlink target {relative_path}: {exc}", file=sys.stderr)
                sys.exit(1)
            if not (stat.S_ISDIR(target_metadata.st_mode) or stat.S_ISREG(target_metadata.st_mode)):
                print(f"unsupported symlink target type: {relative_path}", file=sys.stderr)
                sys.exit(1)
            continue

        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            print(f"unsupported file type: {relative_path}", file=sys.stderr)
            sys.exit(1)
        if metadata.st_mode & 0o6000:
            print(f"privileged mode is not allowed: {relative_path}", file=sys.stderr)
            sys.exit(1)
PY
}

stage_upstream_bundled_skills() {
    local source_skills="$1"
    local target_skills="$2"
    local target_parent
    local staging_skills=""
    local backup_skills=""

    if [ ! -d "$source_skills" ]; then
        info "Bundled skills not present in upstream resources; skipping"
        return 0
    fi
    if ! validate_upstream_bundled_skills "$source_skills"; then
        warn "Bundled skills source contains unsupported content"
        return 1
    fi

    target_parent="$(dirname "$target_skills")"
    mkdir -p "$target_parent"
    if ! staging_skills="$(mktemp -d "$target_parent/.skills.tmp.XXXXXX")"; then
        warn "Failed to create staging directory for bundled skills"
        return 1
    fi
    if ! cp -R "$source_skills/." "$staging_skills/"; then
        rm -rf -- "$staging_skills"
        warn "Failed to stage bundled skills from upstream resources"
        return 1
    fi
    if ! remove_macos_sidecar_files "$staging_skills"; then
        rm -rf -- "$staging_skills"
        warn "Failed to clean macOS sidecar files from bundled skills"
        return 1
    fi
    if ! validate_upstream_bundled_skills "$staging_skills"; then
        rm -rf -- "$staging_skills" || warn "Failed to clean bundled skills staging directory"
        warn "Bundled skills failed post-copy validation"
        return 1
    fi
    if ! chmod -R u+rwX,go-w "$staging_skills"; then
        rm -rf -- "$staging_skills"
        warn "Failed to normalize bundled skills permissions"
        return 1
    fi

    backup_skills="$target_parent/.skills.backup.$$"
    if ! rm -rf -- "$backup_skills"; then
        rm -rf -- "$staging_skills"
        warn "Failed to prepare bundled skills backup"
        return 1
    fi
    if [ -e "$target_skills" ] || [ -L "$target_skills" ]; then
        if ! mv -- "$target_skills" "$backup_skills"; then
            rm -rf -- "$staging_skills"
            warn "Failed to preserve existing bundled skills"
            return 1
        fi
    else
        backup_skills=""
    fi
    if ! mv -- "$staging_skills" "$target_skills"; then
        rm -rf -- "$staging_skills"
        if [ -n "$backup_skills" ]; then
            if mv -- "$backup_skills" "$target_skills"; then
                warn "Failed to install bundled skills; previous target was restored"
            else
                warn "Failed to install bundled skills and previous target could not be restored"
            fi
        else
            warn "Failed to install bundled skills"
        fi
        return 1
    fi
    if [ -n "$backup_skills" ] && ! rm -rf -- "$backup_skills"; then
        warn "Failed to clean previous bundled skills backup: $backup_skills"
        return 1
    fi

    info "Bundled skills staged from upstream DMG"
}

chrome_extension_host_arch() {
    case "$ARCH" in
        x86_64) echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

build_chrome_extension_host() {
    local source_binary="$SCRIPT_DIR/target/release/codex-chrome-extension-host"
    local cargo_cmd=""

    if [ -n "${CODEX_CHROME_EXTENSION_HOST_SOURCE:-}" ]; then
        [ -x "$CODEX_CHROME_EXTENSION_HOST_SOURCE" ] || {
            warn "CODEX_CHROME_EXTENSION_HOST_SOURCE is not executable: $CODEX_CHROME_EXTENSION_HOST_SOURCE"
            return 1
        }
        info "Using prebuilt Chrome extension host"
        printf '%s\n' "$CODEX_CHROME_EXTENSION_HOST_SOURCE"
        return 0
    fi

    if ! cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
        warn "cargo not found; Chrome extension host will be unavailable"
        return 1
    fi

    info "Building Chrome extension host..."
    if ! (cd "$SCRIPT_DIR" && "$cargo_cmd" build --release -p codex-computer-use-linux --bin codex-chrome-extension-host >&2); then
        warn "Failed to build Chrome extension host"
        return 1
    fi

    if [ ! -x "$source_binary" ]; then
        warn "Chrome extension host binary missing after build: $source_binary"
        return 1
    fi

    printf '%s\n' "$source_binary"
}

install_chrome_extension_host_resource() {
    local target_plugin="$1"
    local source_host=""
    local extension_arch
    local target_host

    if ! extension_arch="$(chrome_extension_host_arch)"; then
        warn "Chrome extension host is unavailable for $ARCH; skipping Chrome plugin"
        return 1
    fi

    if ! source_host="$(build_chrome_extension_host)"; then
        return 1
    fi

    target_host="$target_plugin/extension-host/linux/$extension_arch/extension-host"
    mkdir -p "$(dirname "$target_host")"
    install -m 0755 "$source_host" "$target_host"
}

patch_chrome_plugin_for_linux() {
    local target_plugin="$1"
    local patcher="$SCRIPT_DIR/scripts/lib/patch-chrome-plugin.js"

    if [ ! -f "$patcher" ]; then
        warn "Chrome plugin patch helper not found at $patcher; leaving upstream scripts unchanged"
        return 0
    fi

    if ! node "$patcher" "$target_plugin" >&2; then
        warn "Chrome plugin Linux patch helper failed; leaving upstream scripts as-is"
    fi
}

patch_browser_client_iab_socket_scope() {
    local client="$1"
    local patcher="$SCRIPT_DIR/scripts/lib/patch-browser-client-iab-socket-scope.js"

    if [ ! -f "$patcher" ]; then
        warn "IAB Browser socket scope patch helper not found at $patcher; leaving browser-client.mjs unchanged"
        return 0
    fi

    if ! node "$patcher" "$client" >&2; then
        warn "IAB Browser socket scope patch helper failed; leaving browser-client.mjs unchanged"
    fi
}

patch_browser_client_linux_socket_dir() {
    local client="$1"
    local patcher="$SCRIPT_DIR/scripts/lib/patch-browser-client-iab-socket-scope.js"

    if [ ! -f "$patcher" ]; then
        warn "Browser socket-directory patch helper not found at $patcher; leaving browser-client.mjs unchanged"
        return 0
    fi

    if ! node "$patcher" "$client" --socket-dir-only >&2; then
        warn "Browser socket-directory patch helper failed; leaving browser-client.mjs unchanged"
    fi
}

patch_browser_use_node_repl_process_env_import() {
    local client="$1"

    if grep -q "codexLinuxBrowserUseProcessEnv" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'import\{env as (?P<binding>[A-Za-z_$][\w$]*)\}from"node:process";'
)
match = pattern.search(source)
if match is None:
    if '"node:process"' in source:
        print(
            "WARN: Could not find Browser Use node:process env import — leaving browser-client.mjs unchanged",
            file=sys.stderr,
        )
    raise SystemExit(0)

binding = match.group("binding")
replacement = (
    "var codexLinuxBrowserUseProcessEnv=globalThis.nodeRepl?.env??{},"
    f"{binding}=codexLinuxBrowserUseProcessEnv;"
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

normalize_plugin_script_executable_modes() {
    local target_plugin="$1"
    local scripts_dir="$target_plugin/scripts"
    local script

    [ -d "$scripts_dir" ] || return 0

    while IFS= read -r -d '' script; do
        if [ "$(head -c 2 "$script" 2>/dev/null || true)" = "#!" ]; then
            chmod 0755 "$script"
        fi
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name '*.js' -print0)
}

stage_chrome_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local target_plugin="$target_plugins/chrome"
    local source_manifest="$source_plugin/.codex-plugin/plugin.json"
    local source_client="$source_plugin/scripts/browser-client.mjs"
    local source_install_manifest="$source_plugin/scripts/installManifest.mjs"

    if [ ! -d "$source_plugin" ]; then
        warn "Chrome bundled plugin resources not found in upstream app; skipping Chrome"
        return 1
    fi

    if [ ! -f "$source_manifest" ]; then
        warn "Chrome plugin manifest not found in upstream app; skipping Chrome"
        return 1
    fi

    if [ ! -f "$source_client" ] || [ ! -f "$source_install_manifest" ]; then
        warn "Chrome plugin scripts not found in upstream app; skipping Chrome"
        return 1
    fi

    rm -rf "$target_plugin"
    cp -R "$source_plugin" "$target_plugin"
    remove_macos_sidecar_files "$target_plugin"
    patch_chrome_plugin_for_linux "$target_plugin"
    patch_browser_use_node_repl_process_env_import "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_node_repl_env_guard "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_node_repl_config_shim "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_native_pipe_import_meta_bridge "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_site_status_allowlist_fallback "$target_plugin/scripts/browser-client.mjs"
    patch_browser_client_linux_socket_dir "$target_plugin/scripts/browser-client.mjs"
    normalize_plugin_script_executable_modes "$target_plugin"
    if ! install_chrome_extension_host_resource "$target_plugin"; then
        rm -rf "$target_plugin"
        return 1
    fi

    info "Chrome plugin staged from upstream DMG"
    return 0
}

patch_browser_use_site_status_allowlist_fallback() {
    local client="$1"

    if grep -q "codexLinuxSiteStatusAllowlistFallback" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'async fetchBlocked\((?P<url>[A-Za-z_$][\w$]*),(?P<label>[A-Za-z_$][\w$]*)\)\{'
    r'let (?P<response>[A-Za-z_$][\w$]*)=await (?P<fetch>[A-Za-z_$][\w$]*)'
    r'\((?P=url)\.endpoint,\{method:"GET"\}\);'
    r'if\(!(?P=response)\.ok\)throw new Error\((?P<format>[A-Za-z_$][\w$]*)'
    r'\(`\$\{(?P=label)\} cannot determine if \$\{(?P=url)\.displayUrl\} is allowed\. '
    r'Please try again later or use another source\.`\)\);'
    r'let (?P<json>[A-Za-z_$][\w$]*)=await (?P=response)\.json\(\);'
    r'return (?P<status>[A-Za-z_$][\w$]*)\((?P=json)\)\}'
)
match = pattern.search(source)
if match is None:
    if "/aura/site_status" not in source and "fetchBlocked(" not in source:
        raise SystemExit(0)
    print(
        "WARN: Could not find Browser Use site_status allowlist fallback insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

url = match.group("url")
response = match.group("response")
fetch = match.group("fetch")
formatter = match.group("format")
json_value = match.group("json")
status = match.group("status")
label = match.group("label")
error = "__codexLinuxErr"
error_message = f'${{{label}}} cannot determine if ${{{url}.displayUrl}} is allowed. Please try again later or use another source.'
replacement = (
    f'async fetchBlocked({url},{label}){{let {response};try{{{response}=await {fetch}({url}.endpoint,{{method:"GET"}})}}'
    f'catch({error}){{if(String({url}?.endpoint??"").includes("/aura/site_status")&&'
    f'String({error}?.message??{error}).toLowerCase().includes("allowlist"))'
    f'return!1/*codexLinuxSiteStatusAllowlistFallback*/;throw {error}}}'
    f'if(!{response}.ok)throw new Error({formatter}(`{error_message}`));'
    f'let {json_value}=await {response}.json();return {status}({json_value})}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

patch_browser_use_file_url_policy() {
    local client="$1"

    if grep -q "codexLinuxFileUrlPolicy" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
patterns = [
    re.compile(
        r'function\s+(?P<helper>[A-Za-z_$][\w$]*)\((?P<url>[A-Za-z_$][\w$]*)\)\{'
        r'if\((?P<allowlist>[A-Za-z_$][\w$]*)\.has\((?P=url)\)\)return\s*(?:true|!0);'
        r'let\s+(?P<parsed>[A-Za-z_$][\w$]*);'
        r'try\{\s*(?P=parsed)\s*=\s*new URL\((?P=url)\);?\s*\}'
        r'catch\{\s*return\s*(?:false|!1);?\s*\}'
        r'return\s+(?P=parsed)\.protocol\s*===\s*"http:"\s*\|\|\s*'
        r'(?P=parsed)\.protocol\s*===\s*"https:"(?P<semicolon>;?)\}'
    ),
    re.compile(
        r'function\s+(?P<helper>[A-Za-z_$][\w$]*)\((?P<url>[A-Za-z_$][\w$]*)\)\{'
        r'if\((?P<allowlist>[A-Za-z_$][\w$]*)\.has\((?P=url)\)\)return\s*(?:true|!0);'
        r'(?:const|let|var)\s+(?P<parsed>[A-Za-z_$][\w$]*)\s*=\s*new URL\((?P=url)\);'
        r'return\s+(?P=parsed)\.protocol\s*===\s*"http:"\s*\|\|\s*'
        r'(?P=parsed)\.protocol\s*===\s*"https:"(?P<semicolon>;?)\}'
    ),
]

for pattern in patterns:
    match = pattern.search(source)
    if match is None:
        continue

    parsed = match.group("parsed")
    semicolon = match.group("semicolon")
    old_body = match.group(0)
    old_return = re.compile(
        rf'return\s+{re.escape(parsed)}\.protocol\s*===\s*"http:"\s*\|\|\s*'
        rf'{re.escape(parsed)}\.protocol\s*===\s*"https:"{re.escape(semicolon)}'
    )
    file_policy = (
        f'{parsed}.protocol==="file:"&&'
        f'({parsed}.hostname===""||{parsed}.hostname==="localhost")'
        f'/*codexLinuxFileUrlPolicy*/'
    )
    new_return = (
        f'return {parsed}.protocol==="http:"||{parsed}.protocol==="https:"||'
        f'{file_policy}{semicolon}'
    )
    new_body, count = old_return.subn(new_return, old_body, count=1)
    if count != 1:
        continue

    path.write_text(source[:match.start()] + new_body + source[match.end():], encoding="utf-8")
    raise SystemExit(0)

print(
    "WARN: Could not find Browser Use URL policy insertion point — leaving browser-client.mjs unchanged",
    file=sys.stderr,
)
PY
}

patch_browser_use_node_repl_env_guard() {
    local client="$1"

    if grep -q "codexLinuxBrowserUseNodeReplEnvGuard" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
helper_pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\((?P<key>[A-Za-z_$][\w$]*)\)\{'
    r'let (?P<value>[A-Za-z_$][\w$]*)=globalThis\.nodeRepl\?\.env\[(?P=key)\];'
    r'return typeof (?P=value)=="string"\?(?P=value):void 0\}'
)
helper_match = helper_pattern.search(source)
if helper_match is not None:
    helper = helper_match.group("helper")
    key = helper_match.group("key")
    value = helper_match.group("value")
    replacement = (
        f'function {helper}({key}){{'
        f'let {value}=globalThis.nodeRepl?.env?.[{key}];'
        f'return typeof {value}=="string"?{value}:void 0}}'
    )
    source = source[:helper_match.start()] + replacement + source[helper_match.end():]

# Newer Browser clients snapshot privileged node_repl state before creating the
# browser agent. Older Linux node_repl runtimes do not expose `env`, so every
# direct property read must preserve the upstream default behavior when it is
# absent. Keep the object identity comparison itself unchanged.
direct_env_pattern = re.compile(
    r'(?P<object>\b[A-Za-z_$][\w$]*)\.env\[(?P<key>[^\]]+)\]'
)
source, direct_env_count = direct_env_pattern.subn(
    r'\g<object>.env?.[\g<key>]',
    source,
)

if helper_match is None and direct_env_count == 0:
    print(
        "WARN: Could not find Browser Use nodeRepl env guard insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

marker_target = (
    "globalThis.nodeRepl?.env?.["
    if "globalThis.nodeRepl?.env?.[" in source
    else ".env?.["
)
source = source.replace(
    marker_target,
    f"/*codexLinuxBrowserUseNodeReplEnvGuard*/{marker_target}",
    1,
)
path.write_text(source, encoding="utf-8")
PY
}

patch_browser_use_node_repl_config_shim() {
    local client="$1"

    if grep -q "codexLinuxBrowserUseConfigShim" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\(\)\{'
    r'let (?P<value>[A-Za-z_$][\w$]*)=globalThis\.nodeRepl;'
    r'return (?P=value)\?\.config==null\?void 0:(?P=value)\}'
)
match = pattern.search(source)
if match is None:
    print(
        "WARN: Could not find Browser Use nodeRepl config shim insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

helper = match.group("helper")
value = match.group("value")
shim = r'''
function codexLinuxBrowserUseConfigShim() {
  let repl = globalThis.nodeRepl;
  if (repl == null) return;
  codexLinuxBrowserUseNodeReplMethodShim(repl);
  if (repl.config != null) return;
  let config = {
    read: async () => ({ config: await codexLinuxBrowserUseReadToml("config.toml") }),
    readRequirements: async () => ({ requirements: null }),
    readToml: async (filePath) => codexLinuxBrowserUseReadToml(filePath),
    writeToml: codexLinuxBrowserUseIgnoreConfigWrite,
    writeValue: codexLinuxBrowserUseIgnoreConfigWrite,
    batchWrite: codexLinuxBrowserUseIgnoreConfigWrite,
  };

  try {
    repl.config = config;
    if (repl.config != null) return;
  } catch {}

  try {
    let prototype = Object.getPrototypeOf(repl);
    if (prototype != null && Object.getOwnPropertyDescriptor(prototype, "config") == null) {
      Object.defineProperty(prototype, "config", {
        configurable: true,
        get: () => config,
      });
    }
  } catch {}
}

function codexLinuxBrowserUseNodeReplMethodShim(repl) {
  // Older Linux node_repl builds do not expose browser notification hooks.
  codexLinuxBrowserUseDefineNodeReplMethod(repl, "addAfterSubmittedCodeHook", () => () => undefined);
}

function codexLinuxBrowserUseDefineNodeReplMethod(repl, name, value) {
  if (typeof repl?.[name] == "function") return;

  try {
    repl[name] = value;
    if (typeof repl[name] == "function") return;
  } catch {}

  try {
    let prototype = Object.getPrototypeOf(repl);
    if (prototype != null && Object.getOwnPropertyDescriptor(prototype, name) == null) {
      Object.defineProperty(prototype, name, {
        configurable: true,
        value,
      });
    }
  } catch {}
}

function codexLinuxBrowserUseCodexHome() {
  let codexHome = globalThis.nodeRepl?.env?.CODEX_HOME;
  if (typeof codexHome == "string" && codexHome.length > 0) {
    return codexHome.replace(/\/+$/, "");
  }

  let homeDir = globalThis.nodeRepl?.homeDir;
  return typeof homeDir == "string" && homeDir.length > 0
    ? `${homeDir.replace(/\/+$/, "")}/.codex`
    : null;
}

function codexLinuxBrowserUseConfigPath(filePath) {
  let codexHome = codexLinuxBrowserUseCodexHome();
  if (codexHome == null || typeof filePath != "string" || filePath.length === 0) {
    return null;
  }

  let normalized = filePath.replaceAll("\\", "/");
  if (normalized.startsWith("/")) {
    return normalized === codexHome || normalized.startsWith(`${codexHome}/`)
      ? normalized
      : null;
  }

  normalized = normalized.replace(/^\/+/, "");
  return normalized.split("/").includes("..") ? null : `${codexHome}/${normalized}`;
}

async function codexLinuxBrowserUseReadToml(filePath) {
  let configPath = codexLinuxBrowserUseConfigPath(filePath);
  if (configPath == null) return {};

  try {
    let { readFile } = await import("node:fs/promises");
    return codexLinuxBrowserUseParseToml(await readFile(configPath, "utf8"));
  } catch (error) {
    if (error && typeof error == "object" && error.code === "ENOENT") return {};
    throw error;
  }
}

async function codexLinuxBrowserUseIgnoreConfigWrite() {
  return undefined;
}

function codexLinuxBrowserUseParseToml(source) {
  let root = {};
  let section = root;

  for (let line of String(source).split(/\r?\n/)) {
    let trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) continue;

    let sectionMatch = trimmed.match(/^\[([A-Za-z0-9_.-]+)\]$/);
    if (sectionMatch) {
      section = root;
      for (let part of sectionMatch[1].split(".")) {
        section = section[part] && typeof section[part] == "object" && !Array.isArray(section[part])
          ? section[part]
          : (section[part] = {});
      }
      continue;
    }

    let separator = trimmed.indexOf("=");
    if (separator < 0) continue;

    let key = trimmed.slice(0, separator).trim();
    let value = trimmed.slice(separator + 1).trim();
    if (key) section[key] = codexLinuxBrowserUseParseTomlValue(value);
  }

  return root;
}

function codexLinuxBrowserUseParseTomlValue(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);

  if (value.startsWith("[") && value.endsWith("]")) {
    let body = value.slice(1, -1).trim();
    return body.length === 0
      ? []
      : body.split(",").map((item) => codexLinuxBrowserUseParseTomlValue(item.trim()));
  }

  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    try {
      return JSON.parse(value);
    } catch {
      return value.slice(1, -1);
    }
  }

  return value;
}
'''
replacement = (
    shim
    + f'function {helper}(){{codexLinuxBrowserUseConfigShim();let {value}=globalThis.nodeRepl;'
    + f'return {value}?.config==null?void 0:{value}}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

patch_browser_use_native_pipe_import_meta_bridge() {
    local client="$1"

    if grep -Fq "globalThis.nodeRepl?.nativePipe??import.meta.__codexNativePipe" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\(\)\{'
    r'let (?P<bridge>[A-Za-z_$][\w$]*)='
    r'(?:globalThis\.nodeRepl\?\.nativePipe|import\.meta\.__codexNativePipe);'
    r'return (?P=bridge)==null\|\|typeof (?P=bridge)\.createConnection!="function"\?null:(?P=bridge)\}'
)
match = pattern.search(source)
if match is None:
    print(
        "WARN: Could not find Browser Use nativePipe bridge helper — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

helper = match.group("helper")
bridge = match.group("bridge")
replacement = (
    f'function {helper}(){{let {bridge}=globalThis.nodeRepl?.nativePipe??import.meta.__codexNativePipe;'
    f'return {bridge}==null||typeof {bridge}.createConnection!="function"?null:{bridge}}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

find_browser_plugin_source() {
    local bundled_root="$1"
    local source_marketplace="$2"

    node - \
        "$bundled_root" \
        "$source_marketplace" \
        "$BUNDLED_PLUGIN_CONTAINMENT_HELPER" <<'NODE'
const fs = require("fs");
const path = require("path");
const { createPluginContainmentResolver } = require(process.argv[4]);

const bundledRoot = path.resolve(process.argv[2]);
const marketplacePath = process.argv[3];
const candidatePaths = [];
const resolver = createPluginContainmentResolver(bundledRoot, {
  requiredFiles: [
    path.join(".codex-plugin", "plugin.json"),
    path.join("scripts", "browser-client.mjs"),
  ],
  expectedManifestName: "browser",
  maxEntries: 100000,
});

try {
  const marketplace = JSON.parse(fs.readFileSync(marketplacePath, "utf8"));
  const plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];
  for (const plugin of plugins) {
    if (plugin == null || typeof plugin !== "object" || plugin.name !== "browser") {
      continue;
    }
    const source = plugin.source;
    if (source == null || source.source !== "local") {
      continue;
    }
    candidatePaths.push(source.path);
  }
} catch (_err) {
  // A malformed current-upstream marketplace has no trustworthy Browser entry.
}

const seen = new Set();
for (const sourcePath of candidatePaths) {
  if (typeof sourcePath !== "string" || sourcePath.length === 0 || path.isAbsolute(sourcePath)) {
    continue;
  }
  const lexicalCandidate = path.resolve(bundledRoot, sourcePath);
  if (seen.has(lexicalCandidate)) {
    continue;
  }
  seen.add(lexicalCandidate);
  const resolved = resolver.resolve(sourcePath);
  if (resolved != null) {
    console.log(resolved.path);
    process.exit(0);
  }
}

process.exit(1);
NODE
}

validate_staged_browser_plugin_directory() {
    local root="$1"
    local relative_plugin="$2"

    node - \
        "$root" \
        "$relative_plugin" \
        "$BUNDLED_PLUGIN_CONTAINMENT_HELPER" <<'NODE'
const path = require("path");
const { createPluginContainmentResolver } = require(process.argv[4]);

const resolver = createPluginContainmentResolver(process.argv[2], {
  requiredFiles: [
    path.join(".codex-plugin", "plugin.json"),
    path.join("scripts", "browser-client.mjs"),
  ],
  expectedManifestName: "browser",
  maxEntries: 100000,
});
process.exit(resolver.resolve(process.argv[3]) == null ? 1 : 0);
NODE
}

stage_browser_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local target_name="browser"
    local target_plugin="$target_plugins/$target_name"
    local source_client="$source_plugin/scripts/browser-client.mjs"
    local staging_plugin=""
    local staging_client=""
    local backup_plugin="$target_plugins/.browser.backup.$$"

    if [ -L "$target_plugins" ] || [ ! -d "$target_plugins" ]; then
        warn "Browser plugin staging root is missing or is a symlink"
        return 1
    fi

    if [ ! -d "$source_plugin" ]; then
        info "Browser bundled plugin resources not present in upstream app; skipping Browser"
        return 1
    fi

    if [ ! -f "$source_plugin/.codex-plugin/plugin.json" ]; then
        warn "Browser plugin manifest not found in upstream app; skipping Browser"
        return 1
    fi

    if [ ! -f "$source_client" ]; then
        warn "Browser browser-client.mjs not found in upstream app; skipping Browser"
        return 1
    fi

    if ! staging_plugin="$(mktemp -d "$target_plugins/.browser.tmp.XXXXXX")"; then
        warn "Could not create a temporary Browser plugin staging directory"
        return 1
    fi
    staging_client="$staging_plugin/scripts/browser-client.mjs"

    if ! cp -R "$source_plugin/." "$staging_plugin/"; then
        warn "Could not copy the Browser plugin from upstream resources"
        remove_bundled_plugin_tree_safely "$staging_plugin" \
            || warn "Could not clean the failed Browser plugin staging directory"
        return 1
    fi
    if ! validate_staged_browser_plugin_directory \
        "$target_plugins" "$(basename "$staging_plugin")"; then
        warn "Copied Browser plugin failed pre-patch containment validation"
        remove_bundled_plugin_tree_safely "$staging_plugin" \
            || warn "Could not clean the failed Browser plugin staging directory"
        return 1
    fi
    if ! remove_macos_sidecar_files "$staging_plugin" ||
        ! patch_browser_use_node_repl_process_env_import "$staging_client" ||
        ! patch_browser_use_node_repl_env_guard "$staging_client" ||
        ! patch_browser_use_node_repl_config_shim "$staging_client" ||
        ! patch_browser_use_native_pipe_import_meta_bridge "$staging_client" ||
        ! patch_browser_use_site_status_allowlist_fallback "$staging_client" ||
        ! patch_browser_use_file_url_policy "$staging_client" ||
        ! patch_browser_client_iab_socket_scope "$staging_client"; then
        warn "Could not patch the staged Browser plugin"
        remove_bundled_plugin_tree_safely "$staging_plugin" \
            || warn "Could not clean the failed Browser plugin staging directory"
        return 1
    fi

    if ! validate_staged_browser_plugin_directory \
        "$target_plugins" "$(basename "$staging_plugin")"; then
        warn "Patched Browser plugin failed post-patch containment validation"
        remove_bundled_plugin_tree_safely "$staging_plugin" \
            || warn "Could not clean the failed Browser plugin staging directory"
        return 1
    fi

    if ! remove_bundled_plugin_tree_safely "$backup_plugin"; then
        warn "Could not prepare the Browser plugin backup path"
        remove_bundled_plugin_tree_safely "$staging_plugin" || true
        return 1
    fi
    if [ -e "$target_plugin" ] || [ -L "$target_plugin" ]; then
        if ! mv -- "$target_plugin" "$backup_plugin"; then
            warn "Could not preserve the existing Browser plugin"
            remove_bundled_plugin_tree_safely "$staging_plugin" || true
            return 1
        fi
    else
        backup_plugin=""
    fi
    if ! mv -- "$staging_plugin" "$target_plugin"; then
        remove_bundled_plugin_tree_safely "$staging_plugin" || true
        if [ -n "$backup_plugin" ]; then
            if mv -- "$backup_plugin" "$target_plugin"; then
                warn "Could not install the Browser plugin; previous target was restored"
            else
                warn "Could not install the Browser plugin and previous target could not be restored"
            fi
        else
            warn "Could not install the Browser plugin"
        fi
        return 1
    fi
    if [ -n "$backup_plugin" ] &&
        ! remove_bundled_plugin_tree_safely "$backup_plugin"; then
        warn "Could not clean the previous Browser plugin backup: $backup_plugin"
    fi

    info "Browser plugin staged from upstream DMG"
    return 0
}

write_bundled_plugins_marketplace() {
    local source="$1"
    local marketplace_root="$2"
    local selected_browser_source="$3"
    local include_browser="$4"
    local include_chrome="$5"
    local include_computer_use="$6"

    shift 6

    node - \
        "$source" \
        "$marketplace_root" \
        "$selected_browser_source" \
        "$include_browser" \
        "$include_chrome" \
        "$include_computer_use" \
        "$BUNDLED_PLUGIN_CONTAINMENT_HELPER" \
        "$@" <<'NODE'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { createPluginContainmentResolver } = require(process.argv[8]);

const sourcePath = process.argv[2];
const marketplaceRoot = path.resolve(process.argv[3]);
const selectedBrowserSource = process.argv[4];
const includeBrowser = process.argv[5] === "1";
const includeChrome = process.argv[6] === "1";
const includeComputerUse = process.argv[7] === "1";
const portablePluginNames = process.argv.slice(9);
const destinationDirectory = path.join(marketplaceRoot, ".agents", "plugins");
const destinationPath = path.join(destinationDirectory, "marketplace.json");
const marketplace = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
if (marketplace == null || typeof marketplace !== "object" || Array.isArray(marketplace)) {
  throw new Error("Bundled marketplace must be a JSON object");
}
if (marketplace.plugins != null && !Array.isArray(marketplace.plugins)) {
  throw new Error("Bundled marketplace plugins must be an array");
}
const sourcePlugins = marketplace.plugins || [];
const plugins = [];

if (includeBrowser) {
  const stagedResolver = createPluginContainmentResolver(marketplaceRoot, {
    requiredFiles: [
      path.join(".codex-plugin", "plugin.json"),
      path.join("scripts", "browser-client.mjs"),
    ],
    expectedManifestName: "browser",
    maxEntries: 100000,
  });
  const stagedBrowser = stagedResolver.resolve("plugins/browser");
  if (stagedBrowser == null) {
    throw new Error("Staged Browser plugin path is missing or unsafe");
  }

  const sourceRoot = path.resolve(path.dirname(sourcePath), "..", "..");
  const selectedPath = path.resolve(selectedBrowserSource);
  const isStrictlyInside = (root, candidate) => {
    const relative = path.relative(root, candidate);
    return (
      relative.length > 0 &&
      relative !== ".." &&
      !relative.startsWith(`..${path.sep}`) &&
      !path.isAbsolute(relative)
    );
  };
  const browser = sourcePlugins.find((plugin) => {
    if (plugin == null || typeof plugin !== "object" || plugin.name !== "browser") {
      return false;
    }
    const source = plugin.source;
    if (
      source == null ||
      source.source !== "local" ||
      typeof source.path !== "string" ||
      source.path.length === 0 ||
      path.isAbsolute(source.path)
    ) {
      return false;
    }
    const candidate = path.resolve(sourceRoot, source.path);
    return isStrictlyInside(sourceRoot, candidate) && candidate === selectedPath;
  });
  if (browser == null) {
    throw new Error("Bundled marketplace does not contain the selected Browser plugin");
  }
  plugins.push({
    ...browser,
    source: {
      source: "local",
      path: "./plugins/browser",
    },
  });
}

if (includeChrome) {
  const chrome = sourcePlugins.find((plugin) => plugin.name === "chrome");
  if (chrome != null) {
    plugins.push(chrome);
  } else {
    let name = "chrome";
    let category = "Productivity";
    const stagedManifestPath = path.join(
      marketplaceRoot,
      "plugins",
      "chrome",
      ".codex-plugin",
      "plugin.json",
    );
    try {
      const manifest = JSON.parse(fs.readFileSync(stagedManifestPath, "utf8"));
      if (typeof manifest.name === "string" && manifest.name.length > 0) {
        name = manifest.name;
      }
      const manifestCategory =
        manifest && manifest.interface ? manifest.interface.category : undefined;
      if (typeof manifestCategory === "string" && manifestCategory.length > 0) {
        category = manifestCategory;
      }
    } catch (_err) {
      // Fall through to defaults when the staged plugin manifest is
      // missing or malformed — stage_chrome_plugin_from_upstream only
      // existence-checks plugin.json, so it can still be unparseable here.
    }
    plugins.push({
      name,
      source: {
        source: "local",
        path: "./plugins/chrome",
      },
      policy: {
        installation: "AVAILABLE",
        authentication: "ON_INSTALL",
      },
      category,
    });
  }
}

if (includeComputerUse) {
  plugins.push({
    name: "computer-use",
    source: {
      source: "local",
      path: "./plugins/computer-use",
    },
    policy: {
      installation: "AVAILABLE",
      authentication: "ON_INSTALL",
    },
    category: "Productivity",
  });
}

for (const name of portablePluginNames) {
  const plugin = sourcePlugins.find((entry) => {
    if (entry == null || typeof entry !== "object" || entry.name !== name) {
      return false;
    }
    const source = entry.source;
    if (source == null || source.source !== "local" || typeof source.path !== "string") {
      return false;
    }
    const normalized = path.posix.normalize(source.path.replace(/\\/g, "/"));
    return normalized === `plugins/${name}`;
  });
  if (plugin == null) {
    throw new Error(`Bundled marketplace does not contain ${name} plugin`);
  }
  plugins.push({
    ...plugin,
    source: {
      source: "local",
      path: `./plugins/${name}`,
    },
  });
}

const sourceOrder = new Map(sourcePlugins.map((plugin, index) => [plugin?.name, index]));
plugins.sort((left, right) => {
  const leftIndex = sourceOrder.get(left.name) ?? Number.MAX_SAFE_INTEGER;
  const rightIndex = sourceOrder.get(right.name) ?? Number.MAX_SAFE_INTEGER;
  return leftIndex - rightIndex;
});

marketplace.plugins = plugins;
const marketplaceRootParent = path.dirname(marketplaceRoot);
const marketplaceRootParentMetadata = fs.lstatSync(marketplaceRootParent, {
  throwIfNoEntry: false,
});
if (
  marketplaceRootParentMetadata == null ||
  marketplaceRootParentMetadata.isSymbolicLink() ||
  !marketplaceRootParentMetadata.isDirectory()
) {
  throw new Error("Bundled marketplace destination parent is unsafe");
}
for (const directoryPath of [
  marketplaceRoot,
  path.join(marketplaceRoot, ".agents"),
  destinationDirectory,
]) {
  const metadata = fs.lstatSync(directoryPath, { throwIfNoEntry: false });
  if (metadata == null) {
    fs.mkdirSync(directoryPath, { mode: 0o755 });
  } else if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`Unsafe bundled marketplace destination directory: ${directoryPath}`);
  }
}
const destinationMetadata = fs.lstatSync(destinationPath, { throwIfNoEntry: false });
if (
  destinationMetadata != null &&
  (destinationMetadata.isSymbolicLink() || !destinationMetadata.isFile())
) {
  throw new Error("Bundled marketplace destination must be a regular file");
}
const temporaryPath = path.join(
  destinationDirectory,
  `.marketplace.${process.pid}.${crypto.randomBytes(8).toString("hex")}.tmp`,
);
try {
  fs.writeFileSync(temporaryPath, `${JSON.stringify(marketplace, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o644,
  });
  fs.renameSync(temporaryPath, destinationPath);
} finally {
  fs.rmSync(temporaryPath, { force: true });
}
NODE
}

harden_bundled_plugin_source_tree() {
    local resources_dir="$INSTALL_DIR/resources"
    local bundled_plugins_dir="$resources_dir/plugins/openai-bundled"

    [ -d "$bundled_plugins_dir" ] || return 0
    chmod go-w "$INSTALL_DIR" "$resources_dir" "$resources_dir/plugins"
    chmod -R u+rwX,go-w "$bundled_plugins_dir"
}

install_bundled_plugin_resources() {
    local app_dir="$1"
    local upstream_resources="$app_dir/Contents/Resources"
    local bundled_source_root="$upstream_resources/plugins/openai-bundled"
    local source_marketplace="$bundled_source_root/.agents/plugins/marketplace.json"
    local source_browser_plugin=""
    local source_chrome_plugin="$upstream_resources/plugins/openai-bundled/plugins/chrome"
    local resources_dir="$INSTALL_DIR/resources"
    local bundled_plugins_dir="$resources_dir/plugins/openai-bundled"
    local include_browser=0
    local include_chrome=0
    local include_computer_use=0
    local portable_plugin_names=""
    local portable_plugins=()
    local staging_component

    # No staging operation may traverse a pre-existing symlink in the managed
    # install tree, including bundled skills which are staged before plugins.
    for staging_component in \
        "$INSTALL_DIR" \
        "$resources_dir" \
        "$resources_dir/plugins" \
        "$bundled_plugins_dir" \
        "$bundled_plugins_dir/plugins" \
        "$bundled_plugins_dir/.agents" \
        "$bundled_plugins_dir/.agents/plugins"; do
        if [ -L "$staging_component" ]; then
            warn "Bundled resource staging path contains a symlink: $staging_component"
            return 1
        fi
    done

    if ! stage_upstream_bundled_skills "$upstream_resources/skills" "$resources_dir/skills"; then
        return 1
    fi

    if [ ! -f "$source_marketplace" ]; then
        warn "Bundled plugin marketplace not found in upstream app; skipping bundled plugins"
        return 0
    fi

    if ! mkdir -p "$bundled_plugins_dir/plugins" "$bundled_plugins_dir/.agents/plugins"; then
        warn "Could not create the bundled plugin staging root"
        return 1
    fi
    for staging_component in \
        "$INSTALL_DIR" \
        "$resources_dir" \
        "$resources_dir/plugins" \
        "$bundled_plugins_dir" \
        "$bundled_plugins_dir/plugins" \
        "$bundled_plugins_dir/.agents" \
        "$bundled_plugins_dir/.agents/plugins"; do
        if [ -L "$staging_component" ] || [ ! -d "$staging_component" ]; then
            warn "Bundled plugin staging path is not a safe directory: $staging_component"
            return 1
        fi
    done

    if ! portable_plugin_names="$(list_portable_bundled_plugins "$source_marketplace")"; then
        warn "Could not parse portable bundled plugins from upstream marketplace"
        portable_plugin_names=""
    fi
    while IFS= read -r plugin_name; do
        [ -n "$plugin_name" ] || continue
        if stage_portable_bundled_plugin_from_upstream \
            "$bundled_source_root/plugins/$plugin_name" \
            "$bundled_plugins_dir/plugins" \
            "$plugin_name"; then
            portable_plugins+=("$plugin_name")
        fi
    done <<< "$portable_plugin_names"

    if source_browser_plugin="$(find_browser_plugin_source "$bundled_source_root" "$source_marketplace")" &&
        stage_browser_plugin_from_upstream "$source_browser_plugin" "$bundled_plugins_dir/plugins"; then
        include_browser=1
    else
        info "Browser bundled plugin resources not present in upstream app; skipping Browser"
    fi

    if stage_chrome_plugin_from_upstream "$source_chrome_plugin" "$bundled_plugins_dir/plugins"; then
        include_chrome=1
    fi

    if stage_linux_computer_use_plugin "$bundled_plugins_dir/plugins"; then
        include_computer_use=1
    else
        warn "Linux Computer Use plugin will be unavailable"
    fi

    if [ "$include_browser" -eq 0 ] && [ "$include_chrome" -eq 0 ] && [ "$include_computer_use" -eq 0 ] && [ "${#portable_plugins[@]}" -eq 0 ]; then
        warn "No Linux-safe bundled plugins were staged"
        return 0
    fi

    write_bundled_plugins_marketplace \
        "$source_marketplace" \
        "$bundled_plugins_dir" \
        "$source_browser_plugin" \
        "$include_browser" \
        "$include_chrome" \
        "$include_computer_use" \
        "${portable_plugins[@]}"

    install_linux_executable_resource "$upstream_resources/node" "$resources_dir/node" "node runtime" "info" || true
    install_browser_use_node_repl_resource "$upstream_resources" "$resources_dir/node_repl" || true

    info "Linux-safe bundled plugins installed"
}
