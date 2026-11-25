# PulsePlayer

PulsePlayer 是一款原生 SwiftUI 趣味折纸 App。打开 `PulsePlayer.xcodeproj`，选择共享 Scheme `PulsePlayer`。工程使用 iOS 27.1 SDK 的容器布局 API，最低支持 iOS 17。iOS 26 及以上的关键控件使用 Liquid Glass。

首次安装默认使用英文。在设置的 “App language” 中可以手动选语言，也可以选择 “Follow system”。支持的语言与 Swevo 一致，包括英语、韩语、日语、印尼语、葡萄牙语、阿拉伯语和西班牙语。跟随系统时，如果首选语言不在这七种之内，界面会显示英文。

## 跟着视频逐折练习

1. 在 **Search** 中输入链接或短码、浏览在线课程，或从照片和文件导入自己的折纸视频。首次打开时，资料库和练习笔记显示空状态。
2. 在新折法开始时点 **Mark this fold**。可以给步骤起名、设置循环终点或撤销标记。**Play folds hands-free** 会从选中的这一折开始，每折放一至三遍，最后一折结束时暂停。
3. 练习进度保存在本机。**Search** 页可从上次那一折继续，资料库的 **Marked folds** 支持按视频名、折法名或时间查找，点中结果会跳到相应位置。
4. 在 **Fold workbench** 选择本地视频的一折，可以叠看首尾两帧、对照纸边。剪辑时也可以直接用折法的起止点设置裁剪范围，再调整速度、画幅或声音。
5. 练习笔记可以免费导出步骤时间表 CSV，也可以将单独一折存为 MP4 并分享。

已导入或下载的视频可离线练习。资料库提供本地文件夹、收藏和剪辑工具。裁剪、变速、旋转、镜像、提取音频、关键帧对比及导出分享均免费。Plus 提供不限每日次数的在线视频观看和下载，以及免开屏广告。

## 测试配置

Debug 和 Release 均使用 `Config/PulsePlayer.xcconfig`。业务 API 主机为 `devapi.io-jp.com`，安装标识、游客来源和业务包名均为 `im.seex.lobo`，版本为 `1.0.0`，`getV2.name` 为 `PulsePlayer`。此测试 Bundle ID 与工具包的其他测试包共用，同机安装会替换已有的同标识 App。

开屏及激励广告使用 Google 官方演示配置。测试商品为 `coins_1.99` 和 `conis_4.99`，配置位于 `PulsePlayer/Resources/Commerce.json`。实际付款页显示 Apple 返回的商品价格和周期。官网与协议保留测试占位。用户确认测试通过后再收集并切换正式配置。

手动联调时在 **Search** 页输入工具包测试短码 `2DhdI8`。可以用返回的真实课程或自己导入的视频核对标记、循环和续播。
