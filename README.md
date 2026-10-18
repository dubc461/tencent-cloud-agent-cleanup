# tencent-cloud-agent-cleanup.sh

**支持 Debian 12**  

腾讯云 CVM 一次性清理脚本：删除镜像自带的 stargate、barad 云监控、YunJing 云镜、
TAT 自动化代理和 onion 预加载库，并拆掉它们的复活机制。保留镜像的网卡调优脚本。
仅在目标机器上是 root 时运行。

```bash
# 1. 先预览（只读，不改任何东西）
./tencent-cloud-agent-cleanup.sh --dry-run

# 2. 确认后执行
./tencent-cloud-agent-cleanup.sh

# 3. 看退出码和结尾提醒，0 = 干净
echo $?
```

## 选项

| 选项 | 说明 |
|---|---|
| `--dry-run` | 只报告现状和将要做的改动，不修改任何文件 |
| `--keep-tat` | 保留 TAT 自动化代理（控制台仍可通过它执行命令） |
| `--keep-python` | 保留 `/usr/local/qcloud/python` |
| `--kill-fd-holders` | 连"只是打开着 YunJing/sgdaemon 文件"的进程也杀；默认只报告（避免误杀 `tail -f` 日志的人） |
| `--wait SECONDS` | 清理后等待多少秒再复查复活情况，默认 90 |
| `--backup-dir DIR` | 备份目录，默认 `/root/tencent-agent-cleanup-<时间戳>` |
| `--force` | 即使看起来不是腾讯云镜像也继续 |

## 清理顺序（顺序有讲究）

1. 先杀掉隐藏的 YunJing 重装监控（多线程 shell / 映射 YunJing 代码的进程），否则删除后约 10 秒就会装回来；
2. 摘除 `/etc/ld.so.preload` 里的 libonion；
3. stargate → barad → YunJing → 旧镜像的 `/usr/local/sa`、`/usr/local/agenttools` → TAT；
4. 清 unit、cron.d、root crontab、rc.local 里的 agent 行，杀残余进程，删目录和杂项；
5. 等待 `--wait` 秒后复查进程、目录、cron、unit、wants 链接、preload——有残留或复活则退出码 2。

## 保留

`/usr/local/qcloud` 下的调优脚本（irq/rps/xps/cpuidle/gpu/scripts 等）、
`/etc/rc.local` 的调优行、`/etc/udev/rules.d/80-qcloud-nic.rules`、`/etc/qcloudzone`。

## 退出码

- `0` 干净
- `2` 有残留、复活，或删不掉（例如文件有 immutable 属性）
- `1` 参数或环境错误（不是 root、缺少腾讯云特征且未 `--force` 等）

## 注意

- 会先备份：修改/删除的 `/etc` 配置（cron、ld.so.preload、rc.local、init 脚本、
  systemd unit、root crontab）都会复制到备份目录；agent 程序目录和库不备份。
- 清理前已加载 libonion 的进程会一直持有到重启，重启后彻底干净。
- 跑完记得按脚本结尾的提醒，去腾讯云控制台关掉主机安全/云监控的自动安装，
  否则控制台可能把 agent 再装回来。
