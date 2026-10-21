# SECURITY.md と security.txt の案(連絡先が決まるまで公開しない)

連絡先は現在、個人のGmail(`legal.ts`)。独自ドメインの専用アドレスに替える判断(別のカード)が先。決まったら、下の `<連絡先>` を差し替えて、次を行う。

1. リポジトリ直下に `SECURITY.md` を置く(下の本文)。
2. Workerに `/.well-known/security.txt`(RFC 9116)を配信する。`Expires` は1年以内で、更新の期日を[RUNBOOK](../RUNBOOK.md)に書く。テスト: 内容、`Expires`が未来、`Content-Type: text/plain`。
3. GitHubの Settings → Code security → 「Private vulnerability reporting」を有効にする(責任者の操作)。

## SECURITY.md の本文案

> # セキュリティ
>
> Studiquoの脆弱性を見つけた方は、公開の場所に書かずに、次の宛先へ連絡してください。
>
> - 連絡先: `<連絡先>`(または、このリポジトリの「Report a vulnerability」)
> - 含めてほしいこと: 何が起きるか、再現の手順、影響を受けるバージョン。実際の利用者のデータは取得・保存しないでください。
> - 対応の目安: 受領の連絡は3営業日以内、状況の連絡は7日以内。修正の時期は影響によります。
> - 対象: `api.studiquo.app`、iPad向けアプリ、このリポジトリ。
> - 対象外: 他の利用者への攻撃、サービスの停止を狙う試験(DoS)、ソーシャルエンジニアリング、第三者のサービス(OpenAI、Cloudflare、RevenueCat、Appleなど)の脆弱性。
>
> 善意の報告に対して、法的な措置は取りません。

## security.txt の案

```
Contact: mailto:<連絡先>
Expires: <発行から1年以内の日時 ISO 8601>
Preferred-Languages: ja, en
Canonical: https://api.studiquo.app/.well-known/security.txt
Policy: https://github.com/kohtaroh928/studiquo/blob/main/SECURITY.md
```

注意: 「対応の目安」の日数と「法的な措置は取りません」は、責任者が決めてから公開する(AIが決めてよい内容ではない)。
