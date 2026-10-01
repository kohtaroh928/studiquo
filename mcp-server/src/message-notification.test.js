import assert from "node:assert/strict";
import test from "node:test";
import { chatMessageNotification } from "./message-notification.js";

test("a direct-message banner shows the sender and exact message content", () => {
  const notification = chatMessageNotification({
    roomID: "direct-room",
    senderName: "田中",
    text: "明日の課題どこまで？",
  });

  assert.equal(notification.title, "田中");
  assert.equal(notification.body, "明日の課題どこまで？");
  assert.equal(notification.data.roomID, "direct-room");
});

test("a group-message banner shows the group, sender, and message content", () => {
  const notification = chatMessageNotification({
    roomID: "group-room",
    groupName: "数学ゼミ",
    senderName: "佐藤",
    text: "  14ページを\n解きます  ",
  });

  assert.equal(notification.title, "数学ゼミ");
  assert.equal(notification.body, "佐藤: 14ページを 解きます");
  assert.equal(notification.data.route, "friendMessage");
});
