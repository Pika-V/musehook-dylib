# 暮色 注入式下载（手动选择版）· TrollFools + dylib

> **这一版不会自动下载任何东西**。
> 播放时只把抓到的播放地址记成「候选」，暮色界面上多一个悬浮球；
> 你点开、勾选、再点「下载选中」，才真正开始下。
> 纯手机操作，不需要电脑、不需要改 App 本体、不需要源码。

---

## 交互长什么样

```
暮色界面右侧  →  🔴 3        ← 悬浮球，数字 = 新候选数（未看的）
                          
点悬浮球      →  列表页「暮色下载」
                 ┌───────────────────────────────┐
                 │ 全选                     下载选中 │
                 │ ───────────────────────────── │
                 │ 标题 A        12:03:41 待选  ✓ │
                 │ 标题 B        12:01:10 下载中 45%│
                 │ 标题 C        11:58:02 ✅ 已完成 │
                 └───────────────────────────────┘
```

| 操作 | 效果 |
|---|---|
| 点某一行 | 勾选 / 取消勾选 |
| 右上「下载选中」 | 只下勾选的条目（可多选） |
| 左上「全选」 | 一键全勾 / 全不勾 |
| 某行左滑 | 移出列表（不删已下好的文件） |
| 状态为「❌ 失败」的行点一下 | 重试该条 |
| 下载中 | 行尾显示进度条 + 百分比 |
| 悬浮球 | 可拖动；数字变红 = 有新候选 |

下载完成落盘：`/var/mobile/Media/暮色下载/<视频名>.ts`（fMP4 则 `.mp4`），同目录还有工作日志 `hook.log`。

---

## 原理

在原生播放器接收数据源时记录播放地址和请求头。

| 入口 | 用途 |
|---|---|
| BetterPlayerPlugin 的 `handleMethodCall:result:` | 读取 Flutter 传给播放器的 `uri`、请求头和标题 |
| FSPlayer 的 `prepareToPlay` / `play` | 记录 FSPlayer 使用的播放地址 |
| AVURLAsset / AVPlayer | 记录 AVFoundation 数据源地址 |

这些入口接收已经准备好的 URL，包括 HTTPS 地址和本机播放代理地址。抓取状态、观察点安装情况和真实日志路径显示在列表页的「诊断」里。

命中后**只入队，不下载**。你在列表里点「下载选中」时，才走真正下载流程：

下载器先识别 HLS 或 MP4。HLS 使用重定向后的播放列表地址解析相对分片，处理 TS / fMP4、字节范围和 AES-128 媒体序号 IV。分片暂存到磁盘并按顺序合并，全部成功后才生成成品。普通 MP4 直接下载到磁盘。成品直接保存在“暮色下载”目录，文件名优先采用候选列表捕获到的模块标题，例如 [LTX]新有菜 黑丝封神之作.mp4。没有明确标题时采用播放地址的视频文件名，例如 MIDV-530-LXT.mp4。临时分块使用 App 临时目录。HTTP 错误、缺分片或不支持的格式会显示失败原因。

UI 把悬浮球直接加到应用现有主窗口，列表使用原生 UIKit 控制器。

---

## 第 1 步：编译（不需要 Mac，手机浏览器就行）

```bash
cd 暮色注入下载-MuseHook
git init && git add . && git commit -m "musehook"
git remote add origin https://github.com/<你>/<仓库>.git
git branch -M main && git push -u origin main
```

手机浏览器打开仓库 → **Actions** → `build-musehook-dylib` → **Run workflow** → 3–5 分钟 →
下载 artifact `MuseHook-dylib` → 解压得到 **`MuseHook.dylib`**。

> 编译命令（workflow 里就是这个）：
> ```bash
> SDK=$(xcrun --sdk iphoneos --show-sdk-path)
> xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -isysroot "$SDK" \
>   -fobjc-arc -dynamiclib -O2 -framework Foundation -framework UIKit -framework CoreGraphics \
>   -o MuseHook.dylib MuseHook.m
> ldid -S MuseHook.dylib
> ```

## 第 2 步：注入

