# Instant Notes

一键调起 iPhone 摄像头拍照，照片直接保存到**当前编辑文件所在的文件夹**；如果是 HEIC/HEIF，自动转换为 JPEG（保留 EXIF、GPS、方向信息）。

## 用法

| 方式 | 说明 |
| --- | --- |
| `⌘⌥P` | 用 iPhone 拍照 |
| 编辑器右上角 📷 按钮 | 同上 |
| 资源管理器右键 →「用 iPhone 拍照」 | 保存到右键的那个文件夹 |
| 命令面板 →「用 iPhone 立即拍照（网络摄像头模式）」 | 不碰手机，直接用 iPhone 镜头拍一张 |
| 资源管理器右键 .heic →「HEIC 转 JPEG」 | 转换已有文件 |

**拍照模式（默认）**：按下快捷键后 iPhone 上会直接打开相机，按快门后点「使用照片」即可，不需要在 Mac 上选菜单。
有多台设备时，用 `instantNotes.deviceName` 指定要用哪一台（如 `iPhone`）。首次使用时 macOS 可能会询问是否允许 Cursor/VS Code 控制「iPhone 拍照」，请点允许。
如果当前是 Markdown 文件，会在光标处自动插入 Markdown 图片链接。

## 要求

- macOS 14+，iPhone 与 Mac 登录同一 Apple ID，开启 Wi-Fi 和蓝牙（连续互通相机）
- 网络摄像头模式需要 iPhone 锁屏、横放/固定，且首次使用时允许 VS Code 访问摄像头

## 设置

`instantNotes.deviceName`、`jpegQuality`、`keepOriginalHeic`、`fileNamePattern`（`${date}` `${time}` `${fileBasename}`）、`subfolder`、`insertMarkdownLink`、`timeoutSeconds`

## 重新编译原生 helper

```bash
npm run build-native   # 生成 bin/IPhoneCapture.app
```
