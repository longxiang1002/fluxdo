#!/usr/bin/env bash
# 发布 iOS14 测试包 Release 的回退通道（REST API）。
#
# 为什么存在：GitHub Actions 的 GITHUB_TOKEN 即使已授予 `contents: write`，
# 创建 Release 时仍会**间歇性**返回 403 "Resource not accessible by integration"
# （实测 run 37841469025 / 37844039536：构建与上传 artifact 全绿，仅发布步骤 403，
# 把整个 job 拖成 failure，掩盖了成功的构建）。
# 该脚本用 RELEASE_TOKEN（PAT）直连 REST API 重试发布；未配置 token 时
# 只告警不失败——IPA 已在 artifact 里。
set -uo pipefail

if [ -z "${REL_TOKEN:-}" ]; then
  echo "::warning::未配置 RELEASE_TOKEN，跳过回退发布；IPA 可从 Actions artifact 下载"
  exit 0
fi

API="https://api.github.com/repos/${REL_REPO}"
AUTH=(-H "Authorization: Bearer ${REL_TOKEN}" -H "Accept: application/vnd.github+json")

BODY="自动发布的 iOS14 测试包（无签名，TrollStore 安装）。
- commit: ${REL_SHA}
- 分支: ${REL_REF}
- 构建: GitHub Actions run #${REL_RUN}"

PAYLOAD=$(python3 -c '
import json, sys
print(json.dumps({
    "tag_name": sys.argv[1],
    "name": "iOS14 test build (%s)" % sys.argv[1],
    "body": sys.argv[2],
    "prerelease": True,
}))' "${REL_TAG}" "${BODY}")

echo "创建 Release ${REL_TAG} ..."
CODE=$(curl -sS -o /tmp/rel.json -w '%{http_code}' -X POST \
  "${AUTH[@]}" "${API}/releases" -d "${PAYLOAD}")
echo "create release: HTTP ${CODE}"
if [ "${CODE}" != "201" ] && [ "${CODE}" != "422" ]; then
  echo "::warning::创建 Release 失败（HTTP ${CODE}）：$(head -c 300 /tmp/rel.json)"
  exit 0
fi

REL_ID=$(curl -sS "${AUTH[@]}" "${API}/releases/tags/${REL_TAG}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
if [ -z "${REL_ID}" ]; then
  echo "::warning::未能取得 Release id，跳过资源上传"
  exit 0
fi

for f in "dist/${REL_IPA}" dist/SHA256SUMS.txt dist/build-info.txt \
         dist/ios14-validation.md dist/ipa-inspection.json; do
  [ -f "${f}" ] || continue
  NAME=$(basename "${f}")
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
    "https://uploads.github.com/repos/${REL_REPO}/releases/${REL_ID}/assets?name=${NAME}" \
    --data-binary "@${f}")
  echo "upload ${NAME}: HTTP ${CODE}"
done

echo "回退发布完成：https://github.com/${REL_REPO}/releases/tag/${REL_TAG}"
