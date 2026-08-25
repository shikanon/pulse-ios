#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
fixture_dir="$repo_dir/PulseTests/Fixtures/CelebrityTankBattle"
sandbox_dir=$(mktemp -d "${TMPDIR:-/tmp}/pulse-celebrity-tank.XXXXXX")
model=${PULSE_CODING_MODEL:-gpt-5.4}

cleanup() {
  if [[ ${PULSE_KEEP_GENERATION_SANDBOX:-0} != 1 ]]; then
    rm -rf "$sandbox_dir"
  else
    echo "Sandbox retained at $sandbox_dir"
  fi
}
trap cleanup EXIT

for command_name in codex node npm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

mkdir -p "$sandbox_dir/public/avatars" "$sandbox_dir/.npm-cache"
for file_name in abraham-lincoln.jpg nikola-tesla.jpg ada-lovelace.jpg william-shakespeare.jpg; do
  test -s "$fixture_dir/$file_name" || {
    echo "Missing test fixture: $fixture_dir/$file_name" >&2
    exit 1
  }
  cp "$fixture_dir/$file_name" "$sandbox_dir/public/avatars/$file_name"
done

prompt='生成一个各种名人头像的坦克大战。请直接在当前空工作区创建可运行的 React + TypeScript + Vite 单页互动应用。必须使用 public/avatars 中的四张本地头像作为坦克角色，不使用外部网络资源；实现键盘和触控可操作、敌方移动、发射、碰撞、生命值、胜负和重新开始。补充可自动运行的核心逻辑测试。完成前执行测试和 npm run build，并修复所有失败。'

codex exec "$prompt" \
  --model "$model" \
  --ephemeral \
  --skip-git-repo-check \
  --ignore-rules \
  --sandbox workspace-write \
  --cd "$sandbox_dir" \
  --image "$fixture_dir/abraham-lincoln.jpg" \
  --image "$fixture_dir/nikola-tesla.jpg" \
  --image "$fixture_dir/ada-lovelace.jpg" \
  --image "$fixture_dir/william-shakespeare.jpg"

test -s "$sandbox_dir/package.json"
test -d "$sandbox_dir/src"
npm_config_cache="$sandbox_dir/.npm-cache" npm --prefix "$sandbox_dir" install
npm_config_cache="$sandbox_dir/.npm-cache" npm --prefix "$sandbox_dir" test
npm_config_cache="$sandbox_dir/.npm-cache" npm --prefix "$sandbox_dir" run build

for file_name in abraham-lincoln.jpg nikola-tesla.jpg ada-lovelace.jpg william-shakespeare.jpg; do
  test -s "$sandbox_dir/dist/avatars/$file_name"
done

echo "Real generation E2E passed: model output, tests, production build, and four bundled avatars verified."
