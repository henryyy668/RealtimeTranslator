# RealtimeTranslator 耳机实时翻译 v2

一副 AirPods 两人分用的中英实时对话翻译 App。你戴左耳、朋友戴右耳,对着手机自然说话,系统自动判断这句是中文还是英文,翻译后只把译文送进对方那只耳朵。

v2 内置两套引擎,设置里一键切换:

| | 端上引擎(v1) | 云端引擎(v2 新增) |
|---|---|---|
| 识别 | 苹果 SFSpeech 双路 | Deepgram nova-3 双路流式 |
| 翻译 | 苹果 Translation 框架 | Claude(流式 + 对话上下文) |
| 合成 | AVSpeechSynthesizer | ElevenLabs Flash 流式 |
| 网络 | 离线可用 | 需要联网 + 三个 API Key |
| 费用 | 免费 | 按量计费,注册均有免费额度 |
| 体验 | 延迟较高,机器音 | 首句音频约 1 至 2 秒到耳,自然人声,术语前后一致 |

## 环境要求

- 一台 Mac,装 Xcode 16 或更高版本
- iPhone,系统 iOS 18.0 或更高
- 免费 Apple ID 即可(签名 7 天有效,过期重新连 Mac 跑一次)

## 安装到手机

1. 双击 `RealtimeTranslator.xcodeproj` 用 Xcode 打开
2. 选中 target 进入 Signing & Capabilities:Team 选你的 Apple ID,Bundle Identifier 改成唯一的
3. 数据线连 iPhone,Cmd+R 运行
4. 首次需要:手机开 开发者模式(设置 > 隐私与安全性),并在 设置 > 通用 > VPN与设备管理 里信任证书

## 云端模式的三个 Key

在 App 设置里切到「云端」后填入,Key 保存在设备钥匙串,请求直连各服务商:

1. **Deepgram**(识别):console.deepgram.com 注册,新账号送试用额度
2. **Anthropic**(翻译):console.anthropic.com 创建 API Key,用量和计费见 https://docs.claude.com/en/api/overview
3. **ElevenLabs**(合成):elevenlabs.io 注册,免费档每月有额度;Voice ID 默认用 Rachel(多语种,中英通吃),想换声音去 Voice Library 复制别的 ID

粗略成本感受:一小时对话大约几美元量级,识别按分钟、翻译按 token、合成按字符计费,以各官网价格为准。

## 首次使用

1. 允许 麦克风 权限(端上模式还需 语音识别 权限)
2. 端上模式:点一次「下载语言包」把中英翻译模型下好
3. 关键设置:iPhone 设置 > 辅助功能 > 音频与视觉,确认「单声道音频」关闭,否则左右声道会被混在一起
4. 连上 AirPods,你戴左耳,朋友戴右耳(可在设置里换)

## 使用方法

1. 手机平放两人中间,点青色麦克风开始
2. 两人正常轮流说话,不需要按键:你说中文,英文译文进朋友右耳;朋友说英文,中文译文进你左耳
3. 上半屏是给朋友看的英文字幕(面对面模式自动倒转),下半屏是你的中文字幕
4. 说完停顿约 1 秒即触发翻译

## 云端管线工作原理

```
iPhone 麦克风(常开,VAD 断句)
   └─ 说话期间:音频降采样 16k 同时上送两条 Deepgram websocket(中文路 + 英文路)
        └─ 句尾发 Finalize,比较两路整体置信度自动判定语种
             └─ Claude 流式翻译,带最近 10 轮对话上下文,人名术语前后一致
                  └─ 逐 token 攒到句子边界就切给 ElevenLabs 流式合成
                       └─ PCM 音频块到一块播一块,pan 到对方声道
```

关键设计:

- **双路识别代替 multi 模式**:nova-3 的 multi 混合模式暂不支持中文,双路专语言模型准确率也更高,代价是识别费用双份
- **三级流水线重叠**:翻译还没写完,第一句已经在合成;合成还没结束,第一块音频已经在耳机里。首句到耳延迟约 1 至 2 秒
- **持久连接**:两条识别 websocket 全程保持,静默期靠 KeepAlive 心跳维持,每句话零建连开销
- **收音永远用 iPhone 麦**,耳机只输出,保持 A2DP 高音质;voiceChat 模式自带回声消除
- **半双工**:播报期间暂停收音,避免把自己播的译文录进去

## 故障排查

- 中文路报错说不支持:把 DualDeepgramASR.swift 里 model 参数从 nova-3 改成 nova-2
- 识别连接断开:停止再开始即可重连;检查网络和 Deepgram 余额
- 翻译报 401:Anthropic Key 填错;报 429:限流或额度用完
- 合成报错:检查 ElevenLabs Key 和 Voice ID,注意免费档有并发和字符限制
- 吵闹环境误触发:设置里把触发灵敏度往右调
- 听不到声音或两耳串音:检查系统「单声道音频」必须关闭

## 已知限制与下一步

- 半双工:播报时说话会被忽略
- 句级流水线:更极致的方案是 ElevenLabs websocket 输入流,逐词喂送,能再省几百毫秒
- 全双工 + 回声参考信号,实现边听边译,是 v3 的方向

## 无 Mac 路线:GitHub Actions 云端编译 + Windows 装机

不需要任何 Mac。GitHub 的免费云端 Mac 负责编译出 IPA,Windows 上用 Sideloadly 签名装进 iPhone。

1. 注册 github.com,新建仓库,选 Public(公开仓库的 Actions 免费不限时长)
2. 把本文件夹里的全部内容(包括 .github 文件夹)上传到仓库根目录
3. 上传后进仓库的 Actions 标签页,Build iOS IPA 工作流会自动运行,约 10 分钟
4. 运行成功(绿勾)后点进去,页面底部 Artifacts 里下载 RealtimeTranslator-ipa,解压得到 .ipa 文件
5. Windows 上装 iTunes(apple.com 下载)和 Sideloadly(sideloadly.io),数据线连 iPhone
6. Sideloadly 里填你的 Apple ID,把 .ipa 拖进去,点 Start
7. iPhone 上:设置 > 隐私与安全性 > 开发者模式 打开并重启;设置 > 通用 > VPN与设备管理 信任证书
8. 每 7 天签名过期,重开 Sideloadly 用同一个 .ipa 再点一次 Start 即可,不用重新编译

如果 Actions 编译报红叉,点进失败步骤把报错文字复制出来,交给 Claude 修。
