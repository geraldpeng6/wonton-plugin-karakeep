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
kmail_init() { # 契约变量的兜底：e2e 的 identity_check 是直调，不走 run_hook 的 SMOKE_* 导出（底座缺口，见 PR），
  # 过渡期回退到同值的 E2E_*；套件在直调前补导出后这里自动只用 SMOKE_*，兜底可删。
  SMOKE_JAR="${SMOKE_JAR:-${E2E_JAR:-}}"
  SMOKE_WEB_URL="${SMOKE_WEB_URL:-${E2E_WEB_URL:-}}"
  SMOKE_OWNER="${SMOKE_OWNER:-${E2E_OWNER:-}}"
  # 主人邮箱：kit 的 probes_env 导出过；e2e 直调没有——按 #87 约定由 SMOKE_OWNER 推导（<用户名>@wonton.internal）。
  SMOKE_OWNER_EMAIL="${SMOKE_OWNER_EMAIL:-${SMOKE_OWNER:+"${SMOKE_OWNER}@wonton.internal"}}"
  SMOKE_OWNER_EMAIL="${SMOKE_OWNER_EMAIL:-$(probes_setting WONTON_OWNER_EMAIL 2>/dev/null)}"
  SMOKE_BASE="${SMOKE_BASE:-${E2E_BASE:-}}"
  SMOKE_TOKEN="${SMOKE_TOKEN:-${E2E_TOKEN:-}}"
  local name
  for name in SMOKE_JAR SMOKE_WEB_URL SMOKE_BASE SMOKE_TOKEN; do
    [[ -n "${!name:-}" ]] || { echo "套件没有给 \$$name（SMOKE_* 与 E2E_* 都为空）"; return 1; }
  done
}

kmail_health_pick() { # <svc>：兼容两种容器命名（compose 项目式 wonton-plugin-<名>-<svc>-1 / 规范式 wonton-<实例>--<名>--<svc>）
  docker ps --format '{{.Names}}' 2>/dev/null | grep -i "karakeep" |
    grep -E "(--|[-_.])${1}([-_][0-9]+)?$" | head -1
}

