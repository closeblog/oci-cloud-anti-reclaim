# oci-cloud-anti-reclaim
甲骨文云免费实例保活脚本
注册甲骨文云免费VPS的时候，根据官方政策，当资源使用率低于某一标准时，实例会被回收————机器好好的，某天登不上去了，一看 OCI 控制台，实例已经变成了 `RECLAIMED`。这篇文章把回收政策的判定逻辑进行了梳理，同时给出了一套现成的定时脚本，帮你把实例长期保住。

## 一、Oracle 的空闲实例回收政策是什么

Oracle 官方文档里对此有明确说明：**Always Free 额度下的计算实例，如果被判定为"空闲"，Oracle 有权直接回收**。

![instance-reclaim.webp](/img/instance-reclaim.webp)

判定"空闲"的标准是：在**过去 7 天内**，同时满足以下几个条件：

- CPU 利用率的**第 95 百分位**低于 20%
- 网络利用率低于 20%
- 内存使用率低于 20%（**仅适用于 A1 机型**，即 Ampere ARM 架构实例）

注意这里的关键词是"**同时满足**"——也就是说，只要其中任意一项指标稳定超过 20%，实例就不会被判定为空闲，也就不会被回收。这一点很重要，后面的方案就是围绕它设计的。

### 为什么是"第 95 百分位"而不是"平均值"

这是很多人容易忽略的细节。如果判定标准是平均值，那你必须让 CPU 利用率长期维持在 20% 以上，代价不小。但**第 95 百分位**意味着：允许有 5% 的采样点例外——换句话说，一天 24 小时里，只要有 **1~2 小时**的时间段 CPU 利用率冲到 20% 以上，剩下的时间该闲还是闲，95 百分位这个统计值照样会在阈值以上。

这就给了我们一个思路：**不需要长期占用资源，只需要每天定时"脉冲"一段时间的负载即可。**

## 二、方案一：脚本 + cron

最简单的做法是写一个压力测试脚本，用 `stress-ng` 制造真实的 CPU（以及内存）负载，再用 cron 定时触发。

### [脚本本体](oci-anti-reclaim.sh)

脚本会自动用 `uname -m` 判断架构：`aarch64` / `arm64` 视为 A1 机型，自动带上内存压力；`x86_64` 则只压 CPU，不多此一举。

### 部署步骤 + cron 配置

```bash
sudo mv oci-anti-reclaim.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/oci-anti-reclaim.sh

sudo crontab -e
```

运行后在定时脚本的最后可以加一行，比如每天凌晨 3 点跑 40 分钟、CPU 负载 60%：

```
0 3 * * * /usr/local/bin/oci-anti-reclaim.sh 2400 60 auto >> /var/log/oci-anti-reclaim-cron.log 2>&1
```

脚本创建说明：

>`sudo crontab -e` 执行后会打开一个文本编辑器，把整段 crontab 当成一个纯文本文件在编辑，新的定时任务就是往这个文件里加一行。具体步骤是：
> * 运行 `sudo crontab -e` ,如果是第一次在这台机器上用 `crontab -e`，系统会提示选择一个编辑器，直接选默认的 nano（通常是选项 1）最省心。
> * 编辑器打开后，用方向键把光标移动到已有内容的最后一行下面。文件里可能已经有一些以 # 开头的注释说明，不用管它们，也不要删除或修改原有内容。
> * 在新的一行输入或粘贴：`0 3 * * * /usr/local/bin/oci-anti-reclaim.sh 2400 60 auto >> /var/log/oci-anti-reclaim-cron.log 2>&1` 。确保这一整行没有被拆成两行，也没有多余的空格插在中间。
> * 如果是 nano：按 `Ctrl+O` 保存，接着按 Enter 确认文件名，再按 `Ctrl+X` 退出编辑器。如果打开的是 vim：先按 Esc，再输入 `:wq` 然后回车保存退出。保存后终端通常会提示 `crontab: installing new crontab`，说明写入成功。
> * 运行 `sudo crontab -l` 查看当前 root 的 crontab 列表，确认刚才那一行已经出现在里面。这一步只是列出内容，不会再次打开编辑器。

>小提醒：这一行必须是完整的一整行，`0 3 * * *` 是时间字段，后面接完整命令路径，中间不要换行————很多时候复制粘贴时容易被终端自动换行搞乱格式，导致 cron 解析出错。如果不确定粘贴的内容有没有跑偏，sudo crontab -l 看一眼确认格式没问题就行。