1. TrollStore 里装 **TrollFools**
2. TrollFools → 应用列表选 **暮色** → **注入** → 选 `MuseHook.dylib`
3. 强退暮色，重新打开
4. 界面右侧出现悬浮球（有数字就说明工作正常）

> 撤销：TrollFools 同一界面点「卸载注入」，App 立刻恢复原样。
> 注入属底层钩子，**有崩溃风险**；真崩了就卸载注入，数据不受影响。

## 第 3 步：用

1. 在暮色里播一个视频，**播 2–3 秒就够**（地址一出现就会被记下，不需要看完）
2. 悬浮球数字 +1
3. 点悬浮球 → 勾选你要的 → 「下载选中」
4. 列表里看进度，完成后去 `/var/mobile/Media/暮色下载/` 拿文件（Filza 或「文件」App）

---

## 排查

### One 模块打不开

打开悬浮球 →「诊断」→「检查 One」。诊断显示手机时间、One 登录和游客凭证的本地有效期，并分别检查 One 分类接口，显示 HTTP 状态码和服务器错误信息。检查使用手机现有凭证；报告和日志只显示有效期及 UUID 是否存在，不记录凭证原文。检测最长约 40 秒，可选择后台检查后再打开诊断复制结果。

这是定位 One 认证或网络故障的检查功能，检测结果用于判断需要更新凭证、修正请求或处理网络问题。

### 打开就闪退

上一版（v1）有两个会秒崩的点，v2 已修：

| v1 的问题 | v2 的改法 |
|---|---|
| 早期 socket interpose 版本依赖底层符号替换 | 当前观察已核对的 Objective-C 播放器方法，保存并调用原方法 |
| `__attribute__((constructor))` 里就建 ObjC 对象、读写文件、起 UIKit | constructor 只做一件事：把初始化 `dispatch_after(0.6s)` 丢到主队列；对象创建、日志、UI 全在 `muse_bootstrap()` 里，外层 `@try/@catch` |
| 播放地址在 HTTPS 或解析链路中变化 | 在播放器的数据源入口读取明文 URL 和请求头 |

**救命开关**：Filza 里建一个空文件

```
/var/mobile/Media/暮色下载/disable
```

存在这个文件时 dylib 完全不工作（不挂钩逻辑、不建 UI），App 恢复原样——不用卸载注入也能救急。删掉文件后重启 App 即恢复正常。

### 界面点不动 / 触摸全失效

悬浮球现在是应用现有主窗口中的 56×56 按钮。列表由应用现有控制器弹出，点击「关闭」后恢复悬浮球，拖动范围限制在可见区域内。

### 其它现象

| 现象 | 处理 |
|---|---|
| 没有悬浮球，但 App 能开 | 看 `hook.log` 有没有「MuseHook 已注入」；没有就说明 bootstrap 没跑起来，检查是否有 `disable` 文件 |
| 悬浮球在，但列表一直空 | 播放视频后点列表右上角「诊断」，复制观察点、播放器调用、播放地址和真实日志路径 |
| 有候选，下载失败 | 查看「诊断」里的下载错误。播放器传入的请求头会用于下载请求，缺分片或 HTTP 错误会明确报错 |
| 标题都是「候选 N」 | 该接口 JSON 里没有 `title` 字段；不影响下载 |
| 下载到一半 App 被杀 | 本次下载未完成，重新选择下载；成品会在全部成功后发布 |

### 还是要看崩溃日志

- 手机：设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 找文件名以 `暮色` 或 `Runner` 开头的 `.ips`
- 或 Filza 进 `/var/mobile/Library/Logs/CrashReporter/`

把 `.ips` 里 `Exception Type` / `Termination Reason` / 第一个 `MuseHook` 帧发我，就能直接定位。

---

## 文件

```
暮色注入下载-MuseHook/
├── MuseHook.m                          # 全部逻辑（ObjC，单文件）
├── .github/workflows/build-dylib.yml   # 云端 macOS 编译 → 出 dylib
└── README.md
```

依赖系统提供的 Foundation、UIKit、CoreGraphics、CommonCrypto 和 Objective-C runtime。
