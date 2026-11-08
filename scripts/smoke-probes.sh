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

kk_health_pick() { # <svc>：兼容两种容器命名（compose 项目式 wonton-plugin-<名>-<svc>-1 / 规范式 wonton-<实例>--<名>--<svc>）
  docker ps --format '{{.Names}}' 2>/dev/null | grep -i "karakeep" |
    grep -E "(--|[-_.])${1}([-_][0-9]+)?$" | head -1
}

kk_health_loop() { # 采样循环（kk_health_sampler 用 setsid 脱离后跑）：每 10s 记一行紧凑健康状态。
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
      n="$(kk_health_pick "$c")"
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

kk_health_sampler() { # 起采样器（幂等）；输出进 /tmp/kk-health-sampler.log，由 kk_health_dump 同步带进冒烟日志
  local pf=/tmp/kk-health-sampler.pid
  [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null && return 0
  export -f kk_health_loop
  export -f kk_health_pick
  setsid bash -c kk_health_loop </dev/null >/dev/null 2>&1 &
  echo "HEALTH 采样器已启动（输出见 /tmp/kk-health-sampler.log，钩子会带回）" >&2
}

kk_health_dump() { # 全量落盘（钩子内同步执行，肯定能进冒烟日志）：采样行 + 每容器 StartedAt + 完整 Health json
  local n
  [[ -f /tmp/kk-health-sampler.log ]] && { echo "===== HEALTH 采样记录 =====" >&2; cat /tmp/kk-health-sampler.log >&2; }
  echo "===== HEALTH-DUMP =====" >&2
  for c in web chrome meilisearch; do
    n="$(kk_health_pick "$c")"
    [[ -n "$n" ]] || { echo "（找不到 $c 容器）" >&2; continue; }
    # 不能写 "2>/dev/null >&2"：stderr 先指到 /dev/null，stdout 再复制过去就进了 /dev/null（实测吞输出）
    echo "HEALTH-DUMP $n StartedAt=$(docker inspect -f '{{.State.StartedAt}}' "$n" 2>/dev/null)" >&2
    hj="$(docker inspect "$n" --format '{{json .State.Health}}' 2>/dev/null)" && echo "$hj" >&2
  done
}

kk_app_log_tail() { # 诊断用（负责人要求）：应用容器日志最后 50 行 + 三个容器的健康状态；503 复现时这些和 x-wonton-error 一起写 .stop
  local n
  echo "===== karakeep 三个容器健康状态（docker inspect）=====" >&2
  for c in web chrome meilisearch; do
    n="$(kk_health_pick "$c")"
    [[ -n "$n" ]] || { echo "（找不到 $c 容器）" >&2; continue; }
    echo "$n: $(docker inspect --format '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} 连败={{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' "$n" 2>/dev/null || echo "inspect 拿不到")" >&2
  done
  n="$(kk_health_pick web)"
  if [[ -z "$n" ]]; then
    echo "诊断：karakeep 应用容器日志拿不到（docker 不在本机或容器不在跑）" >&2
    return 0
  fi
  echo "===== karakeep 容器（$n）最后 50 行 =====" >&2
  docker logs --tail 50 "$n" 2>&1 | tail -50 >&2
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
  kk_health_sampler
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
  echo "当前用户：$(jq -r .name <<<"$me")" >&2
  kk_health_dump
}

data_write() { # 写一条真实书签（文字书签，内容带时间戳），id 和内容随标记文件覆盖写
  kk_init || return 1
  kk_health_sampler
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
  kk_health_sampler
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
  # 账号邮箱在重装后仍是内部邮箱（init 每次启动都对账一次，值不变）
  me="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me")" ||
    { echo "重装后 users/me 请求失败"; return 1; }
  email="$(jq -r '.email // empty' <<<"$me")"
  [[ "$email" == "$SMOKE_OWNER@wonton.internal" ]] ||
    { echo "重装后账号邮箱不是内部邮箱：$email"; return 1; }
  # init 每次启动都对账一次；重装后日志要么「已从…改成」要么「已是内部邮箱」，值必须是内部地址
  local initc ilog
  initc="$(kk_init_container)"
  ilog="$(docker logs "$initc" 2>&1 | tail -1)"
  grep -qE "已从 .+ 改成|已是内部邮箱" <<<"$ilog" ||
    { echo "init 日志没有对账结论：$ilog"; return 1; }
  echo "重装后数据核对通过：书签 $KK_BOOKMARK_ID，账号邮箱仍是 $email（init：$ilog）" >&2
  kk_health_dump
}

# ---------- 邮件（notify，规范 0.11）----------
kk_core() { # 核心容器：信箱 API 的密码在它挂的数据目录里，Mailpit 的别名也在它的网络上
  docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE}--core" | head -1
}

