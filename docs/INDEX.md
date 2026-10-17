---
title: Studiquo docs 目次
date: 2026-10-08
tags: [index]
---

# Studiquo docs 目次

Obsidianでは、このフォルダ(`docs/`)をvaultとして開く。GitHubとVS Codeでも同じ相対リンクで辿れる。

## まず読む

- [ARCHITECTURE](ARCHITECTURE.md): システム構成、責務の境界、主要データフロー、既知の制約
- [SECURITY_AND_PRIVACY](SECURITY_AND_PRIVACY.md): データ分類、信頼境界、保持・削除、既知の課題(19章)
- [DATA_AND_MIGRATIONS](DATA_AND_MIGRATIONS.md): 保存先と正本、データ移行の基準
- [DEVELOPMENT_WORKFLOW](DEVELOPMENT_WORKFLOW.md): `開発手順: full`のときに読む詳細な開発手順

## 判断・状態の記録(notes/)

- [notes/INDEX](notes/INDEX.md): 設計判断(ADR)、未決事項、ブランチの状態。決めたことの理由と、いま何が止まっているかを見るときに読む

## 公開・運用

- [PRIVACY_RELEASE_CHECKLIST](PRIVACY_RELEASE_CHECKLIST.md): プライバシー変更を本番へ出す順序と必須条件
- [RELEASE_CHECKLIST](RELEASE_CHECKLIST.md): リリース前の確認項目
- [RUNBOOK](RUNBOOK.md): 障害・運用の手順(ログインの429/503の見方を含む)
- [STAGING_SETUP](STAGING_SETUP.md): ステージング環境の準備と、運営者が行う確認
- [PROJECT_SYNC](PROJECT_SYNC.md): claude.ai Projectへ渡している資料の、更新が必要になる変更の対応表
- [releases/INDEX](releases/INDEX.md): リリース記録
- [diagnostics/INDEX](diagnostics/INDEX.md): 診断の記録

## 機能ごとの記録

- [FRIEND_SCREEN_CHANGE](FRIEND_SCREEN_CHANGE.md): フレンド画面の操作とプロフィール共有
- [SPLIT_SOURCE_PICKER](SPLIT_SOURCE_PICKER.md): 分割画面の資料選択の並べ方の切り替え
- [ai-math-rendering](ai-math-rendering.md): AIの出力の数式の表示
- [cloudkit-verification](cloudkit-verification.md): CloudKit同期の動作確認の記録(実機・複数端末の確認は未実施)

## RAG(検索と回答の根拠)

- [HYBRID_RAG](HYBRID_RAG.md): Hybrid RAG v1の設計
- [RAG_IMPLEMENTATION_REPORT](RAG_IMPLEMENTATION_REPORT.md): 実装・検証の報告
- [RAG_QUALITY_IMPLEMENTATION_PLAN](RAG_QUALITY_IMPLEMENTATION_PLAN.md): 検索品質改善の実装計画
- [RAG_QUALITY_IMPLEMENTATION_REPORT](RAG_QUALITY_IMPLEMENTATION_REPORT.md): 検索品質の修正と検証の報告
- [RAG_SEARCH_QUALITY_EVALUATION](RAG_SEARCH_QUALITY_EVALUATION.md): 日本語検索・OCR・100ページPDFの品質評価
- [RAG_ANSWERABILITY_IMPLEMENTATION_REPORT](RAG_ANSWERABILITY_IMPLEMENTATION_REPORT.md): 具体情報に対する根拠判定
- [RAG_FINAL_ANSWER_EVALUATION_REPORT](RAG_FINAL_ANSWER_EVALUATION_REPORT.md): Geminiの最終回答の評価
- [RAG_CLOUDFLARE_AI_VALIDATION](RAG_CLOUDFLARE_AI_VALIDATION.md): Workers AIの実環境での検証

`RAG_*.json`は評価の生データで、ノートではない。
