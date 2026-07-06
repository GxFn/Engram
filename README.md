# Engram

> Clip it anywhere. Ask it anytime. Fully on-device.

**Engram** 是一个「剪藏记忆库」:在任意 app 里通过 share sheet 一键剪藏有价值的内容,之后随时用自然语言问出来——端侧 LLM + 本地 RAG,回答附剪藏原文引用,问答全程离线。

名字来自神经科学术语 *engram*(记忆痕迹):记忆在大脑中留下的物理印记。在这里,你的记忆痕迹物理地存在你自己的设备上——不在任何人的云里。

## 产品哲学:小而美、接缝级

Engram 不是又一个目的地型 chat app。它的入口活在 iOS 的系统接缝里:

| 接缝 | 职责 | 阶段 |
| --- | --- | --- |
| **Share Extension** | 主入口:任意 app 剪藏文本/链接,3 秒返回 | M2 |
| **App Intents** | Siri「问问我的剪藏」/ Action Button / Shortcuts | M4 |
| **Widget** | 每日回顾一条旧剪藏 | M4 |
| **Core Spotlight** | 剪藏进系统搜索,直达 | M4 |

App 本体只有三个界面:**Memory**(剪藏时间流)、**Ask**(问答 + 引用)、**Bench**(真机跑分)。

## Architecture

```
App (Xcode target: @main + assembly)
│
├── Extension Targets ── ShareExtension (M2) / Widget (M4) / AppIntents (M4)
│
├── AppShell ──────────── assembly layer, the only Infrastructure importer
│
├── Features ──────────── SwiftUI, depend on Domain protocols ONLY
│     AskFeature / MemoryFeature / BenchFeature / SettingsFeature
│
├── Domain ────────────── pure Swift contracts, zero third-party deps
│     EngineKit (LLMEngine protocol) / RAGCore / ClipCore / MetricsKit
│
└── Infrastructure ────── leaf plugins implementing Domain protocols
      MLXEngine (M1) / FMEngine (M3) / EmbeddingMLX / VectorStoreSQLite
      ClipPipeline / ModelStore / Persistence
```

**依赖规则(结构约束,不靠自觉):**

1. Features 只 import Domain,永不 import Infrastructure;AppShell 统一装配注入。
2. 引擎是叶子插件:M3 新增 FMEngine 时 Feature 层零改动。
3. Domain 零第三方依赖,纯函数可单测(RRF 融合、Clip 状态机已带测试)。
4. 现代栈:SwiftUI + Swift 6 strict concurrency + SwiftData + AsyncSequence 流式。
5. **Share Extension 的依赖闭包里永不出现推理引擎**——extension 约 120MB 内存墙是编译期结构约束,不是运行时约束。

## Roadmap

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **M1 端侧引擎地基** | MLX 跑通 Qwen3-4B(4bit)、流式输出、模型下载管理、Bench 极简版 | 🔨 |
| **M2 剪藏闭环** | Share Extension → App Group 队列 → 后台索引;混合检索(BM25 + 向量)+ 引用问答 | ⬜️ |
| **M3 双引擎** | Foundation Models 作为第二引擎,一键切换 + 同题对比报告 | ⬜️ |
| **M4 系统接缝群** | App Intents / Widget / Spotlight | ⬜️ |

## Benchmarks

真机实测,脚本可复现,禁止演示模式造假。M1 落地后填充:

| 模型 | 设备 | TTFT (ms) | tokens/s | 内存峰值 | 热状态 |
| --- | --- | --- | --- | --- | --- |
| Qwen3-4B-4bit | — | — | — | — | — |
| Qwen3-1.7B-4bit | — | — | — | — | — |

## Retrieval Evaluation

Source: `Sources/Features/BenchFeature/BenchSuite/retrieval-eval.json` (20 fixed clips, 24 gold questions).
Reproduce: `swift test --filter retrievalEvalRunnerReportsReadmeComparisonFromBundledFixture`.

| Strategy | Questions | Recall@8 | MRR |
| --- | ---: | ---: | ---: |
| Hybrid | 24 | 1.00 | 0.98 |
| Vector-only | 24 | 1.00 | 0.96 |
| Keyword-only | 24 | 1.00 | 0.98 |

## Requirements

- iOS 26.0+,建议 8GB 内存机型(iPhone 15 Pro / 16 系起)
- Xcode 26+ / Swift 6

## Model Setup

Engram downloads public MLX Qwen model snapshots from Hugging Face in Settings
or Welcome. Choose `Download` for the recommended model; Engram fetches the
required `config.json`, tokenizer files, and `.safetensors` weights, then
materializes them under `Application Support/Models/<org>/<model>` with
`.engram-model.json`.

`Import Model Folder` remains available for debugging or offline transfer of an
already prepared MLX folder. The app uses no credentials, login, sync server, or
server-side inference.

## Building

SPM 包(全部模块 + 测试):

```bash
swift build && swift test
```

App 壳(一次性设置):

1. Xcode → File → New → Project → iOS App,命名 `Engram`,放在仓库根目录(不要让 Xcode 新建 git)。
2. 删除模板源文件,把 `App/EngramApp.swift` 加入 app target。
3. File → Add Package Dependencies → Add Local…,选仓库根目录,给 app target 链接 `AppShell`。
4. 配置 signing 后真机运行。

## License

[MIT](LICENSE)
