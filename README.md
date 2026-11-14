# DockFixator

把 Dock 钉死在主屏上，再也不会被副屏边缘"勾走"。

- 原生 Swift，无第三方依赖，CPU 占用可以忽略
- 菜单栏常驻，不占 Dock、不占程序坞图标
- 通用二进制（Intel + Apple Silicon），最低 macOS 14.0
- 自动适配 Dock 停在底部 / 左侧 / 右侧

---

## 它在解决什么问题

macOS 打开「显示器具有单独的空间」之后，Dock 可以在所有显示器上使用：

> 此选项打开时，程序坞在所有显示器上都可用；关闭时，程序坞仅显示在主显示器上。
> —— Apple 支持文档

代价是 Dock 会跟着鼠标跑：只要指针碰到**副屏的 Dock 边缘**（Dock 在底部时是屏幕下边缘，
在左右时是左右边缘），Dock 就会立刻搬到那块屏上去。macOS 没有提供"把 Dock 锁定在某块屏幕"
的开关，第三方的 DockAnchor 之类的工具又常常因为最低系统版本或 CPU 架构限制，在 macOS 14.4
的老 Intel iMac 上根本打不开。

DockFixator 就是干这件事的。

## 工作原理

| 层次 | 机制 | 作用 |
| --- | --- | --- |
| ① 主动防御 | `CGEventTap`（`.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap`） | 把"落在非目标屏 Dock 触发带内的 `mouseMoved`"直接丢弃。窗口服务器和 Dock 都收不到这次移动，等价于鼠标从未碰到那片边缘，Dock 不会迁移。**只丢事件，绝不挪动光标**——光标该怎么走还怎么走。 |
| ② 自动归位 | 合成 `mouseMoved` 事件流 | 万一 Dock 还是跑到别的屏了，模拟一次"从远处滑到目标屏边缘"的动作，把它拽回来，然后还原光标位置。只在用户停手 ≥0.8 秒时才会动手。 |
| ③ 强力兜底 | `killall Dock` | 合成事件在某些系统版本上可能推不动 Dock（Dock 不理会非硬件事件），此时按需重启 Dock 进程。默认关闭，会闪 1~2 秒。 |

触发带宽度默认 **8pt**，可在菜单里调（4 / 6 / 8 / 10 / 12 / 16）。触发带取的是 Dock
当前停靠边——程序每秒重读一次 `com.apple.dock` 的 `orientation`，你把 Dock 改到左右两侧也会自动适配。

## 构建

```bash
cd DockFixator
./build.sh              # 产出 build/DockFixator.app
./build.sh --install    # 构建并安装到 /Applications（推荐）
```

只依赖 Xcode Command Line Tools（`xcode-select --install`）。脚本会分别编译 `arm64` 与
`x86_64` 再 `lipo` 合成通用二进制，并做 ad-hoc 签名。

## 首次使用

1. 用 `./build.sh --install`，或者手动把 `build/DockFixator.app` 拖到 **/Applications**。
   （放在固定位置很重要：辅助功能授权是按 App 路径 + 签名记账的。）
2. 双击运行，菜单栏会出现一个图钉图标，此时通常会自动弹出授权提示。
3. 打开 系统设置 → 隐私与安全性 → **辅助功能**，勾选 `DockFixator`。
   如果没有弹出提示，点菜单里的「辅助功能权限：未授权（点击前往设置）」。
4. 回到菜单栏图标，状态变成「✅ Dock 已锁定在 XXX」就生效了。

> 授权后**不需要**重启 App：程序每秒检查一次授权状态，勾上就自动接管。

## 菜单说明

