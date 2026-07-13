# Engram 上架清单(中国区)

## A. 仓库内技术准备(可由代码完成)

- [x] App 图标 + 深色版(`App/Assets.xcassets/AppIcon.appiconset`)
- [x] 启动屏(`UILaunchScreen` + `LaunchLogo` + `LaunchBackground`)
- [x] 主 App 隐私清单 `App/PrivacyInfo.xcprivacy`(UserDefaults / FileTimestamp)
- [x] `Info.plist`:`ITSAppUsesNonExemptEncryption=false` + `NSSpeechRecognitionUsageDescription`
- [x] 分享扩展隐私清单 `ShareExtension/PrivacyInfo.xcprivacy`(已接入 pbxproj,build 验证进 .appex)
- [x] 开源致谢 `ACKNOWLEDGEMENTS.md`
- [ ] (可选)`AccentColor` 改成品牌紫,与新图标统一
- [ ] 真机验证:切云端跑通拆解(**你还没做的临门一脚**)+ 分享扩展流程
- [ ] 真机验证能力探测失败时显示 exact missing roles,只提供显式 Ark Standard/Local/Cancel,且未上传完整视频
- [ ] 个人 BYOK 测试验证 LAS/TOS 单独上传同意、未知费用、字节上限、四算子、重启、取消、清理/TTL 和错误脱敏
- [ ] **公开发布 blocker:**建立真实 presigned TOS broker 后端仓库、部署 owner、签发/读取/删除能力并通过隐私验证;完成前发布构建禁用 LAS/TOS(不得用空协议/mock broker 代替)
- [ ] 版本号确认(当前 MARKETING_VERSION=1.0 / BUILD=1)

## B. 账号与签名(你在 Mac / 开发者后台做)

- [ ] Apple Developer 会员有效
- [ ] **Distribution 证书 + App Store 描述文件**(现有多为 Development)
- [ ] Archive → 上传(Xcode Organizer 或 Transporter);每次上传 build 号 +1、带 dSYM

## C. App Store Connect 素材

- [ ] 新建 App 记录(bundle id `com.gxfn.engram`、主语言=简体中文)
- [ ] **隐私政策 URL**:把 `docs/app-store/privacy-policy.md` 托管到公开 URL 后填入
- [ ] **App 隐私"营养标签"**:按隐私政策如实填(基本可选"未收集数据";云端上传到用户自配端点,在描述里说明)
- [ ] **App 审核备注**:用 `docs/app-store/review-notes.md`,**提交时补上临时测试 Key/接入点**
- [ ] 截图(至少 6.9"/6.7" iPhone;固定像素规格)、描述、关键词、副标题、支持 URL
- [ ] 年龄分级问卷、分类(建议:效率 或 摄影与录像)
- [ ] 名称「Engram」商店查重 + 商标确认

## D. ⚠️ 中国区专项(硬前置 / 高风险)

- [ ] **ICP 备案**:App 连大陆云(火山方舟),中国区上架需备案(服务商侧办理,耗时数周)——**最先启动**
- [ ] 云端 key 可测试性:审核备注给可用测试配置(见 review-notes),否则大概率被拒(Guideline 2.1)
- [ ] AI 合规:本 App 只做"理解/分析",不提供生成式 AI 服务、不抓取平台内容(保持这个边界,别在 v1 加链接下载)
- [ ] 若涉及"生成式AI/算法"相关备案要求,按当地最新规定评估(法务侧)

## E. 发布前

- [ ] **TestFlight 内测**跑通 → 再提交审核

## F. 官方链接(真实入口)

**中国区备案(火山引擎,最先办)**
- 备案概览:https://www.volcengine.com/docs/6428/68720
- 首次备案流程:https://www.volcengine.com/docs/6428/68739
- 备案材料清单:https://www.volcengine.com/docs/6428/141349
- 大模型 / 算法 / 人工智能备案说明:https://www.volcengine.com/docs/82379/1471389
- 备案控制台(登录后办理):https://console.volcengine.com/beian
- 工信部备案公示 / 查询:https://beian.miit.gov.cn
- 方舟控制台(拿测试接入点 ep 与 Key):https://console.volcengine.com/ark

**Apple**
- App Store Connect:https://appstoreconnect.apple.com
- 开发者账号:https://developer.apple.com/account
- 证书 / 标识 / 描述文件:https://developer.apple.com/account/resources/certificates/list
- 审核指南:https://developer.apple.com/app-store/review/guidelines/
- App 隐私(营养标签)说明:https://developer.apple.com/app-store/app-privacy-details/
- 截图规格:https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
- TestFlight:https://developer.apple.com/testflight/

**隐私政策托管**
- GitHub Pages:https://pages.github.com

## G. 备案后的代码跟进(拿到备案号后我来做)
- [ ] 在 App 内显著位置(如「设置」底部)显示 ICP/App 备案号,并链接到 https://beian.miit.gov.cn(工信部硬性要求)

---

参考文件:`privacy-policy.md`、`review-notes.md`(均在 `docs/app-store/`)。