kk_init_container() { # 一次性改邮箱的容器（重装会重建，名字不变）
  docker ps -a --format '{{.Names}}' | grep -E "init-owner-email" | grep "$SMOKE_INSTANCE" | head -1
}

kk_data_dir() { # 核心数据目录（Mailpit 的库、投递记录都在它下面）
  if declare -F read_env >/dev/null; then read_env WONTON_DATA_DIR; else probes_setting WONTON_DATA_DIR; fi
}

kk_mailpit() { # <path>：调 Mailpit API（basic core:<api-password>）。主路照核心自己的冒烟：在核心网络里
  # 打 mailpit.wonton.internal:8025（curl 镜像，remote-dev/e2e 起栈都预推）；兜底 web 容器的 wget。
  local core webc pw dd out
  core="$(kk_core)" || { echo "找不到核心容器 wonton-$SMOKE_INSTANCE--core"; return 1; }
  dd="$(kk_data_dir)"
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
  webc="$(kk_health_pick web)"
  [[ -n "$webc" ]] || return 1
  docker exec "$webc" wget -qO- \
    --header "Authorization: Basic $(printf 'core:%s' "$pw" | base64 | tr -d '\n')" \
    "http://smtp.wonton.internal:8025$1" 2>&1
}

kk_mailpit_wait() { # <jq 过滤> [次数=40]：轮询 Mailpit 信箱直到过滤命中；过滤里的值先经 jq 转成字面量
  local filt="$1" n="${2:-40}" i out
  for ((i = 0; i < n; i++)); do
    out="$(kk_mailpit "/api/v1/messages?limit=100")" || { sleep 2; continue; }
    jq -e "$filt" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

kk_invite() { # <email>：管理员建用户邀请（上游 TRPC invites.create）
  curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Content-Type: application/json' -H "Origin: $SMOKE_WEB_URL" \
    --data "{\"0\":{\"json\":{\"email\":\"$1\"}}}" "${SMOKE_WEB_URL:-}/api/trpc/invites.create?batch=1"
}

kk_wait_web_healthy() { # 重装后等 web 回到 healthy（最久 150 秒）
  local i n
  for ((i = 0; i < 30; i++)); do
    n="$(kk_health_pick web)"
    [[ -n "$n" ]] && [[ "$(docker inspect -f '{{.State.Health.Status}}' "$n" 2>/dev/null)" == healthy ]] && return 0
    sleep 5
  done
  echo "web 重装后 150 秒没到 healthy" >&2
  return 1
}

extra_check() { # 内部邮箱端到端：变量注入、账号邮箱、真实邀请信进信箱并被核心投走、外部地址拒收、改邮箱初始化
  kk_init || return 1
  kk_health_sampler
  kk_login || { echo "登录链没建立应用会话"; return 1; }
  local webc me email from resp initc ilog
  webc="$(kk_health_pick web)"
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

  # 2) 主人账号的邮箱是内部邮箱（OIDC 声明 + 初始化对账后的结果）
  me="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me")" ||
    { echo "users/me 请求失败"; return 1; }
  email="$(jq -r '.email // empty' <<<"$me")"
  [[ "$email" == "$SMOKE_OWNER@wonton.internal" ]] ||
    { echo "账号邮箱不是内部邮箱：$email（期望 $SMOKE_OWNER@wonton.internal）"; return 1; }
  echo "主人账号邮箱 = $email"

  # 3) 一次性初始化在这次安装里跑过，日志有对账结论（装完还没登录过=还没建号；已登录=已是/已改）
  initc="$(kk_init_container)"
  [[ -n "$initc" ]] || { echo "找不到 init-owner-email 容器"; return 1; }
  ilog="$(docker logs "$initc" 2>&1 | tail -2)"
  grep -qE "已是内部邮箱|已从 .+ 改成|还没登录过|还没建库" <<<"$ilog" ||
    { echo "init 日志没有对账结论：$ilog"; return 1; }
  echo "init 容器（$initc）：$(tail -1 <<<"$ilog")"

  # 4) 模拟 0.11 之前装的实例：把主人账号的邮箱改成旧值（核心只给 status=joined 的家人和主人投信，
  #    刚邀请还没加入的家人不投，所以收件人用主人自己——库里已是旧值，invites 不会按“已有用户”拒绝）
  local old
  old="owner-old-$(date +%s)@example.com"
  docker exec -e KK_OLD="$old" -e KK_CURR="$email" "$webc" node -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync("/data/db.db");
    for (let i = 0; ; i++) {
      try { db.prepare("UPDATE user SET email = ? WHERE email = ?").run(process.env.KK_OLD, process.env.KK_CURR); break; }
      catch (e) { if (i >= 4) { db.close(); throw e; } }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
    }
    db.close();' ||
    { echo "模拟旧邮箱失败"; return 1; }
  email="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me" | jq -r '.email // empty')"
  [[ "$email" == "$old" ]] || { echo "旧邮箱没写进去（现在 $email）"; return 1; }
  echo "已模拟升级前状态：主人账号邮箱 = $old"

  # 5) 真实邀请信：发给主人的内部地址；核心投进主人的 Wonton 私聊后在投递记录里落 delivered
  #    （记录文件按消息 id 哈希命名，投完才写，轮询它不怕信被秒删）
  local outsider recdir before rec found json plugin_id i
  plugin_id="${from%@plugins.wonton.internal}"
  recdir="$(kk_data_dir)/core/mailpit/delivery"
  corec="$(kk_core)"
  before="$(docker exec "$corec" sh -c "ls '$recdir' 2>/dev/null" | sort)"
  resp="$(kk_invite "$SMOKE_OWNER@wonton.internal")"
  jq -e '.[0].result.data.json.email // .result.data.json.email' <<<"$resp" >/dev/null 2>&1 ||
    { echo "邀请的 TRPC 没成功：$(head -c 200 <<<"$resp")"; return 1; }
  found=""
  for ((i = 0; i < 40; i++)); do
    [[ -n "$found" ]] && break
    sleep 3
    while IFS= read -r rec; do
      [[ -n "$rec" ]] && grep -qxF "$rec" <<<"$before" && continue
      json="$(docker exec "$corec" cat "$recdir/$rec" 2>/dev/null)" || continue
      if jq -e --arg p "$plugin_id" --arg u "$SMOKE_OWNER" \
        '.decision.accepted.plugin_id == $p and (.delivered | index($u))' <<<"$json" >/dev/null 2>&1; then
        found="$rec"
        break
      fi
    done < <(docker exec "$corec" sh -c "ls '$recdir' 2>/dev/null" | sort)
  done
  [[ -n "$found" ]] ||
    { echo "投递记录里没有本插件投给 $SMOKE_OWNER@wonton.internal 的信；核心日志：$(docker logs "$corec" 2>&1 | grep -iE '信件|Mailpit' | tail -2 | tr '\n' ' ')"; return 1; }
  echo "核心已把邀请信投进主人的 Wonton 私聊（投递记录 $found，delivered 含主人，From=$from）"

  # 6) 外部地址：上游应用把发信失败吞掉（邀请照样建成，见 PR 说明），但信永远进不了信箱（SMTP 550 拒收）
  outsider="nobody-$(date +%s)@example.com"
  resp="$(kk_invite "$outsider")"
  jq -e '.[0].result.data.json.email // .result.data.json.email' <<<"$resp" >/dev/null 2>&1 ||
    { echo "邀请外部地址的 TRPC 没成功：$(head -c 200 <<<"$resp")"; return 1; }
  sleep 15
  kk_mailpit_wait \
    "$(jq -n --arg to "$outsider" \
      '(.messages | map(select(.To[].Address == $to)) | length) == 0')" 1 ||
    { echo "外部地址 $outsider 的信进了 Mailpit（550 拒收没生效）"; return 1; }
  echo "外部地址 $outsider 被 SMTP 拒收：Mailpit 里没有这封信"

  # 7) 改邮箱初始化：重装触发 init 把旧邮箱对回内部地址
  if declare -F probes_dev_t >/dev/null; then
    probes_dev_t 420 reinstall --yes || { echo "reinstall 失败"; return 1; }
  else
    (cd "${dir:?}" && nice -n 19 timeout 420 scripts/dev.sh reinstall --yes) || { echo "reinstall 失败"; return 1; }
  fi
  kk_wait_web_healthy || return 1
  kk_login || { echo "重装后登录链没建立"; return 1; }
  email="$(curl -fsS --noproxy '*' -b "$SMOKE_JAR" "${SMOKE_WEB_URL:-}/api/v1/users/me" | jq -r '.email // empty')"
  [[ "$email" == "$SMOKE_OWNER@wonton.internal" ]] ||
    { echo "重装后邮箱没对回内部地址：$email"; return 1; }
  initc="$(kk_init_container)"
  ilog="$(docker logs "$initc" 2>&1 | tail -1)"
  grep -qF "已从 $old 改成" <<<"$ilog" ||
    { echo "init 日志没有这次的改邮箱记录：$ilog"; return 1; }
  echo "初始化把 $old 对回 $email（重装触发，init 日志：$ilog）"
}