| 菜单项 | 说明 |
| --- | --- |
| 把 Dock 固定在 | 选择目标显示器，默认跟随系统主显示器（菜单栏所在那块） |
| 边缘触发宽度 | 拦截带的宽度，默认 8pt。误伤到底部贴边控件就调小 |
| 启用边缘防护 | 总开关 |
| 同时拦截拖拽事件 | 连 `mouseDragged` 一起拦，默认关闭（拖东西到边缘一般不会换屏） |
| Dock 跑走时自动拉回 | 检测到 Dock 不在目标屏时用合成事件拉回来，默认开启 |
| 强力兜底：拉不回时重启 Dock | 连续 3 次拉不回来时重启 Dock 进程，默认关闭 |
| 立即把 Dock 拉回目标屏 | 手动触发一次归位（⌘R） |
| 重启 Dock 进程 | 手动重启 Dock，冷却 10 秒 |
| 登录时自动启动 | 优先用系统登录项（`SMAppService`），失败退回 `~/Library/LaunchAgents` 的 plist |

## 诊断

```bash
/Applications/DockFixator.app/Contents/MacOS/DockFixator --selftest
```

会打印当前所有显示器、Dock 归属、停靠边、目标屏、授权状态，以及每块副屏上被保护的具体矩形。
排查"为什么没生效"时先看这个，不会弹权限框。

## 已知限制

- **必须授予辅助功能权限。** 这是 `CGEventTap` 能丢弃事件的前提，没有权限只能看不能管。
- 触发带内的 `mouseMoved` 会被吞掉，所以紧贴屏幕边缘 8pt 的悬停类 UI（例如某些视频进度条）
  在那一条里收不到悬停事件。点击、拖拽、滚动都不受影响，宽度也可以调到 4pt。
  注意这不影响**光标本身**的移动：光标永远可以正常穿过接缝、穿过那 8pt。
- 合成事件能否真正推动 Dock，取决于系统版本；若完全无效请打开「强力兜底」。
- 重新编译后签名变化，辅助功能里可能需要取消勾选再重新勾选一次（ad-hoc 签名的固有行为）。
- 只处理 Dock 在底部 / 左侧 / 右侧三种停靠方式，macOS 也不支持其它停靠位置。

## 卸载

菜单里关掉「登录时自动启动」→ 退出 DockFixator → 删除 `DockFixator.app` →
可选：在 系统设置 → 隐私与安全性 → 辅助功能 里移除残留条目。

配置保存在 `~/Library/Preferences/com.jansonhe.dockfixator.plist`，一并删除即可。

## 目录结构

```
DockFixator/
├── build.sh                      # 构建脚本（通用二进制 + App Bundle + ad-hoc 签名）
├── Resources/Info.plist
└── Sources/DockFixator/
    ├── main.swift                # 入口（含 --selftest）
    ├── AppDelegate.swift         # 菜单栏、调度、自动归位
    ├── EdgeGuard.swift           # 核心：CGEventTap 边缘拦截
    ├── DockGeometry.swift        # 触发带/触发点几何计算
    ├── DockLocator.swift         # 判断 Dock 在哪块屏（按 PID 取 layer=20 窗口）
    ├── DockRelocator.swift       # 合成事件把 Dock 拉回目标屏
    ├── DockProcess.swift         # 强力兜底：重启 Dock
    ├── DisplayCenter.swift       # 显示器枚举与热插拔
    ├── Settings.swift            # 配置持久化
    ├── LoginItem.swift           # 开机自启
    ├── Permissions.swift         # 辅助功能权限
    └── SelfTest.swift            # --selftest 诊断输出
```

## 变更记录

### 1.0.1

**修复：Dock 在左侧时，光标移到副屏左边缘会被"吸附"卡住、猛甩才能挣脱。**

原因是 1.0.0 在拦截事件之外，还会用 `CGWarpMouseCursorPosition` 把光标"顶出"触发带。
当副屏左边缘正好是与主屏的接缝时，每次往左走都被推回 8pt，物理位移与虚拟光标位置的差值
越滚越大，等于在接缝上砌了一堵墙。现在**彻底移除光标干预**，只丢弃事件；同时给自动归位加上
"用户停手 0.8 秒才动手 / 8 秒冷却 / 迁移超过 2 秒强制解除"三重保险。

### 1.0.0

首个版本。
