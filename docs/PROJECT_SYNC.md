---
title: Projectの資料の更新対応表
date: 2026-10-09
tags: [process, claude-projects]
---

# Projectの資料の更新対応表

claude.aiの2つのProject(「Studiquo プロダクト・設計」「Studiquo リリース・ストア」)には、このリポジトリの文書の複製を渡している。この文書は、リポジトリを変更したときに「Projectの資料のどれを更新する必要があるか」を判断する基準である。

- 複製の置き場: `~/Desktop/studiquo-projects/`(`1-product-design/`と`2-release-store/`)。作成日は2026-10-08。
- 正本はリポジトリ。Projectの資料は複製であり、古くなりうる。
- claude.aiのProjectへの差し替えは人間が行う。開発エージェントが行うのは、更新が必要なファイルの特定と、置き場のファイルの更新まで。Projectへのアップロードはしない。

## 開発エージェントの手順

1. 実装・文書・設定の変更を終えたら、下の表で、変更が該当するかを確認する。
2. 該当するものがなければ、完了報告に「Projectの資料の更新: なし」と書く。
3. 該当するものがあれば、完了報告に次の形で書く。更新の判断を省略しない。

   ```text
   Projectの資料の更新が必要:
   - [設計] ARCHITECTURE.md(複製を差し替え)
   - [リリース] 00_残タスク表.md(A3の状態を更新する必要あり)
   ```

4. 置き場のファイルを更新するのは、ユーザーが依頼したときだけ。複製は、正本の該当ファイルを同じ名前でコピーする。
5. 小さな修正(既存の構成の範囲内の不具合修正、UI調整、テストの追加)は該当しない。毎回の更新を求めない。

## 複製するファイル(正本のコピー)

正本が変わったら、同名のファイルを差し替える。

| リポジトリの正本 | 置き場のファイル名 | 置き場 |
| --- | --- | --- |
| `docs/ARCHITECTURE.md` | `ARCHITECTURE.md` | 設計 |
| `docs/DATA_AND_MIGRATIONS.md` | `DATA_AND_MIGRATIONS.md` | 設計 |
| `docs/SECURITY_AND_PRIVACY.md` | `SECURITY_AND_PRIVACY.md` | 設計・リリース |
| `docs/DEVELOPMENT_WORKFLOW.md` | `DEVELOPMENT_WORKFLOW.md` | 設計 |
| `docs/INDEX.md` | `INDEX.md` | 設計 |
| `docs/ai-math-rendering.md` | `ai-math-rendering.md` | 設計 |
| `docs/HYBRID_RAG.md` | `HYBRID_RAG.md` | 設計 |
| `docs/notes/decisions/adr-*.md` | 同名 | 設計 |
| `docs/notes/open-decisions.md` | `notes-open-decisions.md` | 設計・リリース |
| `docs/RELEASE_CHECKLIST.md` | `RELEASE_CHECKLIST.md` | リリース |
| `docs/PRIVACY_RELEASE_CHECKLIST.md` | `PRIVACY_RELEASE_CHECKLIST.md` | リリース |
| `docs/cloudkit-verification.md` | `cloudkit-verification.md` | リリース |
| `docs/releases/<日付>-*.md`(新しいリリース記録) | `release-<日付>-*.md` | リリース |
| `mcp-server/src/legal.js` | `legal-pages-source.js.txt` | リリース |

意図して複製していないもの: ソースコード、`RAG_*`の評価報告と生データ、`STAGING_SETUP.md`、`RUNBOOK.md`、`notes/branches.md`。理由は、リポジトリとすぐ食い違うか、Projectの役割(設計の相談とリリース準備)に不要なため。

## 書き下ろしのファイル(内容を直す)

コピーではなく、文章を書き直す。何が変わったときに直すかを示す。

| ファイル | 置き場 | 更新が必要になる変更 |
| --- | --- | --- |
| `00_機能一覧と現状.md` | 設計 | 機能の追加・削除・大きな変更、プランの内容の変更、ブランチの`main`への統合、公開状態の変化 |
| `01_意思決定ログ.md` | 設計 | ADRの追加・変更、設計判断の確定、未決事項が決まったとき |
| `02_ユーザー像と利用場面.md` | 設計 | 人間が自分で記入する。開発エージェントは内容を推測で埋めない |
| `00_残タスク表.md` | リリース | 外部サービスの設定や確認が終わった・新しく増えた、未決が決まった、リリースの節目(提出前、公開後)、サーバーのデプロイ |
| `01_ストアメタデータ原稿.md` | リリース | 利用者に見える機能の変化、対応言語の変更、収集する情報や外部送信の変化(プライバシー申告に影響)、プランや価格の確定 |
| `02_審査メモ.md` | リリース | 認証手段の変更、アカウント削除の動作変更、購入画面の変更、AI同意まわりの変更、友達・チャット機能の変更、権限(カメラ・マイク・写真)の変更 |
| `03_サブスク商品定義.md` | リリース | Product ID・Entitlement・`PRODUCT_PLAN_MAP`の変更、プランの内容(クレジットなど)の変更、価格・トライアルの確定 |

## 変更したファイルから見る早見表

| 変更したもの | 確認する資料 |
| --- | --- |
| `studiquo/Services/SubscriptionStore.swift`、`studiquo/Views/SubscriptionPlansView.swift`、`mcp-server/src/entitlements.js` | `03_サブスク商品定義.md`、`01_ストアメタデータ原稿.md` |
| `mcp-server/src/legal.js`、アプリ内の利用規約・プライバシーポリシー | `legal-pages-source.js.txt`(複製)、`01_ストアメタデータ原稿.md`(プライバシー申告の材料) |
| `project.yml`の権限の説明文(`NSCameraUsageDescription`など)、`Info.plist` | `02_審査メモ.md` |
| `studiquo/Services/AuthenticationStore.swift`、`AccountFlowView.swift`、`mcp-server/src/account-deletion.js` | `02_審査メモ.md`、`00_残タスク表.md`、`SECURITY_AND_PRIVACY.md`(複製) |
| `mcp-server/wrangler.jsonc`の設定、デプロイ、migrationの適用 | `00_残タスク表.md`、リリース記録(複製) |
| `studiquo/Models/`の変更(SwiftData) | `ARCHITECTURE.md`、`DATA_AND_MIGRATIONS.md`(複製) |
| 新しいADR | ADRと`notes-open-decisions.md`(複製)、`01_意思決定ログ.md` |

## 人間の作業

開発エージェントから更新が必要と報告されたら、置き場のファイルを確認し、claude.aiのProjectで古いファイルを削除してから新しいファイルを追加する。同名のファイルを重複して残すと、Projectが古い内容を参照することがある。

Related: [INDEX](INDEX.md)
