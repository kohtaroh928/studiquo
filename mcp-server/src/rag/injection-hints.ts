// Counts phrases that look like instructions aimed at an AI inside retrieved
// text. It never changes the text or the answer: a study document may quote
// such phrases, and deleting them would corrupt it. The count goes to the log
// so a spike (an account whose library keeps matching) can be noticed.
const HINTS = [
  /ignore\s+(?:all\s+|any\s+)?(?:the\s+)?(?:previous|prior|above|earlier)\s+(?:instructions?|rules?|prompts?)/iu,
  /(?:これまで|以前|上記|前|先)の(?:指示|命令|ルール|制約)(?:は|を)?(?:全て|すべて)?(?:無視|無効|忘れ|取り消)/u,
  /^\s*(?:system|assistant|developer|システム|管理者)\s*[:：]/imu,
  /(?:developer|debug|jailbreak)\s+mode|開発者モード|デバッグモード/iu,
  /(?:print|reveal|show|output|表示|出力|教え)[^。\n]{0,24}(?:system\s*prompt|システムプロンプト|内部の指示)/iu,
  /(?:AI|アシスタント|モデル|assistant)(?:へ|に向け|への)[^。\n]{0,6}(?:指示|命令|お願い|instruction)/iu,
  /(?:回答|返答|返信)の(?:冒頭|最初|最後|末尾)に(?:必ず|かならず)/u,
  /\]\(\s*https?:\/\//iu,
];

export function countInjectionHints(text: any) {
  const value = String(text ?? "");
  let count = 0;
  for (const pattern of HINTS) if (pattern.test(value)) count++;
  return count;
}
