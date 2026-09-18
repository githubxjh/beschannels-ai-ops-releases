#!/bin/sh
set -u

version='0.1.0-candidate.32'
channel='pilot'
archive_url='https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.32/releases/0.1.0-candidate.32/macos-arm64/beschannels-ai-ops-0.1.0-candidate.32-macos-arm64.zip'
archive_sha256='72A1DBC3EBD8F226A4140EF2C8B028D525C6E540C91B588F2F2F6959883E67E0'
manifest_url='https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.32/releases/0.1.0-candidate.32/macos-arm64/manifest.json'
manifest_sha256='38340C5EA100BD479BBD5DB1911A60B6EEE861F7AB2751767AE2C217E5966DA1'
case "$manifest_url" in
  */releases/*) signed_channel_base="${manifest_url%%/releases/*}/channels" ;;
  *)
    printf '%s\n' '{"ok":false,"error":{"code":"invalid_manifest_url","message":"发布清单地址缺少版本路径。"}}'
    exit 2
    ;;
esac
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

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b""): h.update(chunk)
    print(h.hexdigest().upper())
except OSError as e:
    print("READ_ERROR: " + str(e), file=sys.stderr); raise SystemExit(10)
except Exception as e:
    print("TOOL_ERROR: " + str(e), file=sys.stderr); raise SystemExit(11)
PY
}
actual_archive=$(sha256_file "$archive") || { printf '%s\n' '{"ok":false,"error":{"code":"hash_tool_or_read_failed","message":"安装包哈希工具或读文件失败。"}}'; exit 2; }
actual_manifest=$(sha256_file "$manifest") || { printf '%s\n' '{"ok":false,"error":{"code":"hash_tool_or_read_failed","message":"发布清单哈希工具或读文件失败。"}}'; exit 2; }
if [ "$actual_archive" != "$archive_sha256" ] || [ "$actual_manifest" != "$manifest_sha256" ]; then
  printf '%s\n' '{"ok":false,"error":{"code":"hash_mismatch","message":"安装包或发布清单哈希不匹配。"}}'
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
for required in ("bin/beschannels-ai", "skills/beschannels-ai-ops/SKILL.md", "skills/beschannels-marketing-automation/SKILL.md"):
    if required not in actual:
        raise SystemExit("required release file missing")
PY

chmod 755 "$staging/bin/beschannels-ai" "$staging/skills/beschannels-ai-ops/scripts/invoke-runtime.sh"
mkdir -p "$install_root/versions" "$install_root/release-metadata" "$skill_root" "$HOME/.local/bin"
target="$install_root/versions/$version"
target_backup="$install_root/versions/.previous-$version"
# 保留旧版本，直到 doctor 通过后再提交事务。
if [ -d "$target" ]; then
  mv "$target" "$target_backup"
fi
mv "$staging" "$target"

skill_stage="$skill_root/.beschannels-ai-ops-$version"
rm -rf "$skill_stage"
ditto "$target/skills/beschannels-ai-ops" "$skill_stage"
skill_backup="$skill_root/.beschannels-ai-ops-previous"
rm -rf "$skill_backup"
if [ -d "$skill_root/beschannels-ai-ops" ]; then
  mv "$skill_root/beschannels-ai-ops" "$skill_backup"
fi
mv "$skill_stage" "$skill_root/beschannels-ai-ops"
rm -rf "$skill_root/beschannels-marketing-automation"
ditto "$target/skills/beschannels-marketing-automation" "$skill_root/beschannels-marketing-automation"

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

doctor=''; channel_check=''; doctor_rc=0; channel_rc=0
doctor=$($HOME/.local/bin/beschannels-ai doctor --output json 2>&1) || doctor_rc=$?
printf '%s\n' "{\"installed\":{\"status\":\"installed\",\"exit_code\":0},\"doctor\":{\"status\":\"$([ "$doctor_rc" -eq 0 ] && echo passed || echo failed)\",\"exit_code\":$doctor_rc,\"output\":$([ -n "$doctor" ] && python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$doctor" || echo null)}}"
if [ "$doctor_rc" -ne 0 ]; then
  rm -rf "$target"
  if [ -d "$target_backup" ]; then mv "$target_backup" "$target"; fi
  exit 2
fi
channel_check=$(BESCHANNELS_AI_RELEASE_BASE_URL="$signed_channel_base" "$HOME/.local/bin/beschannels-ai" update --channel "$channel" --output json 2>&1) || channel_rc=$?
printf '%s\n' "{\"channel_check\":{\"status\":\"$([ "$channel_rc" -eq 0 ] && echo passed || echo failed)\",\"exit_code\":$channel_rc,\"output\":$([ -n "$channel_check" ] && python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$channel_check" || echo null)}}"
[ "$channel_rc" -eq 0 ] || exit 3
rm -rf "$target_backup"
