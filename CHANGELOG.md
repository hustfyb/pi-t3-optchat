# Changelog

## 1.0.0

首个公开版本，源自一台 macOS 机器上跑通的 T3 Code + Pi + OptChat 组合。

**新增**

- `pi-t3`：Pi 启动垫片。仅对 T3 RPC 会话注入线程级 `--optchat-profile`，其余情况原样透传。
- `pi-t3-patch-optchat`：给 `pi-optchat` 补同进程自锁守卫，支持 `--check` / `--apply` / `--revert`，锚点不匹配时拒绝施工。
- `pi-t3-doctor`：一站式自检（垫片、模板、补丁、T3 设置、日志、进程、profile/锁、会话绑定），附 `name <cwd>` 查询绑定。
- `install.sh`：按前缀安装，支持 `--link`；无模板时用 Pi 当前默认模型生成一份。
- `tests/smoke.sh`：沙箱内 46 项断言，覆盖透传判定、profile 铸造、绑定复用、三级修复、补丁三态、补丁门禁与 doctor 退出码。

**修复/改进（相对内测脚本）**

- 保留 OptChat 运行时写入的合法 `main`：以前会把整个 profile 误判为损坏并搬走，现在只剥离结构非法的 `main`。
- `AGENTS.md` 缺失时原地补齐，不再触发 profile 重建。
- profile 被活进程持锁时跳过修复。
- 模板路径改为随安装位置解析，支持源码树与安装前缀两种布局。
- `pi-t3-doctor` 的模板/配置校验改用与垫片一致的口径（允许合法 `main`）。
- 兼容 bash 3.2（macOS 自带 bash）在 `set -u` 下展开空数组。
