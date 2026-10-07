# bob-plugin-local-ocr

[Bob](https://bobtranslate.com/) 的离线 OCR 插件。识别交给一个运行在本机、沙盒外的小服务，用的是 macOS 自带的 Vision 框架。专门用来解决 **macOS 27 上 Bob 自带的「系统 OCR」每次都要等几十秒甚至一分多钟** 的问题。

- 完全离线：图片只在本机的 `127.0.0.1` 上传递，不经过任何网络服务
- 识别速度：通常 0.1~0.3 秒，满屏密集文字约 1 秒
- 支持文字坐标，可以配合 Bob 的「图片翻译」使用

## 为什么 Bob 的系统 OCR 在 macOS 27 上这么慢

Vision 识别文字时，用的模型要先在神经网络引擎（ANE）上编译。每个模型编译一次大约 20~50 秒，正常情况下编译结果会缓存在 `~/Library/Caches/<程序名>/com.apple.e5rt.e5bundlecache/` 里，之后再用就很快。

macOS 27 上，沙盒 App（Bob 是 Mac App Store 版本，运行在沙盒里）写不进这个缓存，Bob 的日志里能看到这样的错误：

```
e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)
```

错误码 13 就是 `EACCES`（权限被拒）。缓存存不下来，Bob 只能每次都从头编译，于是每次识别都要等 30~100 秒。Bob 1.21.1 加了一个子进程通道来绕开这个错误，但编译还是经常要重来，所以表现为「时好时坏」。

这个插件的思路是：让一个**不在沙盒里**的常驻小服务来调用 Vision。它可以正常写缓存，模型只需要编译一次，之后一直很快。Bob 插件只负责把截图发给这个服务。

```
Bob 截图 ──▶ 本地 OCR 插件 ──HTTP──▶ bob-local-ocr 服务 (127.0.0.1:50888) ──▶ Vision
```

## 环境要求

- macOS 13 或更高版本（主要为 macOS 27 准备，在 macOS 27.0.1 / Apple M2 Pro 上测试过）
- Bob 1.20.0 或更高版本
- Xcode 命令行工具（用来编译服务，不需要完整的 Xcode）

> Intel Mac 没有 ANE，Vision 会改用 CPU/GPU。理论上能用，但没有测试过。

## 安装

### 第 1 步：安装命令行工具

已经装过 Xcode 或命令行工具的可以跳过。在终端运行下面的命令，然后在弹出窗口里点「安装」：

```bash
xcode-select --install
```

### 第 2 步：安装本地 OCR 服务

```bash
git clone https://github.com/kikohz/bob-plugin-local-ocr.git
cd bob-plugin-local-ocr
./install.sh
```

脚本会编译服务，并注册成登录后自动运行的后台服务（LaunchAgent）。看到 `服务已启动` 就说明装好了。

**第一次安装后，服务需要在后台编译 OCR 模型，大约 1~2 分钟。** 可以用下面的命令看进度，出现 `预热完成` 就可以用了：

```bash
tail -f ~/Library/Logs/bob-local-ocr.log
```

```
[...] 监听 127.0.0.1:50888
[...] 预热 zh-Hans，耗时 52460ms
[...] 预热 en-US，耗时 108ms
[...] 预热 ja-JP，耗时 219ms
[...] 预热 ru-RU，耗时 47ms
[...] 预热 ar-SA，耗时 31210ms
[...] 预热 hi-IN，耗时 23094ms
[...] 预热完成，总耗时 107301ms
```

模型编译好以后会一直缓存，之后服务重启时预热不到 1 秒。

### 第 3 步：安装 Bob 插件

到 [Releases](https://github.com/kikohz/bob-plugin-local-ocr/releases/latest) 下载最新的 `.bobplugin` 文件，双击安装。

### 第 4 步：在 Bob 里启用

1. 打开 Bob 偏好设置 → **服务** → **文本识别**
2. 点左下角的 **+**，添加 **「本地 OCR」**
3. 把「本地 OCR」**拖到第一位**。原来的「系统 OCR」可以停用，以免它拖慢速度
4. 点 **验证**，显示成功说明插件已经连上本地服务

完成以后，用 Bob 的截图 OCR 或截图翻译试一下。

## 常见问题

### 点「验证」失败，或者提示「无法连接本地 OCR 服务」

先确认服务在运行：

```bash
curl http://127.0.0.1:50888/health        # 应该返回 {"ok":true}
launchctl print gui/$(id -u)/com.kikohz.bob-local-ocr | grep state
```

如果没有在运行，查看日志 `~/Library/Logs/bob-local-ocr.log`，或者重新运行 `./install.sh`。

### 偶尔还是会慢一次

Vision 按文字体系使用不同的模型。服务启动时会把中、英、日、韩、俄、泰、阿拉伯、印地这几类文字都预热一遍。如果截图里是其他文字，第一次用到时可能还要编译一次（20~50 秒），之后就快了。

另外，**每次升级 macOS 之后缓存都会失效**，服务第一次启动时会自动重新编译。这 1~2 分钟里截图会慢，等日志里出现 `预热完成` 就恢复正常。

### 端口 50888 被占用了

换一个端口重新安装，然后在 Bob 的插件设置里把「服务端口」改成同样的值：

```bash
BOB_OCR_PORT=50889 ./install.sh
```

### 服务会占用多少资源

空闲时内存约 90 MB，CPU 占用为 0。只有收到识别请求时才会工作。

### 安全吗

服务只监听 `127.0.0.1`，外部网络访问不到。不过本机上的其他程序也能调用它，用法和插件一样，都是发截图过去拿识别结果。

## 更新

```bash
cd bob-plugin-local-ocr
git pull
./install.sh
```

插件会在 Bob 里自动提示更新。

## 卸载

```bash
cd bob-plugin-local-ocr
./install.sh uninstall
```

这会删除后台服务和模型缓存。插件请在 Bob 偏好设置 → **插件** 里删除。

## 接口说明

服务本身是一个很小的 HTTP 接口，也可以给其他工具用：

```bash
# 识别图片
curl -X POST http://127.0.0.1:50888/ocr \
  -H 'Content-Type: application/json' \
  -d "{\"image\":\"$(base64 -i screenshot.png)\",\"languages\":[\"zh-Hans\",\"en-US\"],\"autoDetect\":true}"
```

```json
{
  "texts": [{ "text": "识别出的一行文字", "box": { "x": 0.02, "y": 0.35, "w": 0.7, "h": 0.37 } }],
  "elapsedMs": 93
}
```

`box` 是归一化坐标（0~1），原点在左上角。

## 项目结构

| 路径                  | 说明                                                        |
| --------------------- | ----------------------------------------------------------- |
| `server/main.swift`   | 本地 OCR 服务（Network.framework + Vision，没有第三方依赖） |
| `plugin/`             | Bob 插件源码                                                |
| `install.sh`          | 编译、安装、卸载服务                                        |
| `scripts/release.mjs` | 打包插件并更新 `appcast.json`                               |
| `appcast.json`        | Bob 插件自动更新信息                                        |

## 发布新版本（维护者）

1. 修改 `plugin/info.json` 里的 `version`
2. 运行 `node scripts/release.mjs "更新说明"`
3. 提交并推送，然后按脚本输出的 `gh release create ...` 命令发布

## License

[MIT](LICENSE)
