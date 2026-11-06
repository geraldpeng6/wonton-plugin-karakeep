# shellcheck shell=bash
# scripts/smoke.sh / e2e/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 只用套件保证的东西：变量 SMOKE_STATE（数据标记文件，data_write 覆盖写、data_check 读）、SMOKE_JAR、
# SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE，助手 web_get、dweb。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。
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

# ---------- 探针内部助手：只用套件保证的变量和 dweb ----------
kk_login() { # 走完 OIDC：应用自动跳身份方，核心会话在 jar 里时一路 302 回到应用并建好应用会话
  local try final
  for try in 1 2 3; do
    final="$(dweb --sso /)" || final=""
    grep -qE '<title[^>]*>[Kk]arakeep' <<<"$final" && return 0
    (( try < 3 )) && sleep 10
  done
  echo "OIDC 登录链没有落到应用：$(head -c 120 <<<"$final")"
  return 1
}

kk_key_create() { # 经应用自己的设置接口建 API key（和网页“设置 → API 密钥”是同一个请求，superjson 格式）
  local resp
  resp="$(curl -sS --noproxy '*' -X POST -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" -H "Referer: $SMOKE_WEB_URL/" \
    --data '{"0":{"json":{"name":"wonton-e2e"}}}' \
    "$SMOKE_WEB_URL/api/trpc/apiKeys.create?batch=1")" || { echo "apiKeys.create 请求失败"; return 1; }
  local key
  key="$(jq -re '.[0].result.data.json.key // empty' <<<"$resp" 2>/dev/null)" || key=""
  [[ -n "$key" ]] || { echo "apiKeys.create 响应里没有 key：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s\n' "$key"
}

kk_key_ok() { # 标记文件里的 key 还能用（数据库在升级和重装后都保留）
  [[ -f ${SMOKE_STATE:-} && -s "$SMOKE_STATE" ]] || return 1
  # shellcheck source=/dev/null
  . "$SMOKE_STATE"
  [[ -n "${KK_API_KEY:-}" ]] || return 1
  curl -fsS --noproxy '*' -o /dev/null -H "Authorization: Bearer $KK_API_KEY" "$SMOKE_WEB_URL/api/v1/users/me"
}

kk_state_write() { # 覆盖写标记文件；套件的 dev.sh probes 里 SMOKE_STATE 是状态目录（不跑数据钩子），跳过
  [[ -d ${SMOKE_STATE:-} ]] && return 0
  printf 'KK_API_KEY=%s\nKK_BOOKMARK_ID=%s\nKK_BOOKMARK_TEXT=%s\n' "$1" "$2" "$3" >"$SMOKE_STATE" ||
    { echo "写不进标记文件 \$SMOKE_STATE"; return 1; }
}

kk_prepare() { # 登录链 + 可用的 API key（标记里的优先，失效就建新的并覆盖标记）
  kk_login || return 1
  if kk_key_ok; then
    # shellcheck source=/dev/null
    . "$SMOKE_STATE"
    return 0
  fi
  KK_API_KEY="$(kk_key_create)" || return 1
  KK_BOOKMARK_ID="" KK_BOOKMARK_TEXT=""
  kk_state_write "$KK_API_KEY" "" ""
}

identity_check() { # 应用认出的是主人本人：/api/v1/users/me 的名字是主人，且是 OIDC 建的号（非本地密码账号）
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local me
  me="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "$SMOKE_WEB_URL/api/v1/users/me")" ||
    { echo "users/me 请求失败"; return 1; }
  jq -e --arg owner "$SMOKE_OWNER" '.localUser == false and .name == $owner' <<<"$me" >/dev/null ||
    { echo "当前用户不是主人 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
}

data_write() { # 写一条真实书签（文字书签，内容带时间戳），id 和内容随标记文件覆盖写
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local text id resp
  text="云吞 e2e 数据探针 $(date +%Y%m%d%H%M%S)"
  resp="$(curl -fsS --noproxy '*' -X POST \
    -H "Authorization: Bearer $KK_API_KEY" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg t "$text" '{type:"text",text:$t}')" \
    "$SMOKE_WEB_URL/api/v1/bookmarks")" || { echo "建书签失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$resp")"
  [[ -n "$id" ]] || { echo "建书签响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
  kk_state_write "$KK_API_KEY" "$id" "$text"
}

data_check() { # 断言 data_write 写的书签还在、内容一字不差
  [[ -f ${SMOKE_STATE:-} && -s "$SMOKE_STATE" ]] || { echo "标记文件里没有数据：先跑 data_write"; return 1; }
  # shellcheck source=/dev/null
  . "$SMOKE_STATE"
  [[ -n "${KK_API_KEY:-}" && -n "${KK_BOOKMARK_ID:-}" && -n "${KK_BOOKMARK_TEXT:-}" ]] ||
    { echo "标记文件不完整：$SMOKE_STATE"; return 1; }
  local resp text
  resp="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "$SMOKE_WEB_URL/api/v1/bookmarks/$KK_BOOKMARK_ID")" ||
    { echo "读书签 $KK_BOOKMARK_ID 失败"; return 1; }
  text="$(jq -r '.content.text // empty' <<<"$resp")"
  [[ "$text" == "$KK_BOOKMARK_TEXT" ]] ||
    { echo "书签内容对不上：期望「$KK_BOOKMARK_TEXT」，拿到「$text」"; return 1; }
}
