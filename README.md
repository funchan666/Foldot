# PulsePlayer

PulsePlayer 是一款原生 SwiftUI 趣味折纸 App。打开 `PulsePlayer.xcodeproj`，选择共享 Scheme `PulsePlayer`。工程使用 iOS 27.1 SDK 的容器布局 API，最低支持 iOS 17。iOS 26 及以上的关键控件使用 Liquid Glass。

首次安装默认使用英文。在设置的 “App language” 中可以手动选语言，也可以选择 “Follow system”。支持的语言与 Swevo 一致，包括英语、韩语、日语、印尼语、葡萄牙语、阿拉伯语和西班牙语。跟随系统时，如果首选语言不在这七种之内，界面会显示英文。

## 跟着视频逐折练习

1. 首页的纸鹤课内置九个按影片时间标好的步骤。可以从头折，也可以从课程目录点进某一步。自己的视频支持从链接、短码、照片或文件打开。
2. 在新折法开始时点 **Mark this fold**。可以给步骤起名、设置循环终点或撤销标记。**Play folds hands-free** 会从选中的这一折开始，每折放一至三遍，最后一折结束时暂停。
3. 练习进度保存在本机。首页可从上次那一折继续，资料库的 **Marked folds** 支持按视频名、折法名或时间查找，点中结果会跳到相应位置。
4. 在 **Fold workbench** 选择本地视频的一折，可以叠看首尾两帧、对照纸边。剪辑时也可以直接用折法的起止点设置裁剪范围，再调整速度、画幅或声音。
5. 练习笔记支持导出步骤时间表 CSV。Plus 会员还可以把单独一折导出为 MP4，保存到资料库或分享。

内置课和已导入的视频可离线练习。资料库同时提供本地文件夹、收藏、离线下载和剪辑工具。编辑器支持裁剪、变速、旋转、镜像、提取音频和三个关键帧的对比。媒体导出使用服务端验证的 Plus 权益。

## 测试配置

Debug 和 Release 均使用 `Config/PulsePlayer.xcconfig`。业务 API 主机为 `devapi.io-jp.com`，安装标识、游客来源和业务包名均为 `im.seex.lobo`，版本为 `1.0.0`，`getV2.name` 为 `PulsePlayer`。此测试 Bundle ID 与工具包的其他测试包共用，同机安装会替换已有的同标识 App。

开屏及激励广告使用 Google 官方演示配置。月付商品为 `coins_1.99`，年付为 `conis_4.99`，配置位于 `PulsePlayer/Resources/Commerce.json`。实际付款页显示 Apple 返回的商品价格和周期。官网与协议保留测试占位。用户确认测试通过后再收集并切换正式配置。

手动联调时在首页输入工具包测试短码 `2DhdI8`。在线课程由后台实际返回。首屏的纸鹤教学独立随包提供，可用来验证逐折练习。

## 课程署名

内置纸鹤课程为 Tavin 于 2010 年拍摄的《OrigamiCrane》。PulsePlayer 将完整影片转码为 H.264/AAC，并从片尾提取、调亮封面帧。课程页保留署名、原片及许可链接。[原片](https://commons.wikimedia.org/wiki/File:OrigamiCrane.ogv) · [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)
