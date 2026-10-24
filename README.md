# Stash Mobile（iOS）

Stash 素材库的 iPhone 客户端。**不经过任何云端**：手机直连你电脑上跑着的 `http://<ip>:5273`，
浏览、搜索、看原图，以及把相册里的照片视频存进电脑的库里。

- 原生 SwiftUI，仅 iPhone（iOS 17+）
- 个人签名侧载（Sideloadly + 免费 Apple ID），不上架 App Store
- 后端就是桌面端的 `electron/services/remote.ts`，本仓库只是客户端

---

## 它做什么 / 不做什么

| 做 | 不做 |
|---|---|
| 浏览素材（网格 / 目录 / 标签 / 搜索） | 删除、改名、打标签、改评分 |
| 全屏查看图片（缩放/翻页）、播放视频 | 全量双向镜像同步 |
| 保存原图/视频到系统相册 | 后台上传（退到后台会暂停） |
| **把手机相册的照片视频存进电脑库**，带断点续传与内容去重 | 分享扩展、Widget、推送 |

「同步」在这里被拆成三件事：**上传（手机→电脑）+ 浏览 + 按需下载**。
不做全量镜像是有意的——iOS 的后台执行限制 + 免费签名不支持推送，会让「两边永远一致」
变成一个永远修不完的坑，而收益只是「在地铁里也能看缩略图」。

---

## 目录

```
project.yml               XcodeGen 工程定义（仓库里不存 .xcodeproj）
Sources/
  StashMobileApp.swift    入口 + RootView + 配色 token
  Models.swift            与服务端 JSON 对齐的数据模型
  Keychain.swift          token 存储
  Net/APIClient.swift     所有 HTTP 调用
  Store/AppModel.swift    ConnectionStore（配对/连接）+ LibraryStore（列表/分页）
  Upload/UploadQueue.swift HEIC→JPEG 转码 + 分段上传队列
  Cache/ThumbCache.swift  缩略图 内存+磁盘 两级缓存
  UI/                     连接页 / 素材页 / 查看器 / 设置 / 传输列表 / 相册选择器
Resources/Info.plist      ATS、本地网络、相册写入权限说明
.github/workflows/ios.yml 云端编译出未签名 ipa
```

---

## 构建（Windows 也能跑通）

iOS 二进制**只能**在 macOS 上编译，Windows 上没有 `xcodebuild`。
所以分工是：**云端编译 → 本地签名**。

```bash
# 1. 推到 GitHub（公开仓库跑 macOS runner 不占私有额度）
git init && git add -A && git commit -m "init"
gh repo create stash-mobile --public --source=. --push

# 2. 等 Action 跑完（约 3–5 分钟），下载产物 Stash-ipa.zip
gh run watch
gh run download --name Stash-ipa
```

> 首次跑 workflow 若报 `xcodegen: command not found`，是 brew 装在了 runner 上但 PATH 没刷新；
> 重跑一次即可（workflow 里已按顺序安装）。

---

## 安装与签名

1. iPhone 用数据线连电脑，解锁，点「信任此电脑」
2. 打开 [Sideloadly](https://sideloadly.io/)，把 `Stash.ipa` 拖进去
3. Apple ID 填你的免费账号 → Start
4. iPhone：设置 → 通用 → VPN与设备管理 → 信任该开发者
5. iPhone：设置 → 隐私与安全性 → **开发者模式** → 开启 → 重启
   （iOS 16+ 必须；不开的话 App 点开就闪退，且没有任何提示）

**7 天有效期**：免费证书 7 天后失效，App 会提示「无法验证」。重签同一个 Bundle ID 即可，
**App 内数据（含 Keychain 里的配对凭据）不会丢**，不用重新配对。

三种应对：

| 方式 | 成本 | 说明 |
|---|---|---|
| 手动 Sideloadly 重签 | 每周约 3 分钟 | 最稳，推荐先用这个 |
| SideStore / AltStore 自动续签 | 一次性折腾 | 需要先用 `jitterbugpair` 在 Windows 导出配对文件，之后设备上自动重签 |
| 接受失效 | 0 | 只在偶尔用的时候重签 |

---

## 连电脑

1. 电脑端 Stash → 设置 → 手机访问 → 打开
2. 记下地址（`192.168.x.x:5273`，异地用 Tailscale 的 `100.x`）和 6 位配对码
3. App 里填地址 + 配对码 → 连接

首次连接会弹「本地网络」权限，必须允许，否则连不上局域网。

---

## 上传协议

三段式，支持断点续传（视频动辄几百 MB，整段重传不可接受）：

```
POST /api/upload/begin  {name,size,folderId?}   → {uploadId, offset, name}
PUT  /api/upload/:id?offset=N   (裸字节)         → {received, size}
POST /api/upload/:id/commit                      → {assetId, name, deduped, renamed}
DELETE /api/upload/:id                           → 取消
```

两个容易踩的点，客户端和服务端都做了处理：

- **重放幂等**：断线重连时客户端会从「上次确认的 offset」重放同一段。服务端收到 `offset < received`
  会先 `truncate` 再写，所以重放不会把文件变成「前段+前段+后段」。
- **去重**：`commit` 时先算 `content_hash`，命中已有素材直接返回那条（`deduped: true`），
  连一次拷贝都不做。同一张照片传十次，库里也只有一份。

**HEIC 必须先在手机上转 JPEG**：桌面端预编译的 sharp 不带 HEVC 解码器，
HEIC 传过去会「导入成功但永远没有缩略图」——比拒收更糟。`UploadQueue` 在入队时会判扩展名自动转码，
并把 EXIF 方向烤进像素（否则竖拍照片在电脑上是躺倒的）。

---

## 已知限制

- 上传**只在 App 前台**推进；退到后台会给一段宽限期，之后暂停，下次打开继续（不会丢，会从断点续传）
- 网格是正方形格子，不是桌面端那种瀑布流（瀑布流要自己写 layout，收益不抵复杂度）
- 不全量镜像：断网时只能看已经缓存过的缩略图
- 不做分享扩展：免费签名不支持 App Groups，扩展拿不到 token，得单独再配对一次
- 不含 App 图标（`Assets.xcassets` 未提供），系统会显示默认空白图标
