function bannerPreview(text, limit = 120) {
  const normalized = String(text ?? "").replace(/\s+/g, " ").trim();
  return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
}

/** Builds the visible APNs alert for both direct and group chat. */
export function chatMessageNotification({ roomID, text, senderName, groupName = null }) {
  const preview = bannerPreview(text);
  const safeSender = String(senderName ?? "フレンド").trim() || "フレンド";
  const safeGroup = String(groupName ?? "").trim();
  return {
    category: "friendMessage",
    title: safeGroup || safeSender,
    body: safeGroup ? `${safeSender}: ${preview}` : preview,
    threadID: roomID,
    data: { route: "friendMessage", roomID },
  };
}
