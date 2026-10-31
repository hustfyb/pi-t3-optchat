# pi-t3

[![ci](https://github.com/hustfyb/pi-t3-optchat/actions/workflows/ci.yml/badge.svg)](https://github.com/hustfyb/pi-t3-optchat/actions/workflows/ci.yml)

让 **T3 Code** 里的每一条 Pi 线程拥有自己的 **OptChat** profile —— 不需要改 T3 源码，也不需要给每条线程手工建 profile。

`pi-t3` 是一个 Pi 启动垫片（launcher shim）：T3 把 Pi 的 `binaryPath` 指向它，它只在「真的是 T3 的 RPC 会话」时注入一个线程级 profile，其它情况（CLI 交互、`--print`、`--resume`……）原样 `exec` 真正的 Pi。

```text
T3 Code (每条线程一个 Pi 进程)
        │  spawn: pi-t3 --mode rpc ...
        ▼
   ┌─────────────┐   非 RPC / --print / --resume / 用户自带 profile
   │   pi-t3     │──────────────────────────────────────────▶ 真 Pi（原样参数）
   └─────────────┘
        │ RPC 且会话里还没有 optchat.profile 绑定
        ▼
   mint t3-<cwd-slug>-<rand>  →  ~/.optchat/profiles/<name>/config.json + AGENTS.md
        │
        ▼
   真 Pi --optchat-profile <name> ...
```

## 它解决的三件事

| # | 症状 | 原因 | pi-t3 的做法 |
|---|---|---|---|
| 1 | 同一个 T3 project 下多条线程的上下文互相串味 | OptChat 默认按 **工作目录** 绑 profile，同 cwd 的线程共享一个 | 每条线程一个 profile，按线程会话发现绑定 |
| 2 | 第二条线程报 `ProfileBusyError` / 起不来 | OptChat 把「本进程已持有的 profile」当成别人的锁 | `pi-t3-patch-optchat` 打了个同进程自锁守卫 |
| 3 | T3 后台服务里 Pi 直接起不来（`node: not found`） | T3 service 不继承你 shell 的 fnm/nvm PATH | 垫片自己把 node 找出来塞进 PATH |

## 安装

依赖：`bash`、`python3`、`jq`、已安装的 [pi-optchat](https://www.npmjs.com/package/pi-optchat)（`pi install npm:pi-optchat`）、Pi ≥ 1.x、T3 Code。

```sh
git clone https://github.com/hustfyb/pi-t3-optchat ~/pi-t3-optchat
cd ~/pi-t3-optchat
./install.sh              # 装到 ~/.local/bin + ~/.local/share/pi-t3
./install.sh --link       # 或者：软链，仓库保持为唯一来源
```

> 仓库叫 `pi-t3-optchat`，装出来的命令叫 `pi-t3`（垫片本身只服务于 T3，OptChat 是实现细节）。

`install.sh` 会：

1. 安装 `pi-t3`、`pi-t3-doctor`、`pi-t3-patch-optchat` 到 `$PREFIX/bin`（默认 `~/.local/bin`）；
2. 如果还没有 `profile-template.json`，就用你 Pi 当前的默认模型生成一份（拿不到默认模型则跳过，届时新 profile 直接走 Pi 默认模型）。

然后把 T3 的 Pi provider 指向垫片：

```text
T3 Code → Providers → Pi
  Binary path:      /Users/<you>/.local/bin/pi-t3
  Launch arguments: （留空）
```

打补丁并自检：

```sh
pi-t3-patch-optchat --check    # 0 已打 / 2 可打 / 3 上游形状变了 / 4 找不到源码
pi-t3-patch-optchat            # 打补丁，原文件留作 index.ts.pre-t3patch
pi-t3-doctor
```

> 每次升级 `pi-optchat` 都会覆盖源码，需要重新执行一次 `pi-t3-patch-optchat` 并重启 T3。

## 日常命令

```sh
pi-t3-doctor                      # 全量自检：垫片、补丁、模板、T3 设置、锁、绑定
pi-t3-doctor name /path/to/project  # 这个线程绑的是哪个 profile
pi-t3-patch-optchat --revert      # 还原 pi-optchat 源码
tail -20 ~/.optchat/t3-bindings.log
touch ~/.optchat/t3-off           # 临时关闭自动绑定；rm 恢复
```

## 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `PI_T3_REAL` | 自动探测 | 真 Pi 二进制的绝对路径 |
| `PI_T3_TEMPLATE` | `~/.local/share/pi-t3/profile-template.json` | 新 profile 的模型模板 |
| `OPTCHAT_HOME` | `~/.optchat` | OptChat 根目录 |
| `PI_CODING_AGENT_DIR` | `~/.pi/agent` | Pi agent 目录 |
| `PI_CODING_AGENT_SESSION_DIR` | `$PI_CODING_AGENT_DIR/sessions` | 会话目录（绑定发现用） |
| `OPTCHAT_T3_AUTOBIND` | `1` | `0` = 完全不注入 |
| `OPTCHAT_T3_REQUIRE_PATCH` | `1` | `0` = 未打补丁也照常注入（调试用） |
| `OPTCHAT_T3_SEED` | 空 | 指定某个 profile 目录/文件作为新 profile 的模型来源 |
| `OPTCHAT_T3_DEBUG` | `0` | `1` = 把 passthrough 决定也写进日志 |
| `PI_T3_DRY_RUN` | `0` | `1` = 只打印将要执行的命令，不启动 Pi |
| `T3_SETTINGS` | `~/.t3/userdata/settings.json` | doctor 读的 T3 配置文件 |

## 工作原理

完整细节见 [`docs/how-it-works.md`](docs/how-it-works.md)，要点：

- **绑定存在会话文件里**：OptChat 自己会把 `optchat.profile` 记录写进 `*.jsonl`，垫片只读不写，所以线程重启、进程被杀、T3 重开都还能接回同一个 profile。
- **修复不丢数据**：合法 `main`（OptChat 运行时会自己写）原样保留；只有 `compactor`/`subagent` 真的坏了才把 profile 改名成 `.bad.<时间戳>` 后重建；`lock.sock` 有活进程时一律不动。
- **补丁是可回滚的**：`pi-optchat` 源码被四个精确锚点匹配后才改，改完带 `optchat.t3-selflock-guard v1` 标记，`--check` 能分辨「已打 / 可打 / 上游变样了」。

## 故障排查

见 [`docs/troubleshooting.md`](docs/troubleshooting.md)。先跑：

```sh
pi-t3-doctor
```

## 测试

```sh
tests/smoke.sh          # 沙箱里跑真垫片 + 假 Pi + 假 optchat：46 项断言
KEEP=1 tests/smoke.sh   # 保留沙箱目录以便排查
```

用例覆盖：透传判定、profile 铸造、绑定复用、三级修复、补丁 apply/check/revert、补丁门禁、doctor 正常与异常退出。

## 限制

- 同一个工作目录下的**多条线程**共用同一个 `--optchat-profile`（绑定按 cwd 的会话目录发现）。要严格隔离，给每条线程开 worktree。
- 补丁依赖 `pi-optchat` 的具体源码形状；上游改动后 `--check` 会返回 `3` 而不是瞎改。
- 只在 macOS + bash 3.2 / Linux + bash 5 上验证过；`pi-t3-doctor` 的进程 cwd 检测在 Linux 走 `/proc`，在 macOS 走 `lsof`。

## License

MIT © 2026 hustfyb

---

### English

`pi-t3` is a Pi launcher shim for [T3 Code](https://t3.chat): it gives every T3 thread its own [OptChat](https://www.npmjs.com/package/pi-optchat) profile, patches OptChat's same-process lock handling, and repairs node's PATH for T3's background service. Non-RPC invocations pass straight through to the real `pi` binary.

```sh
./install.sh && pi-t3-patch-optchat && pi-t3-doctor
```

Point T3's Pi provider at `~/.local/bin/pi-t3` with empty launch arguments.
