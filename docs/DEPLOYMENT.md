# 部署指南

核对日期：2026-10-13；示例版本：**v0.6.3**。
环境变量和启动行为以 [runtime.exs](../config/runtime.exs)、
[Dockerfile](../Dockerfile) 和 [Release 配置](../mix.exs) 为依据。
本文提供可复制的 Docker Compose 配置，也说明直接使用 Release 归档的方法。

## 1. 选择部署方式

| 服务 | 用途 | 数据与端口 |
| --- | --- | --- |
| `manifold` | Gmail、Microsoft、IMAP、EAS 邮件客户端，Web/API，通讯录和日历 | 主 PostgreSQL、spool、raw、blobs；HTTP 4290，API 4292 |
| `manifold_edge`，可选 | 公网 SMTP 接收，通过签名 HTTPS API 供主程序拉取 | 独立 PostgreSQL、持久 spool；SMTP 25，API 4291 |

只使用现有邮箱服务时，部署主程序即可。需要为自有域名接收公网 SMTP 时，再部署 Edge。
主程序不包含入站 SMTP listener；设置 `MANIFOLD_SMTP_*` 不能在主程序中启用它。
发信通过账户配置的 Gmail API、Microsoft Graph 或 SMTP relay，不直接投递到收件域名 MX。

### HTTP 服务器

