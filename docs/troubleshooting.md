# Troubleshooting

先跑 `pi-t3-doctor`。它按顺序检查：垫片可执行、模板、OptChat 与补丁状态、T3 provider 设置、日志、进程、profile/锁、会话绑定。退出码 `1` 表示有项需要处理。

## 线程没有独立 profile（同一 project 的多条线程串上下文）

```sh
pi-t3-doctor | sed -n '/Session bindings/,/^$/p'
```

- 绑定是**按 cwd 的会话目录**发现的：同一个工作目录下的多条线程共用一份绑定。
- 需要严格隔离时给每条线程开 worktree（不同 cwd → 不同绑定）。
- 日志里出现 `no-inject-bound` 说明这本来就是预期行为。

## 日志里全是 `skip-no-optchat`

```
skip-no-optchat  reason=/Users/…/.pi/agent/npm/node_modules/pi-optchat/src/index.ts
```

垫片只有在 `settings.json` 里能 grep 到 `"npm:pi-optchat"` **且**源码存在时才注入。检查：

```sh
pi list
jq '.packages' ~/.pi/agent/settings.json
ls ~/.pi/agent/npm/node_modules/pi-optchat/src/index.ts
```

## 日志里是 `skip-unpatched`

`pi-optchat` 升级覆盖了源码导致补丁丢失：

```sh
pi-t3-patch-optchat --check    # 2 = 可以打；3 = 上游形状变了
pi-t3-patch-optchat
```

打完必须**重启 T3**（或者在 T3 里新开线程），正在跑的 Pi 进程用的还是旧代码。

## `pi-t3-patch-optchat --check` 返回 3

上游源码形状变了（锚点没匹配上）。**不要**改脚本里的锚点字符串硬打补丁，先看上游 diff：

```sh
diff -u ~/.pi/agent/npm/node_modules/pi-optchat/src/index.ts.pre-t3patch \
        ~/.pi/agent/npm/node_modules/pi-optchat/src/index.ts
```

返回 3 时垫片默认会 passthrough（不注入），所以线程还能起，只是没有独立 profile。临时绕过：`OPTCHAT_T3_REQUIRE_PATCH=0`。

## 线程起不来，报 `ProfileBusyError`

1. `pi-t3-doctor` 看 `Profiles and locks`：`lock=` 后面是活的 PID 说明真有个进程还持有它。
2. 确认补丁在：`pi-t3-patch-optchat --check` 应为 0。
3. 确认没有残留的 `--optchat-profile`：垫片看到用户自己传了 profile 就完全不插手。

## Pi 进程起来就挂，报 `node: not found`

T3 后台服务不继承你 shell 的 PATH。垫片会自己找 node，仍失败时：

```sh
which -a node
echo "$PATH"
```

确保 `node` 在 fnm/nvm/volta/homebrew 的常见位置之一，或者把绝对路径版本管理器目录加到 T3 的环境里。

## 某条线程的 profile 被改名了（`<name>.bad.<时间戳>`）

说明 `compactor`/`subagent` 真的坏了，垫片把旧目录留档后重建：

```sh
ls -la ~/.optchat/profiles | grep bad
jq . ~/.optchat/profiles/<name>.bad.<ts>/config.json
```

确认无误后可以删掉留档；`AGENTS.md` 里自定义过的内容需要手动搬回新 profile。

## 我加在 profile 里的 `AGENTS.md` 没了

垫片只在 `AGENTS.md` **缺失**时补一个占位文件，从不覆盖已有内容。若发现内容被换掉，说明这个 profile 走了「坏配置 → 搬走重建」路径，看 `.bad.*` 目录。

## 关闭 / 回滚

```sh
touch ~/.optchat/t3-off          # 立即停止注入（下一条线程生效）
rm ~/.optchat/t3-off

pi-t3-patch-optchat --revert     # 还原 pi-optchat 源码
```

彻底卸载：删掉 `~/.local/bin/pi-t3*`、`~/.local/share/pi-t3/`，并把 T3 的 Pi binary path 指回真 `pi`。
