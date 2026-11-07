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

# ---------- 探针内部助手：只用套件保证的变量 ----------
kk_init() { # 契约变量的兜底：e2e 的 identity_check 是直调，不走 run_hook 的 SMOKE_* 导出（底座缺口，见 PR），
  # 过渡期回退到同值的 E2E_*；套件在直调前补导出后这里自动只用 SMOKE_*，兜底可删。
  SMOKE_JAR="${SMOKE_JAR:-${E2E_JAR:-}}"
  SMOKE_WEB_URL="${SMOKE_WEB_URL:-${E2E_WEB_URL:-}}"
  SMOKE_OWNER="${SMOKE_OWNER:-${E2E_OWNER:-}}"
  SMOKE_BASE="${SMOKE_BASE:-${E2E_BASE:-}}"
  SMOKE_TOKEN="${SMOKE_TOKEN:-${E2E_TOKEN:-}}"
  local name
  for name in SMOKE_JAR SMOKE_WEB_URL SMOKE_BASE SMOKE_TOKEN; do
    [[ -n "${!name:-}" ]] || { echo "套件没有给 \$$name（SMOKE_* 与 E2E_* 都为空）"; return 1; }
  done
}

kk_login() { # 主人会话种进 SMOKE_JAR，再手动走一遍应用自己的 OAuth 发起请求建立应用会话。
  # 应用的“自动跳转”是客户端 JS（signIn() → POST /api/auth/sign-in/social → 浏览器跳 provider），
  # curl 跟重定向到 /signin 就停了（2026-11-07 e2e 实测），所以手动发这个 POST 拿 provider 地址，
  # 带 jar 走 Hydra（jar 里有核心会话）→ 回调换 code 建会话。成功判据：jar 里出现 better-auth 会话 cookie
  # 且 /api/v1/users/me 返回 200。全程关键步骤都往 stderr 打，失败原因不用猜。
  # 不用 dweb：它写 dev.sh 的默认 jar，e2e 里和 SMOKE_JAR 不是同一个文件（data_write 跑在套件 web_login 之前）。
  local try code resp oauth_url coreline
  for try in 1 2 3; do
    code="$(curl -sS --noproxy '*' -o /dev/null -c "$SMOKE_JAR" -w '%{http_code}' \
      --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" 2>&1)" || code="curl错误:$code"
    coreline="$(grep -c wonton. "$SMOKE_JAR" 2>/dev/null || echo 0)"
    echo "核心登录 HTTP $code，jar 里 wonton 域 cookie ${coreline} 条" >&2
    resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' \
      -H "Origin: $SMOKE_WEB_URL" --data '{"provider":"custom","callbackURL":"/","errorCallbackURL":"/signin"}' \
      -w $'\nHTTP:%{http_code} LOC:%{redirect_url}' "$SMOKE_WEB_URL/api/auth/sign-in/social" 2>&1)" || resp=""
    oauth_url="$(jq -re '.url // empty' <<<"$resp" 2>/dev/null)" || oauth_url=""
    if [[ -z "$oauth_url" ]]; then
      echo "social 响应：$(tail -1 <<<"$resp") 正文开头：$(head -c 200 <<<"$resp")" >&2
      sleep 10
      continue
    fi
    curl -sS --noproxy '*' -o /dev/null -L --max-redirs 30 -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$oauth_url" || true
    if grep -q better-auth "$SMOKE_JAR" &&
      curl -fsS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" "$SMOKE_WEB_URL/api/v1/users/me"; then
      return 0
    fi
    echo "走了 provider 但应用会话没建起来（jar better-auth cookie：$(grep -c better-auth "$SMOKE_JAR" 2>/dev/null || echo 0) 条）" >&2
    (( try < 3 )) && sleep 10
  done
  echo "OIDC 登录链没建立应用会话" >&2
  return 1
}

