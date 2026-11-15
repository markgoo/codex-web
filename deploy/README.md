# 把 codex-web 放到局域网里（nginx + 登录账号）

## 先说结论：这个项目没有任何认证

翻过代码和文档，`codex-web` **确实完全没有** 认证/授权层：

| 位置 | 情况 |
| --- | --- |
| [`src/server/main.ts`](../src/server/main.ts) | Fastify 只注册了 multipart + static，没有任何 auth 中间件；默认 `--host 127.0.0.1`，`--host 0.0.0.0` 只是改监听地址，不带来登录 |
| `main.ts` 的 WebSocket 升级 | 只校验路径是不是 `/__backend/ipc`，不校验来源、不校验 token、不校验 Cookie |
| `main.ts` 的静态目录 | `app.register(fastifyStatic, { root: "/", prefix: "/@fs/" })` —— 也就是 **整个文件系统都能通过 `http://host:8214/@fs/C:/...` 读出来** |
| [`README.md`](../README.md#L86-L104) | 作者自己写的 security 段：只放在可信网络；需要 authn/authz 就自己在外面套反向代理 / wireguard / tailscale / ssh 隧道 |

作者列出的后果很直白：**能打开这个 Web UI 的人 = 能在你机器上以同一个用户身份跑命令、读写文件、用你已登录的 Codex 账号额度。**

所以"nginx 反代 + 账号密码"不只是可行，而是作者明确推荐的用法。

## 目标架构

```
局域网设备 ──https://<局域网IP>:8443────▶ nginx（TLS + basic auth）
   :8080 只回 301 跳到 8443                    │ 127.0.0.1:8214
                                            ▼
                                        codex-web
```

要点：**codex-web 只监听 127.0.0.1，nginx 才是唯一对局域网开放的进程。**
这样即使哪天 nginx 挂了、配置错了，应用本身也不会直接暴露在局域网里；
Windows 防火墙也只需要放行 nginx 的端口，不用给 node 开洞。

**为什么必须 HTTPS**：这里跑的是浏览器里的 ChatGPT 前端，`http://<局域网 IP>` 不是
secure context，`window.crypto.randomUUID` 直接是 undefined，包在渲染前就抛
`crypto.randomUUID is not a function` —— 页面全白。`http://127.0.0.1` / `localhost`
属于 secure context，所以本机直连没事，一到局域网就崩。顺带 basic auth 的密码也不会明文上网。

## 步骤

### 1. 建账号

密码文件用 apr1（Apache `htpasswd -m` 那种格式，nginx 原生支持）。
脚本会先自检哈希实现，再写文件，避免写出一个永远登不进去的密码文件。

```powershell
# 自动生成一个 28 位随机密码，只打印一次，请立刻存进密码管理器
node deploy/htpasswd.mjs generate alice

# 或者自己指定密码（从 stdin 读，不进命令行历史）
Read-Host -AsSecureString | % { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) } | node deploy/htpasswd.mjs add alice

# 查看 / 删除
node deploy/htpasswd.mjs list
node deploy/htpasswd.mjs remove alice
```

生成的文件是 `deploy/htpasswd`，一行一个 `用户名:$apr1$...`。
本机已建好账号 `codex`（`deploy/htpasswd`，gitignore）。

### 2. 拿 nginx

Windows 版没有安装包，解压即用（不需要管理员权限也能跑）。
本机已经放好了：`tools\nginx-1.30.6\`（从 nginx.org 下的 Windows 稳定版 zip，`tools/` 已 gitignore）。
换机器时按同样目录名解压一份即可，或者改 `deploy/nginx.ps1` 的 `-Version`。

```powershell
# 重新下载（Node 的 fetch 能过，curl 在本机 schannel 下会报 SEC_E_NO_CREDENTIALS）
node -e "fetch('https://nginx.org/download/nginx-1.30.6.zip').then(async r=>require('node:fs').writeFileSync('tools/nginx-1.30.6.zip',Buffer.from(await r.arrayBuffer())))"
& "$env:SystemRoot\System32\tar.exe" -xf tools\nginx-1.30.6.zip -C tools
```

Linux / WSL: `sudo apt install nginx`。

### 3. 配置

先出证书（自签；SAN 里要写你实际的局域网 IP，浏览器才不会因为名字不匹配额外报警）：

```powershell
# Git for Windows 自带 openssl；本机 OPENSSL_CONF 可能被别的软件指坏，先指回 Git 的
$env:OPENSSL_CONF = "C:\Program Files\Git\usr\ssl\openssl.cnf"
New-Item -ItemType Directory -Force deploy\certs | Out-Null
& "C:\Program Files\Git\usr\bin\openssl.exe" req -x509 -nodes -days 825 -newkey rsa:2048 `
  -keyout deploy/certs/codex-web.key -out deploy/certs/codex-web.crt `
  -subj "/CN=codex-web" `
  -addext "subjectAltName=IP:192.168.1.10,IP:127.0.0.1,DNS:localhost"   # 192.168.1.10 换成你的局域网 IP
```

[`deploy/nginx.conf`](nginx.conf) 就是完整配置（`auth_basic_user_file` 指向本仓库的 `deploy/htpasswd`，
`ssl_certificate*` 指向刚生成的两份文件），它被复制成 `tools\nginx-1.30.6\conf\nginx.conf`。
改完的话用脚本重载，它会先 `-t` 再 reload：

```powershell
pwsh -File deploy/nginx.ps1 test      # 语法检查
pwsh -File deploy/nginx.ps1 reload    # 复制 deploy/nginx.conf 并热重载
pwsh -File deploy/nginx.ps1 start     # 启动（已在跑会提示）
pwsh -File deploy/nginx.ps1 status    # 端口 / pid / 是否在监听
pwsh -File deploy/nginx.ps1 stop
```

> nginx 必须带 `-p <自己的目录>` 启动，因为配置里的 `mime.types`、`logs/error.log`、`logs/nginx.pid`
> 都是相对前缀解析的；直接双击 `nginx.exe` 会用当前工作目录当前缀，然后报 "could not open error log file"。
> 脚本已经处理好了。
>
> `stop` / `reload` 要能向 master 发信号：如果 nginx 是用别的权限（比如管理员）起的，
> 普通权限的 `nginx -s stop` 会报 `OpenEvent(...) failed (5: Access is denied)`，用同等权限执行即可。

### 4. 让局域网能进来（只需要给 nginx 开洞）

```powershell
# 以管理员身份
New-NetFirewallRule -DisplayName "codex-web nginx" -Direction Inbound `
  -Protocol TCP -LocalPort 8080,8443 -Action Allow -Profile Private
```

本机地址：`ipconfig` 里无线/以太网那块 IPv4。
然后手机/另一台电脑浏览器打开 `https://<局域网IP>:8443`，自签证书警告点继续，输账号密码。
`http://<局域网IP>:8080` 会 301 跳到 8443。

> 第一次在**新浏览器**打开时，可能看到一条 "Couldn't load workspace settings / Retry"。
> 原因是 `%USERPROFILE%\.codex\attachments\` 不存在，前端读 `pasted-text-attachments.json` 拿到
> `os error 3` 就当成加载失败。建好目录（或点一次 Retry）即可，之后不会再来。

### 5. 启动 codex-web（保持 loopback）

```powershell
pwsh -File deploy/run-server.ps1
# 等价于：node src/server/main.js --host 127.0.0.1 --port 8214
```

**不要** 加 `--host 0.0.0.0`，那样就绕过了 nginx 和登录。

打开 <http://127.0.0.1:8214> 应该直接是 Codex 界面（左侧 Recents、中间 "What should we build?"）。

> **必须在普通终端里启动，不要用受限/沙箱化的进程去拉它。**
> app-server 是 codex.exe 的子进程，要往 `%USERPROFILE%\.codex\tmp\arg0-windows\` 写别名目录；
> 被沙箱拦住时它会 `os error 5 (拒绝访问)` 退出，界面就是你最熟悉的那个白屏。

#### 启动后白屏：先看是不是这一条

这套 app 包是 **macOS 版**，里面没有 Windows 的 codex CLI。启动时它要读"组织网络设置"
（组织策略），这条数据来自 app-server；拿不到就直接 `app.paused`，弹一个只有
Retry / Sign out / Quit 的原生对话框——浏览器点不到它，所以页面永远是空白。

`run-server.ps1` 现在会自己找本机 CLI 并导出 `CODEX_CLI_PATH`，启动时会打印：

```
codex-web: http://127.0.0.1:8214  (loopback only)
codex cli: C:\Users\<you>\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\
           @openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe
```

找不到就会直接报错退出，并告诉你怎么装（`npm install -g @openai/codex`）或手动指定
`CODEX_CLI_PATH`。看到 `codex cli:` 那行之后仍白屏，日志里会有：

| 日志 | 含义 |
| --- | --- |
| `[dialog] Organization settings could not be loaded …` | 上面那个门禁被触发了；紧跟其后的 `[net-request]` / `[net.fetch]` 行说明是哪次请求失败 |
| `os error 5 (拒绝访问)` + `arg0-windows` | app-server 写不进 `~/.codex/tmp`，多半是沙箱/安全软件挡住了 |
| `listen EADDRINUSE … 8214` | 已经有一个实例在跑（只允许一个），先关掉它 |

`CODEX_WEB_DEBUG_NET=1` 会打印主进程每条出站请求与结果；`CODEX_WEB_DEBUG_SHIM=1`
会打印所有被调用的 Electron API（很吵，只在排查时用）。

## 必须知道的几点

1. **这就是走 HTTPS 的原因**：既是 secure context（否则 `crypto.randomUUID` 不存在、白屏），
   也不让 basic auth 的密码明文上网。自签证书浏览器会警告一次，点继续即可；
   要彻底消警告就把 `deploy/certs/codex-web.crt` 装进设备的受信任根。
2. **密码等于 root 权限**（至少是"能在这个用户下跑任意命令"）。用长随机密码，别复用。
   账号密码泄露 = 别人能翻你的 `~/.ssh`、`~/.codex/auth.json`。
3. **`/@fs/` 前缀能读全盘**。有登录挡着才是安全的；没有登录就等于把整台机器公开。
4. **WebSocket 别漏代理**：`nginx.conf` 里 `Upgrade`/`Connection` 两行是 agent 能不能正常流式输出的关键，
   少了它会表现为页面能打开但一直转圈。前端是用 `window.location.host` 拼 WS 地址的
   （[`src/browser/shim.ts:244`](../src/browser/shim.ts#L244)），所以只要浏览器地址是 nginx 那个地址就对。
5. **比 nginx 更省事的替代**：如果只是你自己几台设备用，Tailscale / WireGuard 组网（不暴露任何端口）
   比"公网式反代"更安全，也更少维护。nginx 方案适合"局域网内多人、要给账号"的场景。

## 本机当前实况（2026-11-15 收口时）

| 项 | 值 |
| --- | --- |
| codex-web | `127.0.0.1:8214`，由 `deploy/run-server.ps1` 在普通终端启动（沙箱里起会因 app-server 写 `~/.codex/tmp` 被拒而白屏） |
| nginx | `tools\nginx-1.30.6\`，`0.0.0.0:8080`（301）+ `0.0.0.0:8443`（TLS + basic auth） |
| 账号 | `codex`（密码在生成时只打印一次；`node deploy/htpasswd.mjs remove codex` 可删） |
| 证书 | `deploy/certs/codex-web.{crt,key}`，SAN = 局域网 IP / `127.0.0.1` / `localhost`，825 天 |
| 局域网入口 | `https://<局域网IP>:8443` |
| 防火墙 | 还需你自己提权执行上面第 4 步那条 `New-NetFirewallRule`（放行 8080,8443） |

验证脚本（都在 `scratch/`，不进版本库）：`https-check.mjs` 查 301/401/200/WSS，
`cdp-auth-check.mjs` 用真实浏览器带 `Authorization` 头打开并把结果截图。

## 附：在 Windows 上构建时踩到的坑（都已在脚本里处理）

上游的 `scripts/prepare` / `scripts/prepare_asar` 是 bash + macOS 包，本项目用
[`setup-windows.ps1`](setup-windows.ps1) 做了等价移植。下面几条是排查出来的真实原因，改脚本前先看一眼：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `better-sqlite3` 编译失败 | 它 12.9.0 只提供 Node 20–25 的预编译包；本机 Node 26 没有，且 VS2022 缺 C++ 工具链 | 脚本自动下载便携 Node 22.23.5 到 `tools/`（校验 SHA256），不动系统 Node |
| `npm install` 报 `EPERM ... package.json` | 本机安全软件按文件名保护 npm 清单文件，拒绝 npm 改写 | 用 `--no-package-lock`，缓存也放回仓库内 `scratch/npm-cache` |
| 19 个补丁里 17 个失败 | prettier 默认遵守 `.gitignore`，而文件都在被忽略的 `scratch/` 下，于是它**静默跳过**全部文件；补丁需要的是"已格式化"的源码 | 传 `--ignore-path` 指向空文件（上游 bash 里是 `--ignore-path /dev/null`，同理） |
| `patch` 打不开补丁文件 | Git 自带的 MSYS `patch` 不认相对路径/反斜杠 | 一律传绝对路径、正斜杠 |
| `unzip` 只解出空目录 | MSYS `unzip` 对 `app.asar.unpacked/*` 通配符处理不对 | 改用 Windows 自带 `bsdtar`（`%SystemRoot%\System32\tar.exe`） |
| `tsc` 报 `EPERM` 写不进 `src/` | 安全软件拒绝这个 Node 进程写入被保护的源码目录 | 输出改到 `scratch/server/`（同在两层深度，`../../scratch/asar` 照样解析）；把项目目录加进信任区后可以改回标准布局 |
| 服务启动即 `EPERM mkdtemp` | 该 Node 进程被拒绝写 `%TEMP%` | `run-server.ps1` 把 `TEMP`/`TMP` 指到 `scratch/tmp` |
| 服务起来了但页面永远白屏 | 包是 macOS 版、没有 Windows codex CLI，读不到组织设置后 `app.paused` 弹原生对话框 | `run-server.ps1` 自动定位本机 CLI 并导出 `CODEX_CLI_PATH`（见上面第 5 步） |
| 明明重新构建了 `scratch/server`，行为却还是旧的 | `src/server/module.ts` 把 `electron` 别名硬编码到 `src/server/electron/index.js` | 改成按运行目录解析（`<build>/electron/index.js`，找不到才回退 `src/`），并让 `run-server.ps1` 优先用 `scratch/server` |

**根本解法**：把 `tools\node-v22.23.5-win-x64\node.exe`（或整个项目目录）加进安全软件的信任区，
上面这些绕过就都不再必要，`npm run build` 也能按标准布局工作。

