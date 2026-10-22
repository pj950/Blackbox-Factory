# 资产与依赖来源

日期：2026-10-22。此表记录开发来源，不替代最终发行许可审核，也不为本项目代码指定开源许可证。

| 内容 | 来源与用途 | 当前许可处理 |
| --- | --- | --- |
| Godot 4.7.2 标准版 | 官方下载及 godotengine/godot-builds 官方发布；本地开发和测试 | Godot 为 MIT；便携工具不提交到项目。正式导出游戏前附带适用的引擎版权、许可及第三方声明 |
| 建筑及工具图集 | [factory_tiles.svg](../game/assets/factory_tiles.svg)，本项目新绘制的临时像素矢量图集，含 M3 保存、加载和维修图标 | 未复制其他游戏素材，未引用外部图片；目前为原型资源，正式美术仍待设计和审核 |
| 字体 | 通过 Godot SystemFont 请求本机 Bahnschrift、Segoe UI，缺失时由引擎回退 | 未复制或分发字体文件；若后续嵌入字体，需另选明确可商业分发的字体并记录许可 |
| 音效与音乐 | 尚未引入 | 无 |
| 第三方插件、测试框架 | 尚未引入，测试使用 Godot SceneTree 脚本 | 无新增依赖 |

核验入口：

- Godot 许可说明：https://godotengine.org/license/
- 引擎及第三方版权说明：https://github.com/godotengine/godot/blob/4.7.2-stable/COPYRIGHT.txt
- Windows 下载：https://godotengine.org/download/windows/
- 本次发布校验和：https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/SHA512-SUMS.txt

正式发行前仍需检查导出模板、Steam 分发要求、所有新增资产和插件；当前未生成或发布游戏安装包。