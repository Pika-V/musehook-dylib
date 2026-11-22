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

下载完成落盘：`/var/mobile/Media/暮色下载/<标题>/<标题>.ts`（fMP4 则 `.mp4`），同目录还有工作日志 `hook.log`。

---

## 原理

暮色接口是明文 `http://IP:6868`，Flutter(dart:io) 走 BSD socket。dylib 用 dyld `__interpose` 挂钩四个符号：

| 挂钩 | 作用 |
|---|---|
| `send` / `write` | 看请求行，定位当前连接 |
| `recv` / `read` | 扫响应体里的 `.m3u8`，顺手把同一个 JSON 里的 `"title"` 捞出来当标题 |

命中后**只入队，不下载**。你在列表里点「下载选中」时，才走真正下载流程：

拉 playlist → master 自动选最高码率 → 解析 TS / fMP4（`EXT-X-MAP`、`EXT-X-BYTERANGE`）→
`AES-128` 自动抓 key 用 CommonCrypto 解密（无 IV 时按 HLS 规范用分片序号）→ 6 并发 + 3 次重试 → 顺序合并成单文件。

UI 是自己建的 `UIWindow`（`windowLevel = Alert+100`，背景透明），盖在 Flutter 渲染层之上，所以不需要动 App 本体。

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
>   -fobjc-arc -dynamiclib -O2 -framework Foundation -framework UIKit \
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

### 打开就闪退

上一版（v1）有两个会秒崩的点，v2 已修：

| v1 的问题 | v2 的改法 |
|---|---|
| `dlsym(RTLD_NEXT, "send")` 在 interpose 场景下会返回 NULL → 空指针调用 | **完全不 dlsym**：只 interpose `send`/`recv`，内部改用 `sendto`/`recvfrom` 调原始实现（这两个符号没被挂钩，直接落到 libsystem） |
| `__attribute__((constructor))` 里就建 ObjC 对象、读写文件、起 UIKit | constructor 只做一件事：把初始化 `dispatch_after(0.6s)` 丢到主队列；对象创建、日志、UI 全在 `muse_bootstrap()` 里，外层 `@try/@catch` |
| 额外隐患：同时挂钩 `read`/`write` 会影响 App 所有文件 IO | 只挂 `send`/`recv`（socket 专用），不干扰文件读写 |

**救命开关**：Filza 里建一个空文件

```
/var/mobile/Media/暮色下载/disable
```

存在这个文件时 dylib 完全不工作（不挂钩逻辑、不建 UI），App 恢复原样——不用卸载注入也能救急。删掉文件后重启 App 即恢复正常。

### 界面点不动 / 触摸全失效

v3 已修。原因是悬浮球挂在了一个**全屏透明 window** 上，而那个 window 会把所有触摸吞掉（Flutter 界面在它下面）。

修法：根视图换成 `MusePassthroughView`，重写 `hitTest:withEvent:`——点到悬浮球才响应，点到空白 `return nil` 把事件让给下层 window（也就是 Flutter）。同时给列表页补了「关闭」按钮（之前点进去出不来）。

### 其它现象

| 现象 | 处理 |
|---|---|
| 没有悬浮球，但 App 能开 | 看 `hook.log` 有没有「MuseHook 已注入」；没有就说明 bootstrap 没跑起来，检查是否有 `disable` 文件 |
| 悬浮球在，但列表一直空 | interpose 没命中 Flutter 的 socket。退而求其次：完整播一遍 → Filza 进暮色沙盒 `Library/Caches/` 按时间取分片 |
| 有候选，下载全失败 | 分片在 https CDN 上需要 Referer/Token。在 `MuseHook.m` 的 `HTTPAdditionalHeaders` 里补上 Referer 再编一次 |
| 标题都是「候选 N」 | 该接口 JSON 里没有 `title` 字段；不影响下载 |
| 下载到一半 App 被杀 | 已下分片在内存里，未落盘，重下即可 |

### 还是要看崩溃日志

- 手机：设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 找文件名以 `暮色` 或 `Runner` 开头的 `.ips`
- 或 Filza 进 `/var/mobile/Library/Logs/CrashReporter/`

把 `.ips` 里 `Exception Type` / `Termination Reason` / 第一个 `MuseHook` 帧发我，就能直接定位。

---

## 文件

```
暮色注入下载-MuseHook/
├── MuseHook.m                          # 全部逻辑（约 770 行 ObjC，单文件）
├── .github/workflows/build-dylib.yml   # 云端 macOS 编译 → 出 dylib
└── README.md
```

零第三方依赖（Foundation + UIKit + CommonCrypto）。