kmail_health_loop() { # 采样循环（kmail_health_sampler 用 setsid 脱离后跑）：每 10s 记一行紧凑健康状态。
  # 写文件不写 stderr：钩子返回后冒烟不再读它的输出管道，写了也会被 SIGPIPE 杀掉（11-07 实测）。
  # pid 幂等：pid 文件活着就直接退；容器连续 3 次找不到就自退
  local prog n h miss=0 found sf=/tmp/kk-health-sampler.log pf=/tmp/kk-health-sampler.pid
  [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null && exit 0
  echo $$ >"$pf"
  # shellcheck disable=SC2016  # prog 是 jq 程序，不能让 bash 展开
  prog='"\($t) \($n) \(.Status) streak=\(.FailingStreak) \(if (.Log|length)>0 then (.Log[-1] | "last探针: exit=\(.ExitCode) 起=\(.Start[11:23]) 止=\(.End[11:23]) 输出=\((.Output|gsub("\n";" ")|.[0:80]))") else "last探针: 无" end)"'
  echo "HEALTH 采样开始 $(date +%H:%M:%S) pid=$$" >"$sf"
  while :; do
    found=0
    for c in web chrome meilisearch; do
      n="$(kmail_health_pick "$c")"
      [[ -n "$n" ]] || continue
      found=1
      h="$(docker inspect "$n" --format '{{json .State.Health}}' 2>/dev/null)" || h=""
      [[ -n "$h" ]] || continue
      jq -r --arg n "$n" --arg t "$(date +%H:%M:%S)" "$prog" <<<"$h" >>"$sf"
    done
    if (( found == 0 )); then
      (( ++miss >= 3 )) && { echo "HEALTH 采样结束（容器已清）$(date +%H:%M:%S)" >>"$sf"; return 0; }
    else
      miss=0
    fi
    sleep 10
  done
}

kmail_health_sampler() { # 起采样器（幂等）；输出进 /tmp/kk-health-sampler.log，由 kmail_health_dump 同步带进冒烟日志
  local pf=/tmp/kk-health-sampler.pid
  [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null && return 0
  export -f kmail_health_loop
  export -f kmail_health_pick
  setsid bash -c kmail_health_loop </dev/null >/dev/null 2>&1 &
  echo "HEALTH 采样器已启动（输出见 /tmp/kk-health-sampler.log，钩子会带回）" >&2
}

kmail_health_dump() { # 全量落盘（钩子内同步执行，肯定能进冒烟日志）：采样行 + 每容器 StartedAt + 完整 Health json
  local n
  [[ -f /tmp/kk-health-sampler.log ]] && { echo "===== HEALTH 采样记录 =====" >&2; cat /tmp/kk-health-sampler.log >&2; }
  echo "===== HEALTH-DUMP =====" >&2
  for c in web chrome meilisearch; do
    n="$(kmail_health_pick "$c")"
    [[ -n "$n" ]] || { echo "（找不到 $c 容器）" >&2; continue; }
    # 不能写 "2>/dev/null >&2"：stderr 先指到 /dev/null，stdout 再复制过去就进了 /dev/null（实测吞输出）
    echo "HEALTH-DUMP $n StartedAt=$(docker inspect -f '{{.State.StartedAt}}' "$n" 2>/dev/null)" >&2
    hj="$(docker inspect "$n" --format '{{json .State.Health}}' 2>/dev/null)" && echo "$hj" >&2
  done
}

kmail_app_log_tail() { # 诊断用（负责人要求）：应用容器日志最后 50 行 + 三个容器的健康状态；503 复现时这些和 x-wonton-error 一起写 .stop
  local n
  echo "===== karakeep 三个容器健康状态（docker inspect）=====" >&2
  for c in web chrome meilisearch; do
    n="$(kmail_health_pick "$c")"
    [[ -n "$n" ]] || { echo "（找不到 $c 容器）" >&2; continue; }
    echo "$n: $(docker inspect --format '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} 连败={{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' "$n" 2>/dev/null || echo "inspect 拿不到")" >&2
  done
  n="$(kmail_health_pick web)"
  if [[ -z "$n" ]]; then
    echo "诊断：karakeep 应用容器日志拿不到（docker 不在本机或容器不在跑）" >&2
    return 0
  fi
  echo "===== karakeep 容器（$n）最后 50 行 =====" >&2
  docker logs --tail 50 "$n" 2>&1 | tail -50 >&2
  echo "===== 容器日志完 =====" >&2
}

kmail_login() { # 分两步把两个会话都建好（2026-11-07 e2e 逐轮实测的结论）：
  # 1) 核心会话：token POST 返回 303 但不发 cookie（jar 为空，同 jar GET 插件域 401），
  #    必须走 dev.sh 的表单登录回退——用 dweb，并把它写会话的 jar 指到 SMOKE_JAR
  #    （WONTON_DEV_JAR 是 dev.sh 的公开入口，session_jar 读它）。
  # 2) 应用会话：Karakeep 的自动跳转是客户端 JS（signIn.social），curl 触发不了，
  #    手动 POST 应用自己的 /api/auth/sign-in/social 拿 provider 地址，带 jar 走 Hydra → 回调建会话。
  # 成功判据：jar 里有 better-auth 会话 cookie 且 /api/v1/users/me 返回 200。
  kmail_init || return 1
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
      kmail_app_log_tail
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
  kmail_app_log_tail
  return 1
}


kmail_state_write() { # 覆盖写标记文件；套件的 dev.sh probes 里 SMOKE_STATE 是状态目录（不跑数据钩子），跳过。
  # 值用 %q 转义：文本里有空格/中文，data_check 要用 source 读回来
  [[ -d ${SMOKE_STATE:-} ]] && return 0
  printf 'KK_BOOKMARK_ID=%q\nKK_BOOKMARK_TEXT=%q\n' "$1" "$2" >"$SMOKE_STATE" ||
    { echo "写不进标记文件 \$SMOKE_STATE"; return 1; }
}

identity_check() { # 应用认出的是主人本人：/api/v1/users/me（OAuth 会话）的名字是主人，且是 OIDC 建的号（非本地密码账号）
  kmail_init || return 1
  kmail_health_sampler
  kmail_login || { echo "登录链没建立应用会话"; return 1; }
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
  echo "当前用户：$(jq -r .name <<<"$me")" >&2
  kmail_health_dump
}

data_write() { # 写一条真实书签（文字书签，内容带时间戳），id 和内容随标记文件覆盖写
  kmail_init || return 1
  kmail_health_sampler
  kmail_login || { echo "登录链没建立应用会话"; return 1; }
  local text id resp
  text="云吞 e2e 数据探针 $(date +%Y%m%d%H%M%S)"
  resp="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" -X POST \
    -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" \
    --data "$(jq -cn --arg t "$text" '{type:"text",text:$t}')" \
    "${SMOKE_WEB_URL:-}/api/v1/bookmarks")" || { echo "建书签失败"; return 1; }
  id="$(jq -r '.id // empty' <<<"$resp")"
  [[ -n "$id" ]] || { echo "建书签响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
  kmail_state_write "$id" "$text"
}

data_check() { # 断言 data_write 写的书签还在、内容一字不差
  kmail_init || return 1
  kmail_health_sampler
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
  # 账号邮箱在重装后仍是对账过的注入值（init 每次启动都对账一次，值不变）。
  # 比较对象用套件导出的 WONTON_OWNER_EMAIL 本身：e2e/kit 环境的值形制可能不同，别硬编码 @wonton.internal。
  me="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me")" ||
    { echo "重装后 users/me 请求失败"; return 1; }
  email="$(jq -r '.email // empty' <<<"$me")"
  [[ "$email" == "${SMOKE_OWNER:-owner}@wonton.internal" ]] ||
    { echo "重装后账号邮箱不是注入的主人邮箱：$email（期望 $SMOKE_OWNER_EMAIL）"; return 1; }
  # init 每次启动都对账一次；重装后日志要么「已从…改成」要么「已是内部邮箱」，值必须是内部地址
  local initc ilog
  initc="$(kmail_init_container)"
  ilog="$(docker logs "$initc" 2>&1 | tail -1)"
  grep -qE "已从 .+ 改成|已是内部邮箱" <<<"$ilog" ||
    { echo "init 日志没有对账结论：$ilog"; return 1; }
  echo "重装后数据核对通过：书签 $KK_BOOKMARK_ID，账号邮箱仍是 $email（init：$ilog）" >&2
  kmail_health_dump
}

# ---------- 邮件（notify，规范 0.11）----------
kmail_core() { # 核心容器：信箱 API 的密码在它挂的数据目录里，Mailpit 的别名也在它的网络上
  docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE}--core" | head -1
}

kmail_init_container() { # 一次性改邮箱的容器（重装会重建，名字不变）
  docker ps -a --format '{{.Names}}' | grep -E "init-owner-email" | grep "$SMOKE_INSTANCE" | head -1
}

kmail_data_dir() { # 核心数据目录（Mailpit 的库、投递记录都在它下面）
  if declare -F read_env >/dev/null; then read_env WONTON_DATA_DIR; else probes_setting WONTON_DATA_DIR; fi
}

kmail_mailpit() { # <path>：调 Mailpit API（basic core:<api-password>）。主路照核心自己的冒烟：在核心网络里
  # 打 mailpit.wonton.internal:8025（curl 镜像，remote-dev/e2e 起栈都预推）；兜底 web 容器的 wget。
  local core webc pw dd out
  core="$(kmail_core)" || { echo "找不到核心容器 wonton-$SMOKE_INSTANCE--core"; return 1; }
  dd="$(kmail_data_dir)"
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || pw="$(docker exec "$core" sh -c 'cat "$(find / -maxdepth 6 -path "*/core/mailpit/api-password" 2>/dev/null | head -1)"' 2>/dev/null)"
  [[ -n "${pw:-}" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if jq -e '.messages' <<<"$out" >/dev/null 2>&1 || [[ "$out" == "{"* ]]; then
    printf '%s' "$out"
    return 0
  fi
  echo "Mailpit 主路（核心网络 curl）没拿到 JSON：$(head -c 200 <<<"$out")" >&2
  webc="$(kmail_health_pick web)"
  [[ -n "$webc" ]] || return 1
  docker exec "$webc" wget -qO- \
    --header "Authorization: Basic $(printf 'core:%s' "$pw" | base64 | tr -d '\n')" \
    "http://smtp.wonton.internal:8025$1" 2>&1
}

kmail_mailpit_wait() { # <jq 过滤> [次数=40]：轮询 Mailpit 信箱直到过滤命中；过滤里的值先经 jq 转成字面量
  local filt="$1" n="${2:-40}" i out
  for ((i = 0; i < n; i++)); do
    out="$(kmail_mailpit "/api/v1/messages?limit=100")" || { sleep 2; continue; }
    jq -e "$filt" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

kmail_invite() { # <email>：管理员建用户邀请（上游 TRPC invites.create）
  curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" \
    --data "{\"0\":{\"json\":{\"email\":\"$1\"}}}" "${SMOKE_WEB_URL:-}/api/trpc/invites.create?batch=1"
}

kmail_wait_web_healthy() { # 重装后等 web 回到 healthy（最久 150 秒）
  local i n
  for ((i = 0; i < 30; i++)); do
    n="$(kmail_health_pick web)"
    [[ -n "$n" ]] && [[ "$(docker inspect -f '{{.State.Health.Status}}' "$n" 2>/dev/null)" == healthy ]] && return 0
    sleep 5
  done
  echo "web 重装后 150 秒没到 healthy" >&2
  return 1
}

kmail_matrix_owner_token() { # 以主人身份拿 Matrix 令牌：套件的 owner_access_token（管理令牌 impersonation）
  local tuwunel="http://tuwunel.wonton.internal:8008"
  owner_access_token
}

extra_check() { # 邮件端到端：SMTP 变量注入、找回密码（公开端点免应用会话）、投递进主人私聊
  kmail_init || return 1
  kmail_health_sampler
  local webc from resp initc ilog
  webc="$(kmail_health_pick web)"
  [[ -n "$webc" ]] || { echo "找不到 web 容器"; return 1; }

  # 1) 三个 SMTP 变量进了 web 容器（compose 把 WONTON_SMTP_* 映射成上游的 SMTP_*）
  local smtp_host smtp_port
  smtp_host="$(docker exec "$webc" printenv SMTP_HOST)" || { echo "web 容器没有 SMTP_HOST"; return 1; }
  smtp_port="$(docker exec "$webc" printenv SMTP_PORT)" || { echo "web 容器没有 SMTP_PORT"; return 1; }
  from="$(docker exec "$webc" printenv SMTP_FROM)" || { echo "web 容器没有 SMTP_FROM"; return 1; }
  [[ "$smtp_host" == "smtp.wonton.internal" && "$smtp_port" == "25" &&
    "$from" == *@plugins.wonton.internal ]] ||
    { echo "SMTP 变量不对：host=$smtp_host port=$smtp_port from=$from"; return 1; }
  echo "SMTP 变量已注入：$smtp_host:$smtp_port from=$from"

  # 3) 一次性初始化在这次安装里跑过，日志有对账结论（装完还没登录过=还没建号；已登录=已是/已改）
  initc="$(kmail_init_container)"
  [[ -n "$initc" ]] || { echo "找不到 init-owner-email 容器"; return 1; }
  ilog="$(docker logs "$initc" 2>&1 | tail -2)"
  grep -qE "已是内部邮箱|已从 .+ 改成|还没登录过|还没建库" <<<"$ilog" ||
    { echo "init 日志没有对账结论：$ilog"; return 1; }
  echo "init 容器（$initc）：$(tail -1 <<<"$ilog")"

  # 4) 触发发信：部署是 OIDC-only（"Password authentication is currently disabled"），
  #    找回密码路径天然不存在；按负责人指示用插件注入的同一组 SMTP 变量在容器里发一封信
  #    ——与应用 email.ts 的 buildTransporter 同配置（host/port/from，无认证无 TLS），收件人=主人内部邮箱。
  local mtok before_ts found json seen_room corec plugin_id
  plugin_id="${from%@plugins.wonton.internal}"
  mtok="$(kmail_matrix_owner_token)"
  [[ -n "$mtok" ]] || { echo "主人 Matrix 登录失败（读私聊拿投递证据用）"; return 1; }
  before_ts="$(date +%s000)"
  local nm_dir
  nm_dir="$(docker exec "$webc" sh -c 'find /app -maxdepth 7 -type d -name nodemailer 2>/dev/null | head -1')"
  [[ -n "$nm_dir" ]] || { echo "镜像里找不到 nodemailer 包目录"; return 1; }
  docker exec -e NM_DIR="$nm_dir" -e KK_TO="${SMOKE_OWNER:-owner}@wonton.internal" "$webc" node -e '
    const { createTransport } = require(process.env.NM_DIR);
    const t = createTransport({ host: process.env.SMTP_HOST, port: Number(process.env.SMTP_PORT), secure: false });
    t.sendMail({ from: process.env.SMTP_FROM, to: process.env.KK_TO,
      subject: "Karakeep smoke", text: "wonton-smoke-" + Date.now() },
      (e) => { if (e) { console.error(e.message); process.exit(1); } });' ||
    { echo "容器内发信失败"; return 1; }
  echo "测试信已从容器内经注入的 SMTP 发出（收件人 ${SMOKE_OWNER:-owner}@wonton.internal）"

  # 5) 以主人身份读私聊，等 app.wonton.plugin_mail 消息（成功投递在核心日志里静默）
  found=""
  # Mailpit websocket 偶发断连会让核心走「重连后补漏」，投递可能晚于 150 秒，窗口放宽到 300 秒。
  for _ in $(seq 1 100); do
    seen_room="$(matrix_curl -H "Authorization: Bearer $mtok" \
      "http://tuwunel.wonton.internal:8008/_matrix/client/v3/joined_rooms" 2>/dev/null)" || { sleep 3; continue; }
    while IFS= read -r room; do
      [[ -n "$room" ]] || continue
      json="$(matrix_curl -H "Authorization: Bearer $mtok" \
        "http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$(printf '%s' "$room" | sed 's/!/%21/g;s/:/%3A/g')/messages?dir=b&limit=30" 2>/dev/null)" || continue
      if jq -e --arg p "$plugin_id" --argjson t "$before_ts" '.chunk[] |
          select(.type == "m.room.message" and .origin_server_ts >= $t and
          .content["app.wonton.plugin_mail"].plugin_id == $p)' <<<"$json" >/dev/null 2>&1; then
        found="$room"
        break
      fi
    done <<<"$seen_room"
    [[ -n "$found" ]] && break
    sleep 3
  done
  [[ -n "$found" ]] ||
    { echo "主人的 Wonton 私聊里没有本插件的重置信；核心日志：$(docker logs "$(kmail_core)" 2>&1 | grep -iE '信件|Mailpit' | tail -2 | tr '\n' ' ')"; return 1; }
  echo "核心已把重置信投进主人的 Wonton 私聊（房间 $found，From=$from）"
}
