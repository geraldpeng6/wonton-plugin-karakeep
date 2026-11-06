# shellcheck shell=bash
# scripts/smoke.sh / e2e/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 数据：data_write 写一条真实用户数据，data_check 断言它还在（升级、重装后各跑一次）。
# 装之前要准备（如先配出口代理）：写 before_install。

# sso=oidc：打开网页自动跳云吞登录（DISABLE_PASSWORD_AUTH + OAUTH_AUTO_REDIRECT）。
# 清单没有 mcp：上游 MCP 镜像只支持 stdio 传输，云吞只收 streamable-http（取舍见 README / PR）。
# shellcheck disable=SC2034  # SSO/MCP 由冒烟套件读取
SSO=oidc
MCP=0

# 页面标记用 <title>：核心的登录页/错误页不会以 Karakeep 为标题（但跳转参数里可能带插件地址，
# 所以不能只 grep 'karakeep' 词）。
web_assert() { grep -qE '<title[^>]*>[Kk]arakeep'; }

# ---------- 探针内部用的上下文：套件（dev.sh probes）和 e2e 都能跑 ----------
# 在探针开始时求值：套件先 source 本文件、后来才设 SMOKE_WEB_URL 这些变量，不能在文件加载时取。
kk_init() { # 出错时说明原因并返回 1
  kk_dir="${E2E_DIR:-$SMOKE_DIR}"
  kk_state="$kk_dir/.wonton"
  kk_file="$kk_state/probe.env"                               # API key、书签 id 和写入内容
  kk_web="${E2E_WEB_URL:-$SMOKE_WEB_URL}"
  # dweb 写会话进的 jar：套件里是 SMOKE_JAR，e2e 里是 dev.sh web 的默认 jar。
  kk_jar="${SMOKE_JAR:-$kk_state/session.cookies}"
  [[ -n "$kk_web" ]] || { echo "拿不到插件网页地址（SMOKE_WEB_URL / E2E_WEB_URL 都为空）"; return 1; }
}

kk_owner_email() { # 核心注入的主人邮箱：套件里是环境变量，e2e 在实例 .env 里
  if [[ -n "${WONTON_OWNER_EMAIL:-}" ]]; then
    printf '%s\n' "$WONTON_OWNER_EMAIL"
  else
    sed -n 's/^WONTON_OWNER_EMAIL=//p' "$kk_state/.env" 2>/dev/null | tail -1
  fi
}

kk_walk() { # 走完 OIDC：应用自动跳身份方，核心会话在 jar 里时一路 302 回到应用并建好应用会话
  local try final
  for try in 1 2 3; do
    final="$(dweb --sso /)" || final=""
    grep -qi 'karakeep' <<<"$final" && return 0
    (( try < 3 )) && sleep 10
  done
  echo "OIDC 登录链没有落到应用：$(head -c 120 <<<"$final")"
  return 1
}

kk_key_create() { # 经应用自己的设置接口建 API key（和网页“设置 → API 密钥”是同一个请求，superjson 格式）
  local resp
  resp="$(curl -sS --noproxy '*' -X POST -b "$kk_jar" -c "$kk_jar" \
    -H 'Content-Type: application/json' -H "Origin: $kk_web" -H "Referer: $kk_web/" \
    --data '{"0":{"json":{"name":"wonton-e2e"}}}' \
    "$kk_web/api/trpc/apiKeys.create?batch=1")" || { echo "apiKeys.create 请求失败"; return 1; }
  local key
  key="$(jq -re '.[0].result.data.json.key // empty' <<<"$resp" 2>/dev/null)" || key=""
  [[ -n "$key" ]] || { echo "apiKeys.create 响应里没有 key：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s\n' "$key"
}

kk_key_ok() { # 旧 key 还能用（数据库在升级和重装后都保留）
  [[ -s "$kk_file" ]] || return 1
  # shellcheck source=/dev/null
  . "$kk_file"
  [[ -n "${KK_API_KEY:-}" ]] || return 1
  curl -fsS --noproxy '*' -o /dev/null -H "Authorization: Bearer $KK_API_KEY" "$kk_web/api/v1/users/me"
}

kk_prepare() { # 登录链 + 可用的 API key
  kk_init || return 1
  kk_walk || return 1
  kk_key_ok && return 0
  KK_API_KEY="$(kk_key_create)" || return 1
  printf 'KK_API_KEY=%s\n' "$KK_API_KEY" >"$kk_file"
}

identity_check() { # 应用认出的是主人本人：/api/v1/users/me 的邮箱 == 核心注入的主人邮箱，且是 OIDC 用户
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local me email want
  me="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "$kk_web/api/v1/users/me")" ||
    { echo "users/me 请求失败"; return 1; }
  want="$(kk_owner_email)"
  email="$(jq -r '.email // empty' <<<"$me")"
  [[ -n "$want" && "$email" == "$want" ]] ||
    { echo "当前用户不是主人：$(head -c 200 <<<"$me")（期望邮箱 $want）"; return 1; }
  jq -e '.localUser == false' <<<"$me" >/dev/null ||
    { echo "当前用户是本地账号而不是 OIDC 登录：$me"; return 1; }
}

data_write() { # 写一条真实书签（文字书签，内容带时间戳），id 和内容存进探针状态
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local text id resp
  text="云吞 e2e 数据探针 $(date +%Y%m%d%H%M%S)"
  resp="$(curl -fsS --noproxy '*' -X POST \
    -H "Authorization: Bearer $KK_API_KEY" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg t "$text" '{type:"text",text:$t}')" \
    "$kk_web/api/v1/bookmarks")" || { echo "建书签失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$resp")"
  [[ -n "$id" ]] || { echo "建书签响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
  printf 'KK_API_KEY=%s\nKK_BOOKMARK_ID=%s\nKK_BOOKMARK_TEXT=%s\n' "$KK_API_KEY" "$id" "$text" >"$kk_file"
}

data_check() { # 断言 data_write 写的书签还在、内容一字不差
  kk_init || return 1
  [[ -s "$kk_file" ]] || { echo "探针状态里没有书签：先跑 data_write"; return 1; }
  # shellcheck source=/dev/null
  . "$kk_file"
  [[ -n "${KK_BOOKMARK_ID:-}" && -n "${KK_BOOKMARK_TEXT:-}" ]] || { echo "探针状态不完整：$kk_file"; return 1; }
  local resp text
  resp="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "$kk_web/api/v1/bookmarks/$KK_BOOKMARK_ID")" ||
    { echo "读书签 $KK_BOOKMARK_ID 失败"; return 1; }
  text="$(jq -r '.content.text // empty' <<<"$resp")"
  [[ "$text" == "$KK_BOOKMARK_TEXT" ]] ||
    { echo "书签内容对不上：期望「$KK_BOOKMARK_TEXT」，拿到「$text」"; return 1; }
}