kk_key_create() { # 经应用自己的设置接口建 API key（和网页“设置 → API 密钥”是同一个请求，superjson 格式）
  local resp
  resp="$(curl -sS --noproxy '*' -X POST -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" -H "Referer: $SMOKE_WEB_URL/" \
    --data '{"0":{"json":{"name":"wonton-e2e"}}}' \
    "$SMOKE_WEB_URL/api/trpc/apiKeys.create?batch=1")" || { echo "apiKeys.create 请求失败：$resp" >&2; return 1; }
  local key
  key="$(jq -re '.[0].result.data.json.key // empty' <<<"$resp" 2>/dev/null)" || key=""
  [[ -n "$key" ]] || { echo "apiKeys.create 响应里没有 key：$(head -c 200 <<<"$resp")" >&2; return 1; }
  printf '%s\n' "$key"
}

kk_key_ok() { # 标记文件里的 key 还能用（数据库在升级和重装后都保留）
  [[ -f ${SMOKE_STATE:-} && -s "$SMOKE_STATE" ]] || return 1
  # shellcheck source=/dev/null
  . "$SMOKE_STATE"
  [[ -n "${KK_API_KEY:-}" ]] || return 1
  curl -fsS --noproxy '*' -o /dev/null -H "Authorization: Bearer $KK_API_KEY" "${SMOKE_WEB_URL:-}/api/v1/users/me"
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
  kk_init || return 1
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local me
  me="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "${SMOKE_WEB_URL:-}/api/v1/users/me")" ||
    { echo "users/me 请求失败"; return 1; }
  # 主人名非空才比对（e2e 直调未导出时兜底也可能为空；localUser==false 已证明是 OIDC 建的号）。
  if [[ -n "$SMOKE_OWNER" ]]; then
    jq -e --arg owner "$SMOKE_OWNER" '.localUser == false and .name == $owner' <<<"$me" >/dev/null ||
      { echo "当前用户不是主人 $SMOKE_OWNER：$(head -c 200 <<<"$me")"; return 1; }
  else
    echo "SMOKE_OWNER 未导出，未断言用户名，只断言 OIDC 用户" >&2
    jq -e '.localUser == false' <<<"$me" >/dev/null ||
      { echo "当前用户是本地密码账号：$me"; return 1; }
  fi
}

data_write() { # 写一条真实书签（文字书签，内容带时间戳），id 和内容随标记文件覆盖写
  kk_init || return 1
  kk_prepare || { echo "登录或建 API key 失败"; return 1; }
  local text id resp
  text="云吞 e2e 数据探针 $(date +%Y%m%d%H%M%S)"
  resp="$(curl -fsS --noproxy '*' -X POST \
    -H "Authorization: Bearer $KK_API_KEY" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg t "$text" '{type:"text",text:$t}')" \
    "${SMOKE_WEB_URL:-}/api/v1/bookmarks")" || { echo "建书签失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$resp")"
  [[ -n "$id" ]] || { echo "建书签响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
  kk_state_write "$KK_API_KEY" "$id" "$text"
}

data_check() { # 断言 data_write 写的书签还在、内容一字不差
  kk_init || return 1
  [[ -f ${SMOKE_STATE:-} && -s "$SMOKE_STATE" ]] || { echo "标记文件里没有数据：先跑 data_write"; return 1; }
  # shellcheck source=/dev/null
  . "$SMOKE_STATE"
  [[ -n "${KK_API_KEY:-}" && -n "${KK_BOOKMARK_ID:-}" && -n "${KK_BOOKMARK_TEXT:-}" ]] ||
    { echo "标记文件不完整：$SMOKE_STATE"; return 1; }
  local resp text
  resp="$(curl -fsS --noproxy '*' -H "Authorization: Bearer $KK_API_KEY" "${SMOKE_WEB_URL:-}/api/v1/bookmarks/$KK_BOOKMARK_ID")" ||
    { echo "读书签 $KK_BOOKMARK_ID 失败"; return 1; }
  text="$(jq -r '.content.text // empty' <<<"$resp")"
  [[ "$text" == "$KK_BOOKMARK_TEXT" ]] ||
    { echo "书签内容对不上：期望「$KK_BOOKMARK_TEXT」，拿到「$text」"; return 1; }
}
