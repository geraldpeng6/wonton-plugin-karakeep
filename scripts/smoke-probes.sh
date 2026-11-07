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

kk_app_log_tail() { # 诊断用（负责人要求）：抓 karakeep 应用容器最后 50 行，看 better-auth 服务端取签发方文档是否失败
  local host inst c
  host="$(sed 's#https\?://##;s#[/:].*##' <<<"${SMOKE_WEB_URL:-}")"
  inst="$(cut -d. -f2 <<<"$host")"
  c="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -x "wonton-$inst--karakeep--web")" || c=""
  if [[ -z "$c" ]]; then
    echo "诊断：karakeep 容器日志拿不到（inst=$inst，docker 不在本机或容器不在跑）" >&2
    return 0
  fi
  echo "===== karakeep 容器（$c）最后 50 行 =====" >&2
  docker logs --tail 50 "$c" 2>&1 | tail -50 >&2
  echo "===== 容器日志完 =====" >&2
}

kk_login() { # 分两步把两个会话都建好（2026-11-07 e2e 逐轮实测的结论）：
  # 1) 核心会话：token POST 返回 303 但不发 cookie（jar 为空，同 jar GET 插件域 401），
  #    必须走 dev.sh 的表单登录回退——用 dweb，并把它写会话的 jar 指到 SMOKE_JAR
  #    （WONTON_DEV_JAR 是 dev.sh 的公开入口，session_jar 读它）。
  # 2) 应用会话：Karakeep 的自动跳转是客户端 JS（signIn.social），curl 触发不了，
  #    手动 POST 应用自己的 /api/auth/sign-in/social 拿 provider 地址，带 jar 走 Hydra → 回调建会话。
  # 成功判据：jar 里有 better-auth 会话 cookie 且 /api/v1/users/me 返回 200。
  kk_init || return 1
  export WONTON_DEV_JAR="$SMOKE_JAR"
  local try resp oauth_url
  # 诊断（负责人要求）：SMOKE_WEB_URL 与 dweb 实际用的地址是否同一实例同一 slug
  echo "诊断：SMOKE_WEB_URL=$SMOKE_WEB_URL" >&2
  for try in 1 2 3; do
    dweb --sso / >/dev/null 2>&1 || true
    echo "诊断：dweb 实际地址=$(dweb / -s -o /dev/null -w '%{url_effective}' 2>/dev/null)" >&2
    grep -q wonton. "$SMOKE_JAR" || { (( try < 3 )) && sleep 10; continue; }
    # 手动发应用登录按钮的同一个请求（OAuth 自动跳转是客户端 JS，curl 触发不了）。
    # 失败即停：登录链走不通就如实报错，不做任何绕网关的变体（POST 503 是底座缺陷，等底座修）。
    hdrs="$(mktemp)"
    resp="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -X POST \
      -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" \
      --data '{"provider":"custom","callbackURL":"/","errorCallbackURL":"/signin"}' \
      -D "$hdrs" -w $'\nKKMETA:%{http_code} LOC:%{redirect_url}' \
      "$SMOKE_WEB_URL/api/auth/sign-in/social" 2>&1)" || resp=""
    body="${resp%$'\nKKMETA'*}" meta="${resp##*$'\nKKMETA'}"
    werr="$(grep -i '^x-wonton-error:' "$hdrs" 2>/dev/null | tr -d '\r')" || werr=""
    rm -f "$hdrs"
    echo "诊断：social POST 状态 $(echo "$meta" | cut -d' ' -f1)，x-wonton-error=${werr:-无（非网关错误页，可能是应用自己回的）}" >&2
    oauth_url="$(jq -re '.url // empty' <<<"$body" 2>/dev/null)" || oauth_url=""
    if [[ -z "$oauth_url" && "$meta" == 302* ]]; then
      oauth_url="${meta#*LOC:}"
    fi
    if [[ -z "$oauth_url" ]]; then
      echo "social 端点没返回 provider 地址（HTTP $(echo "$meta" | cut -d' ' -f1)），正文：$(head -c 120 <<<"$body")" >&2
      kk_app_log_tail
      (( try < 3 )) && sleep 10
      continue
    fi
    echo "拿到 provider 地址，走 Hydra" >&2
    curl -sS --noproxy '*' -o /dev/null -L --max-redirs 30 -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$oauth_url" || true
    if grep -q better-auth "$SMOKE_JAR" &&
      curl -fsS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" "$SMOKE_WEB_URL/api/v1/users/me"; then
      return 0
    fi
    echo "走了 provider 但应用会话没建起来（better-auth cookie $(grep -c better-auth "$SMOKE_JAR" 2>/dev/null || echo 0) 条，落点 ${page:-未知}）" >&2
    (( try < 3 )) && sleep 10
  done
  echo "OIDC 登录链没建立应用会话" >&2
  kk_app_log_tail
  return 1
}


kk_state_write() { # 覆盖写标记文件；套件的 dev.sh probes 里 SMOKE_STATE 是状态目录（不跑数据钩子），跳过。
  # 值用 %q 转义：文本里有空格/中文，data_check 要用 source 读回来
  [[ -d ${SMOKE_STATE:-} ]] && return 0
  printf 'KK_BOOKMARK_ID=%q\nKK_BOOKMARK_TEXT=%q\n' "$1" "$2" >"$SMOKE_STATE" ||
    { echo "写不进标记文件 \$SMOKE_STATE"; return 1; }
}

identity_check() { # 应用认出的是主人本人：/api/v1/users/me（OAuth 会话）的名字是主人，且是 OIDC 建的号（非本地密码账号）
  kk_init || return 1
  kk_login || { echo "登录链没建立应用会话"; return 1; }
  local me
  me="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me")" ||
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
  kk_login || { echo "登录链没建立应用会话"; return 1; }
  local text id resp
  text="云吞 e2e 数据探针 $(date +%Y%m%d%H%M%S)"
  resp="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" -X POST \
    -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" \
    --data "$(jq -cn --arg t "$text" '{type:"text",text:$t}')" \
    "${SMOKE_WEB_URL:-}/api/v1/bookmarks")" || { echo "建书签失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$resp")"
  [[ -n "$id" ]] || { echo "建书签响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
  kk_state_write "$id" "$text"
}

data_check() { # 断言 data_write 写的书签还在、内容一字不差
  kk_init || return 1
  [[ -f ${SMOKE_STATE:-} && -s "$SMOKE_STATE" ]] || { echo "标记文件里没有数据：先跑 data_write"; return 1; }
  # shellcheck source=/dev/null
  . "$SMOKE_STATE"
  [[ -n "${KK_BOOKMARK_ID:-}" && -n "${KK_BOOKMARK_TEXT:-}" ]] ||
    { echo "标记文件不完整：$SMOKE_STATE"; return 1; }
  local resp text
  resp="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/bookmarks/$KK_BOOKMARK_ID")" ||
    { echo "读书签 $KK_BOOKMARK_ID 失败"; return 1; }
  text="$(jq -r '.content.text // empty' <<<"$resp")"
  [[ "$text" == "$KK_BOOKMARK_TEXT" ]] ||
    { echo "书签内容对不上：期望「$KK_BOOKMARK_TEXT」，拿到「$text」"; return 1; }
}
