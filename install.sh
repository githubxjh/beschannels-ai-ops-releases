#!/bin/sh
set -eu

version='0.1.0-candidate.6'
channel='pilot'
archive_url='https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.6/releases/0.1.0-candidate.6/macos-arm64/beschannels-ai-ops-0.1.0-candidate.6-macos-arm64.zip'
archive_sha256='4062EF7C256EF83CE9F24FE6B50193947127485C39E31EBE45B6F43128F07656'
manifest_url='https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.6/releases/0.1.0-candidate.6/macos-arm64/manifest.json'
manifest_sha256='383C8717E4CCD5366B1D173B3210F3C8A30E02D801D5A0D05BC980E795D7B3CF'
install_root="${BESCHANNELS_AI_HOME:-$HOME/Library/Application Support/BesChannelsAIOps/runtime}"
skill_root="${BESCHANNELS_AI_SKILL_ROOT:-$HOME/.codex/skills}"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/BesChannelsAIOps.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT INT TERM

if [ "$(uname -s)" != 'Darwin' ] || [ "$(uname -m)" != 'arm64' ]; then
  printf '%s\n' '{"ok":false,"error":{"code":"unsupported_platform","message":"当前安装包仅支持 Apple Silicon Mac。"}}'
  exit 2
fi

archive="$temp_root/release.zip"
manifest="$temp_root/manifest.json"
staging="$temp_root/staging"
curl -fL --retry 3 --connect-timeout 15 "$archive_url?sha=$archive_sha256" -o "$archive"
curl -fL --retry 3 --connect-timeout 15 "$manifest_url?sha=$archive_sha256" -o "$manifest"

actual_archive=$(shasum -a 256 "$archive" | awk '{print toupper($1)}')
actual_manifest=$(shasum -a 256 "$manifest" | awk '{print toupper($1)}')
if [ "$actual_archive" != "$archive_sha256" ] || [ "$actual_manifest" != "$manifest_sha256" ]; then
  printf '%s\n' '{"ok":false,"error":{"code":"hash_mismatch","message":"安装包或发布清单校验失败。"}}'
  exit 2
fi

python3 - "$archive" "$manifest" "$staging" "$version" <<'PY'
import hashlib, json, pathlib, shutil, sys, zipfile
archive_path, manifest_path, staging_path, version = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("version") != str(version) or manifest.get("platform") != "macos-arm64":
    raise SystemExit("release manifest mismatch")
staging_path.mkdir(parents=True)
with zipfile.ZipFile(archive_path) as bundle:
    for member in bundle.infolist():
        relative = pathlib.PurePosixPath(member.filename.replace("\\", "/"))
        if relative.is_absolute() or ".." in relative.parts or any(":" in part for part in relative.parts):
            raise SystemExit("unsafe archive path")
    bundle.extractall(staging_path)
expected = {row["path"]: row for row in manifest["files"]}
actual = {path.relative_to(staging_path).as_posix(): path for path in staging_path.rglob("*") if path.is_file()}
if set(actual) != set(expected):
    raise SystemExit("release file set mismatch")
for name, path in actual.items():
    digest = hashlib.sha256(path.read_bytes()).hexdigest().upper()
    row = expected[name]
    if path.stat().st_size != row["size"] or digest != row["sha256"]:
        raise SystemExit("release file hash mismatch")
for required in ("bin/beschannels-ai", "skills/beschannels-ai-ops/SKILL.md"):
    if required not in actual:
        raise SystemExit("required release file missing")
PY

chmod 755 "$staging/bin/beschannels-ai" "$staging/skills/beschannels-ai-ops/scripts/invoke-runtime.sh"
mkdir -p "$install_root/versions" "$install_root/release-metadata" "$skill_root" "$HOME/.local/bin"
target="$install_root/versions/$version"
target_backup="$install_root/versions/.previous-$version"
rm -rf "$target_backup"
if [ -d "$target" ]; then
  mv "$target" "$target_backup"
fi
mv "$staging" "$target"
rm -rf "$target_backup"

skill_stage="$skill_root/.beschannels-ai-ops-$version"
rm -rf "$skill_stage"
ditto "$target/skills/beschannels-ai-ops" "$skill_stage"
skill_backup="$skill_root/.beschannels-ai-ops-previous"
rm -rf "$skill_backup"
if [ -d "$skill_root/beschannels-ai-ops" ]; then
  mv "$skill_root/beschannels-ai-ops" "$skill_backup"
fi
mv "$skill_stage" "$skill_root/beschannels-ai-ops"

python3 - "$install_root" "$version" "$archive_sha256" "$channel" <<'PY'
import json, os, pathlib, sys, tempfile
root = pathlib.Path(sys.argv[1])
version, archive_sha256, channel = sys.argv[2:]
current = root / "current.json"
previous = None
if current.is_file():
    previous = json.loads(current.read_text(encoding="utf-8")).get("version")
payload = {"schema_version": 1, "version": version, "relative_path": f"versions/{version}", "archive_sha256": archive_sha256, "previous_version": previous, "channel": channel}
fd, temp = tempfile.mkstemp(prefix=".current.", suffix=".tmp", dir=root)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
    json.dump(payload, stream, ensure_ascii=False, sort_keys=True, indent=2)
    stream.write("\n")
os.replace(temp, current)
PY

cat > "$HOME/.local/bin/beschannels-ai" <<'SH'
#!/bin/sh
set -eu
root="${BESCHANNELS_AI_HOME:-$HOME/Library/Application Support/BesChannelsAIOps/runtime}"
version_root=$(python3 - "$root/current.json" <<'PY'
import json, pathlib, sys
current = pathlib.Path(sys.argv[1]).resolve()
root = current.parent
target = (root / json.loads(current.read_text(encoding="utf-8"))["relative_path"]).resolve()
if root != target and root not in target.parents:
    raise SystemExit("unsafe runtime path")
print(target)
PY
)
exec "$version_root/bin/beschannels-ai" "$@"
SH
chmod 755 "$HOME/.local/bin/beschannels-ai"

doctor=$($HOME/.local/bin/beschannels-ai doctor --output json)
signed_check=$($HOME/.local/bin/beschannels-ai update --channel "$channel" --output json)
printf '%s\n' "$doctor"
printf '%s\n' "$signed_check"