手动执行脚本的话就直接运行： `sudo oci-anti-reclaim.sh` ,如果是第一次运行，脚本会自动安装相关的 stress-ng 模块。

![执行压力测试脚本](/img/oci-anti-reclaim-sh.webp)

脚本执行完成，查看执行日志：

```bash
sudo tail -f /var/log/oci-anti-reclaim-cron.log
```

![日志查看结果]/img/tail-f-log.webp)

cron 方案简单够用，缺点是：机器重启时如果正好错过了触发时间点，就要等到第二天，日志和状态也会发生混乱。想要更稳的方案，可以换成方案二 systemd。

## 三、方案二（推荐）：systemd service + timer

### `.service` 和 `.timer` 分别是什么

这是 systemd 里配对使用的两个 unit 文件：

| 文件 | 作用 |
|---|---|
| `.service` | 定义"要做什么"——跑哪个脚本、什么优先级 |
| `.timer` | 定义"什么时候触发"——相当于 systemd 自带的 cron |

`.timer` 到点后会去启动**同名**的 `.service`（靠文件名对应，不需要在文件里显式声明关联）。你 `enable` 的是 `.timer`，因为你要的是"定时自动跑"；想立刻手动测试一次效果，直接运行 `start` `.service`。

比起 cron，systemd 方案多了几个好处：`Persistent=true` 能保证错过的触发会在下次开机后自动补跑；执行状态能用 `systemctl status` 直接看；日志统一进 `journalctl`，不用自己拼日志文件。

### [service 文件](oci-anti-reclaim.service) 

**注意：文件名： `oci-anti-reclaim.service` ,放在 `/etc/systemd/system/` 目录下**

### [timer 文件](oci-anti-reclaim.timer)

**文件名： `oci-anti-reclaim.timer` ,放在`/etc/systemd/system/` 目录下**

### 部署步骤

```bash
sudo mv oci-anti-reclaim.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/oci-anti-reclaim.sh

sudo mv oci-anti-reclaim.service /etc/systemd/system/
sudo mv oci-anti-reclaim.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now oci-anti-reclaim.timer

# 确认已经排上计划
systemctl list-timers oci-anti-reclaim.timer

# 想手动测试一次
sudo systemctl start oci-anti-reclaim.service

# 查看执行日志
journalctl -u oci-anti-reclaim.service --since today
```

## 一键安装

可以命令行状态下使用如下命令进行一键安装,这样就不必手动运行其它 shell 脚本了：

### 方案一：cron 定时一键安装
`bash <(curl -Ls https://github.com/closeblog/oci-cloud-anti-reclaim/edit/main/install.sh) cron`

### 方案二：systemd 定时一键安装（推荐）
`bash <(curl -Ls https://github.com/closeblog/oci-cloud-anti-reclaim/edit/main/install.sh) systemd`

**必须以 root 运行命令，或者提前 sudo -i 切到 root。完整写法在bash前面加上 sudo：**
**`sudo bash <(curl -Ls https://github.com/closeblog/oci-cloud-anti-reclaim/edit/main/install.sh) cron`**
或
**`sudo bash <(curl -Ls https://github.com/closeblog/oci-cloud-anti-reclaim/edit/main/install.sh) systemd`**

## 五、几点补充

- 脚本运行过程中可以使用 `sudo top` 命令查看资源实时使用情况

>![实例资源使用情况]/img/top.webp)
>从结果看，脚本运行还是比较成功的

- **不用天天跑很久**。判定标准是 95 百分位，每天 1~2 小时的高负载窗口通常就足够，不会明显影响实例上跑的其他正经业务。
- 脚本首次运行会自动 `apt install stress-ng`，之后不再重复安装。
- 如果实例本身已经有稳定的常驻负载（比如跑着个人网站或博客、Docker 容器等），可以先用 `top` / OCI 控制台的监控图表观察一下实际利用率，如果本身的正常业务能达到一定的负载，也就不需要额外的压力测试。
- 这套方案是为了保住 Always Free 额度内的实例不被误判为"空闲"而设计，压力测试产生的都是真实负载，不涉及任何流量伪造。合理使用免费额度的同时，也别把实例资源占满影响自己其他正常业务。
