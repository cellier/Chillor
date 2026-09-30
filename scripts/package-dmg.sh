#!/bin/zsh
# Package the already built/signed canonical app and verify a mounted round trip.
set -euo pipefail
cd "${0:A:h:h}"
release_label="${1:-$(date +%Y.%m.%d)}"
[[ "$release_label" != *[^0-9A-Za-z.-]* ]] || { print -u2 'Invalid release label'; exit 1; }
app_path="$PWD/outputs/Chillor.app"
output_dir="$PWD/outputs/内测试用包"
target_dmg="$output_dir/Chillor-Preview-${release_label}-AppleSilicon.dmg"
codesign --verify --deep --strict "$app_path"
mkdir -p "$output_dir" "$PWD/work"
scratch_dir=$(mktemp -d "$PWD/work/dmg-package.XXXXXX")
cleanup() {
  if mount | /usr/bin/grep -Fq " on $scratch_dir/mount "; then
    hdiutil detach "$scratch_dir/mount" >/dev/null || return
  fi
  rm -rf "$scratch_dir"
}
trap cleanup EXIT
mkdir -p "$scratch_dir/stage" "$scratch_dir/mount"
ditto "$app_path" "$scratch_dir/stage/Chillor.app"
ln -s /Applications "$scratch_dir/stage/Applications"
install_notes="$output_dir/安装与试用说明.txt"
[[ -f "$install_notes" ]] || install_notes="$PWD/docs/public/INSTALL.txt"
cp "$install_notes" "$scratch_dir/stage/先读我.txt"
hdiutil create -volname Chillor -fs APFS -srcfolder "$scratch_dir/stage" \
  -format UDZO -imagekey zlib-level=9 "$scratch_dir/Chillor.dmg"
hdiutil verify "$scratch_dir/Chillor.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$scratch_dir/mount" "$scratch_dir/Chillor.dmg"
codesign --verify --deep --strict "$scratch_dir/mount/Chillor.app"
python3 - "$app_path" "$scratch_dir/mount/Chillor.app" "$scratch_dir/manifest.json" <<'PY'
import hashlib,json,os,pathlib,sys
def manifest(root):
    root=pathlib.Path(root);result={}
    for directory,dirs,files in os.walk(root,followlinks=False):
        for name in dirs+files:
            path=pathlib.Path(directory)/name
            relative=str(path.relative_to(root))
            if path.is_symlink():result[relative]={'link':os.readlink(path)}
            elif path.is_file():
                result[relative]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                                  'mode':path.stat().st_mode & 0o777}
    return result
source,mounted=manifest(sys.argv[1]),manifest(sys.argv[2])
assert source==mounted, 'Mounted application differs from the build'
for name in ('personal_memory.py','context_builder.py','deepseek_model.py','sandbox.py'):
    assert 'Contents/Resources/AgentTools/'+name in mounted
assert not any(pathlib.Path(name).name in ('conversation.json','personal-memory.sqlite','session.sqlite') for name in mounted), 'Unexpected user state in installer'
report={'verified':'Full file content, executable permissions and symlink comparison; mounted codesign passed',
        'file_count':len(mounted),'app_binary_sha256':mounted['Contents/MacOS/Chillor']['sha256'],
        'app_manifest_sha256':hashlib.sha256(json.dumps(mounted,sort_keys=True).encode()).hexdigest()}
pathlib.Path(sys.argv[3]).write_text(json.dumps(report,indent=2))
print(json.dumps(report))
PY
hdiutil detach "$scratch_dir/mount"
mv -f "$scratch_dir/Chillor.dmg" "$target_dmg"
mv -f "$scratch_dir/manifest.json" "$output_dir/DMG-verification-${release_label}.json"
(cd "$output_dir" && shasum -a 256 "${target_dmg:t}" > SHA256.txt)
print "Verified DMG: $target_dmg"