Gaoxy 替换已在隔离分支 `codex/gaoxy-http-server` 通过 257 项 Web/API/Edge 测试，
两个本地生产 release 已通过实际启动及 HTTP 请求验证；**尚未合并或部署**。
先前的[大正文 LiveView 消息](https://github.com/gsmlg-dev/gaoxy/issues/9)
和 [Edge 活跃请求关闭](https://github.com/gsmlg-dev/gaoxy/issues/10) 缺陷已由 0.9.0 修复并通过消费者回归。

源码中的 Web/API Endpoint 使用 `Gaoxy.PhoenixAdapter`，Edge API 直接监督
`Gaoxy.HTTP`，依赖 `gaoxy_http` 0.9.0。Phoenix 的 `websock_adapter` 依赖由同名 OTP
应用的 `gaoxy_websock_adapter` 0.9.0 包提供；升级依赖时保留根 `mix.exs` 的 override。
本节描述源码接入，旧版镜像仍以其发布内容为准。
打包移除旧依赖的版本时使用新的 release 输出目录；`mix release --overwrite`
可能保留旧库文件。本次已在全新输出中核验 Bandit/ThousandIsland 不存在。

监听端口和启动开关仍由 `PORT`、`API_PORT`、`MANIFOLD_EDGE_API_PORT` 及现有 Release
配置控制。容器内监听普通 HTTP，Caddy 终止外部 TLS，并转发 `/live` 的 WebSocket
升级和 longpoll 请求。公开 URL 的 HTTPS 配置不会自动启用原生 TLS、HTTP/2 或 HTTP/3。

Web 监听服务的字节预算为 64 MiB，API 为 16 MiB，Edge 默认为 8 MiB，供 Plug 聚合请求体及传输
缓冲使用；它们不改变应用的请求大小上限，也不代表整个 BEAM 的内存上限。普通 JSON
解析上限仍为 8,000,000 字节，Resend webhook 为 1,048,576 字节，Edge 默认签名请求
为 2,097,152 字节。Edge 启动时从 `MANIFOLD_EDGE_MAX_REQUEST_BYTES` 自动计算服务
预算（至少 4 MiB，且为请求上限的四倍）及底层 body ceiling（至少 8 MiB，且比应用
上限多一字节），让应用继续返回原有 JSON 413。

Gaoxy 0.9.0 默认 HTTP 请求/响应总期限为 30 秒，header/read/write 期限为 5 秒，
分块附件下载也受这些期限约束。Web 的现有 Phoenix 配置保留 10,000,000 字节的
WebSocket 帧上限，省略的消息上限在 0.9.0 中跟随帧上限；两者也受服务预算四分之一的约束。
64 MiB Web 预算为原有容量留出余量，已通过 300 KiB 转义正文及 5 MiB ASCII 草稿回归。
WebSocket 空闲期限仍为 60 秒、最大连接寿命 24 小时，普通 Phoenix 心跳和重连机制继续生效。
需要更长 HTTP 下载期限时，在 Endpoint 的 `http`
或 Edge 的 `Gaoxy.HTTP` 子配置中使用公开的 `http_limits`，并同时核对代理超时。
迁移范围和传输验证入口见[维护记录](../.agents/skills/develop/references/http-server-migration.md)。

Web 和 API **没有应用级登录或权限隔离**。所有能访问它们的人都拥有整个实例的访问权。
使用 VPN、受限网络或有访问控制的可信反向代理；仅配置 HTTPS 不会增加用户认证。
下文将后台端口绑定到宿主机 loopback，并给出 VPN 地址白名单的代理示例。

## 2. 主程序：准备主机、目录与密钥

准备 Linux 主机、Docker Engine、Docker Compose v2 或更新版本，以及持久磁盘。
示例使用 PostgreSQL 16，与当前开发和 CI 基线一致；数据库不向公网发布端口。
反向代理在宿主机运行，公开地址示例为 `https://mail.example.com`。

在仓库外创建部署目录，例如 `/srv/manifold`，后续命令均在该目录运行。
Docker 权限和目录创建由主机管理员配置。应用镜像以 UID/GID `1000:1000` 运行：

```sh
set -e
sudo install -d -m 0750 -o "$(id -u)" -g "$(id -g)" /srv/manifold
cd /srv/manifold
sudo install -d -m 0700 -o 1000 -g 1000 \
  data/main data/main/spool data/main/raw data/main/blobs data/main/log
```

首次生成密钥；已有部署保留原文件及原加密密钥，不能覆盖重新生成：

```sh
set -e
umask 077
test ! -e .env && test ! -e main.env || exit 1
printf 'MANIFOLD_VERSION=0.6.3\nPOSTGRES_PASSWORD=%s\n' \
  "$(openssl rand -hex 32)" > .env
{
  printf 'PHX_HOST=mail.example.com\n'
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -hex 64)"
  printf 'MANIFOLD_CONNECTOR_ENCRYPTION_KEY=%s\n' "$(openssl rand -base64 32)"
} > main.env
chmod 600 .env main.env
```

将 `PHX_HOST` 改为真实主机名，不含协议或路径。当前生产 Endpoint 的公开 URL 固定为
HTTPS/443，Web 和 API 使用同一 `PHX_HOST`。示例默认将两者代理到同一域名。
随机十六进制数据库密码可以直接用于下面的连接 URL；其他密码需进行 URL 编码。

| 配置 | 要求 |
| --- | --- |
| `DATABASE_URL` | 主数据库连接；Compose 示例根据 `.env` 构造 |
| `SECRET_KEY_BASE` | 稳定的 Phoenix secret，不使用 Dockerfile 的构建占位值 |
| `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` | **恰好 32 字节密钥的 Base64 编码**；用于 OAuth、邮箱密码、Apple 凭证等加密，升级和恢复时必须保持不变 |
| `RESEND_API_KEY` / `RESEND_WEBHOOK_SECRET` | 按生产凭证管理约定配置遗留 Resend 发送及 Webhook 所需凭证；新账户发送不选择 Resend，未启用遗留路径时明确记录未配置 |

Google/Microsoft OAuth 客户端凭证只在 **Settings → OAuth** 保存，不能写进环境文件或 CI 变量。
`.env`、`main.env` 和数据库备份包含敏感数据，放在仓库外，不提交到 GitHub。
不要将完整的 `docker compose config`、容器环境或数据库 URL 贴入日志与问题报告。

## 3. 主程序：Docker Compose

保存为 `compose.yaml`。固定版本标签便于升级和回退；需要不可变引用时，将 `image` 改为
对应 Release 中核验过的 `ghcr.io/gsmlg-dev/manifold@sha256:...`。

```yaml
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: manifold
      POSTGRES_DB: manifold
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U manifold -d manifold"]
      interval: 5s
      timeout: 5s
      retries: 12
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  main:
    image: ghcr.io/gsmlg-dev/manifold:${MANIFOLD_VERSION:-0.6.3}
    restart: unless-stopped
    env_file: main.env
    environment:
      DATABASE_URL: postgres://manifold:${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}@postgres:5432/manifold
      PORT: "4290"
      API_PORT: "4292"
      MANIFOLD_SPOOL_DIR: /var/lib/manifold/spool
      MANIFOLD_RAW_STORE_BACKEND: local
      MANIFOLD_RAW_STORE_DIR: /var/lib/manifold/raw
      MANIFOLD_BLOB_STORE_DIR: /var/lib/manifold/blobs
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:4290:4290"
      - "127.0.0.1:4292:4292"
    volumes:
      - ./data/main:/var/lib/manifold
      - ./data/main/log:/app/log
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  postgres_data:
```

应用需要同时保留 spool、raw 和 blobs。当前只实现本地文件存储，不能通过一个环境变量切换到 S3。
Connector 活动日志默认写入 `/app/log/connectors`，保留期配置为 14 天；没有对应的日志目录环境变量。
上面的日志挂载保存活动记录；Docker 日志轮转只管理 stdout/stderr，不轮转活动日志文件。
镜像中的入口不会自动执行数据库迁移。

## 4. 主程序：迁移、启动和检查

首次安装先启动数据库，再运行一次性迁移，最后启动应用：

```sh
set -e
docker compose config --quiet
docker compose pull
docker compose up -d --wait postgres
docker compose exec -T postgres pg_isready -U manifold -d manifold
docker compose run --rm --no-deps main /app/bin/manifold eval '
Application.put_env(:manifold_data, :oban_enabled, false)
{:ok, _} = Application.ensure_all_started(:manifold_data)
path = Application.app_dir(:manifold_data, "priv/repo/migrations")
{:ok, migrated, _} = Ecto.Migrator.with_repo(Manifold.Repo, fn repo ->
  Ecto.Migrator.run(repo, path, :up, all: true)
end)
IO.inspect(migrated, label: "migrated")
'
docker compose up -d main
docker compose ps
docker compose logs --tail=100 main
```

`pg_isready` 未就绪时，等数据库健康后再迁移。迁移命令通过保留的 `:oban_enabled` 运维开关禁用一次性进程中的 Styx，避免在迁移前执行任务。
主程序没有 `Manifold.Release.migrate/0`；Edge 的迁移入口也不能用于主数据库。

后台 HTTP 存活检查：

```sh
set -e
curl --fail --silent --show-error http://127.0.0.1:4290/contacts > /dev/null
curl --fail --silent --show-error http://127.0.0.1:4292/api/v1/health
docker compose exec -T postgres psql -U manifold -d manifold \
  -c 'SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 5;'
```

`/api/v1/health` 返回静态服务状态，不证明数据库、Styx 或 provider 正常。
完整验收还应检查迁移结果、`/jobs` 中任务执行、账户同步状态及实际收件；发送时区分
provider 接受与最终投递，不自动重发 `submission_uncertain` 的邮件。

## 5. 主程序：HTTPS 与访问边界

下面是宿主机 Caddy 的配置示例。将域名和 VPN 子网 `10.20.0.0/16` 替换为实际值。
该白名单允许可信网络内的用户访问整个实例；如需逐用户认证，在可信代理层另外配置。
若前面还有代理，应重新设计真实客户端地址的信任边界，不能直接放行整个上游代理地址。
自动公开证书要求 DNS 和 ACME 验证通路正确；纯内网安装应使用客户端信任的内部证书。

```caddy
mail.example.com {
	@outside not remote_ip 127.0.0.1 ::1 10.20.0.0/16
	respond @outside "Forbidden" 403

	@api path /api/* /.well-known/manifold
	handle @api {
		reverse_proxy 127.0.0.1:4292
	}
	handle {
		reverse_proxy 127.0.0.1:4290
	}
}
```

Caddy `reverse_proxy` 支持 LiveView WebSocket 升级。保留 `/live` 路径、原始 Host 和
WebSocket 请求头，不重写成其他路径；公开 Host 应匹配 `PHX_HOST`。
宿主机上的代理使用上述 loopback 地址；若代理也在容器里，应通过私有容器网络访问服务，
容器中的 `127.0.0.1` 不能访问宿主机的后台端口。

在允许的网络中打开 `https://mail.example.com`，确认 LiveView 已连接、资源正常加载，
并检查 API 与 `/.well-known/manifold`。先在 Settings → Accounts 添加账户及收发方式。
OAuth 配置和授权见 [OAUTH_SETUP.md](OAUTH_SETUP.md)，iCloud 配置见 [ICLOUD.md](ICLOUD.md)。
Google 回调必须与 Settings 中保存、Google Cloud 注册的 URL 完全一致；Microsoft
默认 device-code 登录不需要回调。Provider 授权不是 Manifold 自身的登录认证。

## 6. 可选 Edge：数据库、配置与启动

在 Edge 主机的独立目录（例如 `/srv/manifold-edge`）部署，使用独立数据库和 Compose 项目。
准备持久 spool、可到达的公网 TCP 25、SMTP 主机名和域名 MX/A/AAAA 记录。
下面使用宿主机 25 → 容器 2525，以便保持镜像的非 root 用户。

```sh
set -e
sudo install -d -m 0750 -o "$(id -u)" -g "$(id -g)" /srv/manifold-edge
cd /srv/manifold-edge
sudo install -d -m 0700 -o 1000 -g 1000 data/edge data/edge/spool
umask 077
test ! -e .env && test ! -e edge.env || exit 1
printf 'MANIFOLD_VERSION=0.6.3\nPOSTGRES_PASSWORD=%s\n' \
  "$(openssl rand -hex 32)" > .env
{
  printf 'MANIFOLD_EDGE_API_URL=https://edge.example.com\n'
  printf 'MANIFOLD_EDGE_INSTALLATION_ID=installation-1\n'
  printf 'MANIFOLD_EDGE_SHARED_SECRET=%s\n' "$(openssl rand -hex 32)"
  printf 'MANIFOLD_SMTP_HOSTNAME=mx.example.com\n'
} > edge.env
chmod 600 .env edge.env
```

API URL 使用 HTTPS origin，不包含 `/api/v1` 或其他路径前缀。
安装 ID 和至少 32 字节的 shared secret 需在主程序与 Edge 保持一致。
Edge 不需要主程序的 `SECRET_KEY_BASE` 或 Connector 加密密钥。

保存下面的 Edge `compose.yaml`；不要把主镜像设置为 `MANIFOLD_ROLE=edge` 来代替 Edge 镜像：

```yaml
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: manifold_edge
      POSTGRES_DB: manifold_edge
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U manifold_edge -d manifold_edge"]
      interval: 5s
      timeout: 5s
      retries: 12
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  edge:
    image: ghcr.io/gsmlg-dev/manifold-edge:${MANIFOLD_VERSION:-0.6.3}
    restart: unless-stopped
    env_file: edge.env
    environment:
      MANIFOLD_EDGE_DATABASE_URL: postgres://manifold_edge:${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}@postgres:5432/manifold_edge
      MANIFOLD_EDGE_API_BIND: 0.0.0.0
      MANIFOLD_EDGE_API_PORT: "4291"
      MANIFOLD_SMTP_BIND: 0.0.0.0
      MANIFOLD_SMTP_PORT: "2525"
      MANIFOLD_SPOOL_DIR: /var/lib/manifold-edge/spool
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:4291:4291"
      - "25:2525"
    volumes:
      - ./data/edge:/var/lib/manifold-edge
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  postgres_data:
```

迁移并启动：

```sh
set -e
docker compose config --quiet
docker compose pull
docker compose up -d --wait postgres
docker compose exec -T postgres pg_isready -U manifold_edge -d manifold_edge
docker compose run --rm --no-deps edge /app/bin/manifold_edge eval \
  'Manifold.Edge.Release.migrate()'
docker compose up -d edge
docker compose logs --tail=100 edge
```

主机 Caddy 配置 Edge HTTPS API；签名认证在 Edge 执行。不要添加路径前缀、重写请求体，
或将四个 `x-manifold-*` 签名请求头丢弃：

```caddy
edge.example.com {
	reverse_proxy 127.0.0.1:4291
}
```

Edge 后台 API 是 plain HTTP，由代理终止 TLS。使用标准 HTTPS/443 最直接；如 URL 显式包含
端口，Host 必须保留该端口；Caddy 默认透传原始 Host，不另行覆盖它。
主程序和 Edge 时钟应同步，签名默认允许 300 秒时钟偏差。
未经签名访问 `/api/v1/status` 应得到 401，这只证明 listener 在响应，不能当作成功同步验收。

### SMTP STARTTLS

准备与 `MANIFOLD_SMTP_HOSTNAME` 匹配的证书，将包含 `fullchain.pem`、`privkey.pem` 的目录
以只读方式挂载到 Edge 容器 `/run/manifold-tls`，并在 `edge.env` 同时添加：

```dotenv
MANIFOLD_SMTP_TLS_CERTFILE=/run/manifold-tls/fullchain.pem
MANIFOLD_SMTP_TLS_KEYFILE=/run/manifold-tls/privkey.pem
```

Compose 的 Edge `volumes` 增加 `./tls:/run/manifold-tls:ro`。
私钥及父目录必须允许容器 UID/GID `1000:1000` 读取和遍历，不能只检查宿主 root 是否能读。
不要直接使用指向挂载目录外部的证书 symlink。两项都省略时没有 STARTTLS，只设置一项会导致启动失败。
证书续期后更新挂载文件并重启 Edge；当前没有承诺自动热加载。

## 7. 主程序连接 Edge

在主程序 `main.env` 添加 Edge 的相同 URL、安装 ID 和 shared secret：

```dotenv
MANIFOLD_EDGE_API_URL=https://edge.example.com
MANIFOLD_EDGE_INSTALLATION_ID=installation-1
MANIFOLD_EDGE_SHARED_SECRET=REPLACE_WITH_THE_SAME_EDGE_SECRET
MANIFOLD_EDGE_SOURCE_ID=edge-1
```

保持 source ID 稳定，以保留远端来源身份。修改环境文件后执行
`docker compose up -d --force-recreate main`；普通 `restart` 不会载入修改后的 Compose 环境。
这只是重新创建应用容器，持久数据保持在挂载与数据库中。

先配置本地活跃域名、账户及别名，再打开 `/cloud`，执行 **Publish routes** 并确认 Styx
任务完成，然后执行 **Pull deliveries**。自动发布间隔为 5 分钟，拉取间隔为 1 分钟。
`Configured` 只表示本地配置存在；用成功的签名交互和实际测试邮件证明链路可用。
缺少或过期的路由快照会使 Edge 的 RCPT 接收暂时失败，默认路由有效期为 24 小时。

使用独立测试收件地址验收：SMTP 接收后能够在主程序中找到邮件、下载原始邮件，并看到
Edge 的 pending delivery 被确认清理。Edge 的 PostgreSQL 与 spool 都必须持久化，
不能将 SMTP `250` 后的数据留在临时容器层。

## 8. 直接安装 Release 归档

从 [GitHub Releases](https://github.com/gsmlg-opt/manifold/releases) 下载同版本的
`manifold-0.6.3.tar.gz` 或 `manifold-edge-0.6.3.tar.gz`，核对发布 SHA-256 后解压。
归档包含 ERTS，但仍依赖兼容的 Linux/glibc、系统共享库和 CA 证书；不要假设能在 macOS、
Alpine/musl 或任意旧 Linux 上直接运行。不确定目标 ABI 时，使用发布的 Docker 镜像。

为服务建立专用用户和受保护的环境文件。主程序设置 `DATABASE_URL`、Phoenix/Connector 密钥、
`PHX_HOST`，以及指向版本目录外的 spool/raw/blob 绝对路径；Edge 使用第 6 节的 Edge 环境变量。
使用进程管理器将受保护的环境文件加载到服务中；不要把环境文件内容写入启动日志。
Connector 的 `log/connectors` 相对服务工作目录，工作目录必须可写并纳入日志管理。

首次安装先创建空 PostgreSQL 数据库。以服务用户运行对应迁移，再交给 systemd 等进程管理器
以前台 `start` 方式运行；生产归档不会像 Devenv 进程定义一样自动迁移：

```sh
set -e
# 主程序：在解压后的 manifold 目录中运行，环境已由服务管理器加载。
bin/manifold eval '
Application.put_env(:manifold_data, :oban_enabled, false)
{:ok, _} = Application.ensure_all_started(:manifold_data)
path = Application.app_dir(:manifold_data, "priv/repo/migrations")
{:ok, migrated, _} = Ecto.Migrator.with_repo(Manifold.Repo, fn repo ->
  Ecto.Migrator.run(repo, path, :up, all: true)
end)
IO.inspect(migrated, label: "migrated")
'
bin/manifold start
```

```sh
set -e
# Edge：在解压后的 manifold_edge 目录中运行，使用独立数据库。
bin/manifold_edge eval 'Manifold.Edge.Release.migrate()'
bin/manifold_edge start
```

使用 Caddy 等代理保护公开入口，设置服务自动重启与日志轮转。安装旧版本时使用它的配置与迁移说明，
不要将两个归档解压到同一版本目录，也不要让新旧实例同时访问迁移中的数据库。

## 9. 备份与恢复

备份必须同时包含主数据库、spool/raw/blobs、稳定的 Connector 加密密钥及运行配置。
Edge 备份包含它的独立数据库、spool、shared secret 和安装/source 身份配置。
为得到一致副本，暂停新操作并停止相关应用及其所有 worker，保持 PostgreSQL 运行后执行备份。

主程序 Compose 备份示例：

```sh
set -e
umask 077
mkdir -p backups
chmod 700 backups
backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
docker compose stop main
docker compose exec -T postgres pg_dump -U manifold -d manifold -Fc \
  > "backups/database-$backup_stamp.dump"
sudo tar -czf - -- .env main.env data/main \
  > "backups/files-$backup_stamp.tar.gz"
docker compose up -d main
```

命令块使用 `set -e`，任何步骤失败即停止，避免继续启动应用并误报成功。
文件归档使用 `sudo` 读取 UID 1000 专属目录；重定向生成的备份由当前用户持有。
若 dump 或文件归档失败，检查并修复备份，不能把失败的副本标为可恢复。
Edge 使用同样过程，替换为 `stop edge`、数据库用户/库名 `manifold_edge` 和 `.env edge.env data/edge`；
启用 STARTTLS 时还要保存证书获取与续期配置。远端 SMTP 服务器在 Edge 停机期间需重试投递。
将备份加密后复制到另一存储位置，单独保护密钥；不要删除当前仍在使用的 Docker volumes。

恢复时先停止旧实例，在独立目录/Compose 项目上准备空数据库，恢复同一备份集的文件与配置，
确认 UID/GID 和原加密密钥，再导入数据库。例如空主数据库：

```sh
set -e
# 在独立恢复目录中，先准备 compose.yaml、恢复的配置与数据。
docker compose -p manifold-restore up -d --wait postgres
docker compose -p manifold-restore exec -T postgres pg_restore \
  -U manifold -d manifold --exit-on-error < backups/database-RESTORE_TIMESTAMP.dump
```

先检查 schema、对象文件、待执行任务及账号身份，再用兼容版本执行迁移/启动步骤。
恢复环境使用不同端口，不能与现有生产实例争用同一数据库或 storage。
恢复的 Styx 任务在应用启动后会继续执行，应先核对待发送和不确定发送状态，再恢复对外服务。
仅有数据库 dump 而丢失 raw、spool 或加密密钥不是完整恢复。

## 10. 升级与回退

1. 阅读目标版本 Release notes、[当前进度与限制](PROGRESS.md) 和相关迁移说明，保留旧镜像/归档。
2. 暂停新操作，处理队列中的发送与不确定提交；停止所有旧 Web、Connector 和任务消费者（Oban 或 Styx）实例。
   历史 Gmail/Microsoft 共享授权和 Settings cutover 要求 **非滚动升级**，见
   [README 迁移说明](../README.md#non-rolling-gmail-authorization-cutover)。
3. 按第 9 节备份。在停止应用后先不要执行备份示例最后的应用启动命令。
4. 修改 `.env` 中 `MANIFOLD_VERSION`，或改为目标镜像 digest；执行 `docker compose pull`。
5. 执行对应主程序/Edge 的一次性迁移，然后 `docker compose up -d main` 或 `up -d edge`。
6. 检查页面和 LiveView、静态资源、数据库、Styx、provider 同步，以及需要时的 Edge 收信/拉取链路。

固定版本镜像更新时仍要执行 `pull`；`latest` 不能作为可重复的升级基线。
数据库没有变化或新 schema 明确向后兼容时，才可以仅切回旧二进制。
不要默认执行 migration `down`：共享授权有 rollback preflight，iCloud schema 回退可能删除本地数据。
具体限制见 [OAuth 迁移说明](../README.md#non-rolling-oauth-provider-settings-cutover) 和
[iCloud 升级说明](ICLOUD.md#upgrade)。

需要数据库恢复时，恢复与旧版本配套的一致备份集。升级后若已经接受了新邮件或本地编辑，
先保存这些数据并制定恢复/合并方案；直接覆盖成升级前的备份会丢失它们。

### Oban 切换到 Styx

使用 Styx 的版本需要执行 `20261021000000_migrate_oban_storage_to_styx.exs`。
这是非滚动切换：暂停新请求和后台生产者，停止所有旧应用与消费者，再使用新版本执行第 4 节的一次性迁移。
保留的 `:oban_enabled` 开关现在控制 Styx；迁移进程必须将它设为 `false`。

迁移将原有任务完整复制到 `styx_jobs`，保留 ID、worker 名称、参数、状态、重试历史和时间，
并延续旧序列的高水位。旧的 SQL NULL `meta`、`tags` 分别转为 `{}`、`[]`。
旧 peer 租约不复制。空的 `oban_jobs_styx_rollback` 与 `oban_peers_styx_rollback`
仅保留旧表结构供回迁使用，不能手动写入或删除。

存在执行中的任务、独立 Styx 历史，或 `tags` / `attempted_by` 中超过 255 字符的元素时，
迁移会拒绝切换。先核对原因与不确定发送状态，不要通过批量重置任务状态绕过检查。
迁移成功后再启动新应用，检查 `/jobs`、账户同步和实际任务执行。

从旧 Oban 数据库升级后若需要回退，先停止所有 Styx 实例，使用仍含 Styx 的新二进制只回退该迁移：

```sh
bin/manifold eval '
Application.put_env(:manifold_data, :oban_enabled, false)
{:ok, _} = Application.ensure_all_started(:manifold_data)
path = Application.app_dir(:manifold_data, "priv/repo/migrations")
{:ok, migrated, _} = Ecto.Migrator.with_repo(Manifold.Repo, fn repo ->
  Ecto.Migrator.run(repo, path, :down, to: 20261021000000)
end)
IO.inspect(migrated, label: "rolled_back")
'
```

Docker 安装用 `docker compose run --rm --no-deps main /app/bin/manifold eval` 执行相同表达式。
回迁复制当前 Styx 任务，包括升级后新增的任务与最新终态，不恢复旧任务快照；
旧 enum 不支持某个状态或检测到独立写入时，会拒绝回退。
确认 `oban_jobs` 恢复且切换迁移已回退后，才启动旧二进制，不要继续回退历史 `AddOban`。
全新安装直接创建 Styx 存储，没有旧 Oban 表结构；此回迁路径不为它创建 Oban 数据库。

## 11. 常见问题

| 现象 | 检查 |
| --- | --- |
| 存储或日志 `permission denied` | 挂载目录 UID/GID 1000:1000、父目录遍历权限及剩余磁盘空间；不要将整棵 `/app` 替换为数据目录 |
| 首次启动报缺表 | 先运行对应 Release 的迁移；应用容器不会自动迁移 |
| `SECRET_KEY_BASE` / encryption key 缺失或不合法 | 检查 `main.env` 是否加载；Connector key 必须是 32 字节的 Base64，不是十六进制字符串 |
| UI 能打开，LiveView 不连接 | 检查 HTTPS Host 与 `PHX_HOST`、`/live` WebSocket 转发和访问控制；API 请求不能全部转发到 Web 4290 |
| Edge API 401 | 未签名访问本就为 401；主程序请求需检查 shared secret、安装 ID、公开 Host/端口、原始路径及时间同步 |
| Edge 不接收已知地址 | 检查路由发布任务、快照有效期、活跃账户/域名/别名；`Configured` 不等于路由已发布 |
| 升级后 OAuth 失效 | 保留原 Connector key，检查 Settings 与迁移要求；不要生成新 key 代替丢失的 key |

文档中的 Compose/Caddy 示例应做配置和语法检查。真实 provider 授权、发送、Apple 写入、
公网 DNS/SMTP 和备份恢复演练需要在目标环境单独验收；历史 fixture 或 Release 检查不替代这些结果。
