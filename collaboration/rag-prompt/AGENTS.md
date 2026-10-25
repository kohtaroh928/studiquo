# プロンプト共同担当の作業範囲

まずroot AGENTS.md、docs/RAG_COLLABORATION.mdとこのフォルダのHANDOFF.mdを読む。

- 候補作成はcandidates/、仮説・採点設計はPROPOSAL.md、進捗はこのHANDOFF.mdへ記録する。
- shared docs/RAG_CLAUDE_HANDOFF.mdは統合担当が集約する。並行作業者はそこを更新する代わりに担当HANDOFFを更新する。
- 本番src、認証/課金、検索、凍結baseline、評価bank/gold/未使用20問を変更しない。
- check/prepareはキー不要・API0回。成功は入力準備の検証であり回答品質ではない。
- 自分のclone/branchを使う。担当範囲外が必要なら理由と対象を提案し、合意してから編集する。
- 秘密・実資料・生回答は保存/ログ/コミットしない。.localはprivate生成物でcommitしない。
