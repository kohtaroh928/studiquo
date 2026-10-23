# 原PDF内部orchestratorの接続記録

2026-10-18。計画Step1〜3の内部接続と受付行数制限。未公開・未配備。

## 実装

- header/binding確認→admission予約→一度限りreceive claim→有限reader→原PDF digest検証→dispatch CAS→private parse一回→最終構造検証→非公開consumer→停止確認精算→最終再認可。
- token付きjob状態guardを追加し、intakeが有効でもjobのみの停止要求を監視する。pollは重複させず、独立したwork deadline/abortを持つ。
- readerのcancel完了promiseをtrusted callerへ観測可能にし、ローカル停止不明なら枠を保持する。
- manifestは最大4MiB、strict envelope/全page連番・共通文書・原digest・namespace、既存prepareStructuredInputによるmetadata/text hash、batchをまたぐlocal ID一意を確認。初版の固定Docling profile/semanticなしを要求。
- prepareLimitedRawPDFIntakeを追加。owner/global総行数・有効pending数を同一INSERT条件で制限し、同文書置換は行数を増やさない。旧primitiveは内部互換用、将来の公開受付はbounded版とrate limitを使う。

## 修正したレビュー指摘

1. timeoutは実Promiseを停止しない。bytes検証内のDB停止でPDFコピーを持つtaskが残っていたため、開始済み実taskを追跡し、終了不明ならmemory枠を解放しない。
2. success/catch間でcleanup期限を作り直さず、一つの最大10秒graceを共有。
3. 大きい結果を精算後のDB待機へ持ち越さない。必須trusted consumeResultへ枠保持中だけ渡し、その完了と参照解放を確認。raw bytes・readerTask・Request・manifestの参照を落としてから精算し、小さい成功状態だけ返す。

consumerは非公開staging専用で、終了前に参照を解放し、未確認の結果を利用者へ公開/正式採用しない。正式採用は今後の再認可/commit契約で別実装する。callbackも未終了なら枠を保持する。今回HTTP streamingやiPadへ結果を公開する経路はない。

## 検証

サーバー全体1,812件成功（失敗/skip0）、orchestrator17件、intake24件成功。独立Code/Security観点レビューで上記修正後の未解決指摘なし。独立再テストは未実施。最初の修正中に一時的なshadowingによるテスト失敗があり修正済み。最終結果だけを現在の成績とする。

合成2pageで新MCP処理→DoclingJob（DO/VMはshim）→実loopback HTTP→実offline Docling→strict manifest→非公開test consumer→job精算まで確認。parse POST1回、7.642秒、helper停止・job一時領域削除。本文/manifestをrepoやNotionへ保存せず、結果metadataだけを記録。

通常sandboxではlistener権限で最初の試験が失敗。loopback 127.0.0.1に限定したテストhelperへ変更し、許可されたlocal試験で成功した。外部送信・新モデル取得・新有料APIなし。実コードhashはRESULTS.jsonに保存。

## 現在の境界と次の作業

実Linux build/VM起動停止/OS隔離/Cloudflare service-binding/実D1は未検証。Docker/Podmanが見つからず、この検証を再開するには利用可能なDocker/Linux環境が必要。runtime導入・配備・費用条件の承認を今回のローカル成功から推測しない。

停止不明/token紛失時の証拠付き復旧、監視/reaper/cleanup retry、retention/tombstone整理、heap/実費policy校正、公開rate limit、非公開result staging→新Notebook採用とiPad接続が残る。公開flag/config/routeは追加していない。0010〜0012はremote未適用、commit/push/deployなし、自動スケジュールPAUSED。
