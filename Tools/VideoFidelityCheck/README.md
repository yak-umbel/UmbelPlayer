# 视频格式与动态元数据传递验证

此命令使用真实本地媒体核对 RPU NAL 存在、文件散列、实际播放路由与高位深缓冲传递。
显示层没有挂到可见窗口，结果不证明最终显示映射或画中画的动态效果。

```sh
Tools/swift.sh run umbel-video-fidelity-check --manifest tmp/video-fidelity/samples.json --report tmp/video-fidelity/report.json
```

清单 JSON 使用 `schemaVersion: 1` 与非空 `samples` 数组。每项必须给出中性 `id`、本地 `path`、
实际 `sha256` 和非空 `license` 说明；清单、原始媒体和报告放项目 `tmp/`，不入库。
命令拒绝空清单、散列不符、缺少许可说明或找不到实际 RPU 的样片。
仓库的配置型 DV 测试片不属于动态效果样片，不能替代此验证。

输出的 `submittedToSystem` 只表示已交付显示层。`effectValidated` 与画中画效果验收始终为 false；
真实显示验收须另记录设备、系统、显示环境、受控对照和观察方法。P8.1 与 P8.4 各有自己的能力属性，目前条件相同（系统硬解 DV）；P8.1 的资格不是借用 P8.4 的结果，也不代表其效果已验收。
