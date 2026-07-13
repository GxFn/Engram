# App Review 备注(草稿)

> 用途:粘贴到 App Store Connect →「App 审核信息 / App Review Information」的 **Notes** 字段。
> ⚠️ **真实测试 Key 只在提交时填进 App Store Connect,切勿写入代码仓库或任何公开位置。**

---

## 中文(建议主用)

**这是什么 App**
Engram 是给短视频创作者的"第二大脑":把你**自己相册里的视频**导入后,在**设备本机**做语音转写、画面理解,拆解出爆点结构与分镜剧本,并支持对你保存的内容做问答与规律洞察。

- 本 App **不生成视频**,不提供生成式 AI 服务;只做"理解 + 记忆 + 问答"。
- 视频来自**用户本地文件**(系统图片选择器),本 App 不抓取、不下载任何平台内容。
- **无需注册/登录**,无账号体系。

**如何测试(两种方式)**

*方式 A —— 云端模式(推荐,最快看到主功能):*
1. 打开 App →「设置」→「请求模式」选择「Ark Standard」。
2. 在「Ark · 文本与逐镜画面」填入以下测试配置:
   - Base URL: `https://ark.cn-beijing.volces.com/api/v3`
   - 文本模型 ID: `[提交时填写临时文本接入点 ep-…]`
   - 视觉模型 ID: `[提交时填写临时视觉接入点 ep-…]`
   - API Key: `[提交时填写临时测试 Key —— 勿写入仓库]`
   点「保存」。
3. 回到「拆解」标签 → 右上角导入一段短视频(设备相册里任意一段人物说话的短视频即可)→ 等待拆解完成,可查看分镜、字幕、爆点结构。
4. 在「问答」标签可基于已保存内容提问;「洞察」标签可选多条剧本提炼范式。

*方式 B —— 端侧模式(完全离线):*
在「设置」→「AI 模式」选「本地」,下载推荐模型后即可离线拆解(模型体积较大、视觉模型需较高内存机型;若审核设备内存有限,请用方式 A)。

**隐私与数据**
- 云端模式下,仅"用于分析的关键帧与文本"发送到上面这个**用户自配置的第三方服务**;开发者**没有任何服务器**,不接收这些数据。
- 审核步骤使用的是 `Ark Standard`:不会上传完整视频。仓库还包含个人 BYOK 测试用的 `LAS Deep`,它会把一份原视频流式暂存到用户自己的 TOS 并调用四个 LAS 算子,需要真实媒体探测与一次性费用/上传同意。由于公开发布所需的 presigned broker 后端尚未完成,提交审核的公开版本不得开放 LAS/TOS 路径。
- API Key 保存在系统钥匙串(Keychain)。
- 详见隐私政策:`[填写你托管的隐私政策 URL]`

**分享扩展(EngramClip)**
从其他 App 的系统分享菜单可把链接/文字分享进 Engram 作为"剪藏"。测试:在浏览器中选中一段文字或分享一个网址 → 分享菜单选 Engram。

---

## English (optional)

Engram is a "second brain" for short-video creators: import a video **from your own photo library**, and it runs speech-to-text and visual understanding to break the video into its hook structure and storyboard, then lets you ask questions across everything you've saved. **It does not generate video** and provides no generative-AI service. No account/login is required.

**To test the main flow, use Ark Standard:** Settings → Requested Mode → Ark Standard → enter Base URL `https://ark.cn-beijing.volces.com/api/v3`, the text/vision model IDs and API Key we provide above, tap Save, then import a short talking-head video. Only sampled frames/text are sent to that user-configured endpoint. The repository also contains a personal-BYOK LAS Deep path that temporarily stages one full video in the user's TOS and may incur charges; it must remain disabled in the public review build until a real presigned-broker backend and deletion contract exist. The developer runs no server and receives nothing. Keys are stored in separate Keychain entries. Privacy policy: `[URL]`.
