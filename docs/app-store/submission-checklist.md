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

---

参考文件:`privacy-policy.md`、`review-notes.md`(均在 `docs/app-store/`)。
