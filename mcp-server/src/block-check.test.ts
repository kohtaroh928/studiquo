import assert from "node:assert/strict";
import test from "node:test";
import { blockedBetween } from "./block-check.ts";
import { partialEnv } from "./test-env.ts";

// A CHAT_ROOM binding whose rooms answer blockStatus with whatever `answer`
// returns for that room, recording which rooms and callers were asked about.
function envAnswering(answer: (roomID: string, userKey: string) => unknown) {
  const asked: { roomID: string; userKey: string }[] = [];
  const env = partialEnv({
    asked,
    CHAT_ROOM: {
      getByName(roomID: string) {
        return {
          async blockStatus(userKey: string) {
            asked.push({ roomID, userKey });
            return answer(roomID, userKey);
          },
        };
      },
    },
  });
  return env;
}

test("nothing is blocked when there is no friend, or the pair has no room yet; the room isn't asked", async () => {
  const env = envAnswering(() => ({ blockedByMe: true, blockedByOther: true }));
  assert.equal(await blockedBetween(env, "me", undefined), false);
  assert.equal(await blockedBetween(env, "me", null), false);
  assert.equal(await blockedBetween(env, "me", {}), false);
  assert.equal(await blockedBetween(env, "me", { roomID: null }), false);
  assert.equal(await blockedBetween(env, "me", { roomID: "" }), false);
  assert.deepEqual(env.asked, []);
});

test("a block by either side counts, and no block at all does not", async () => {
  const friend = { roomID: "room-1" };
  const answers: Record<string, unknown> = {
    none: { blockedByMe: false, blockedByOther: false },
    mine: { blockedByMe: true, blockedByOther: false },
    theirs: { blockedByMe: false, blockedByOther: true },
    both: { blockedByMe: true, blockedByOther: true },
  };
  const results: Record<string, boolean> = {};
  for (const [name, answer] of Object.entries(answers)) {
    results[name] = await blockedBetween(envAnswering(() => answer), "me", friend);
  }
  assert.deepEqual(results, { none: false, mine: true, theirs: true, both: true });
});

test("the question is asked of the friend's own room, on behalf of the caller", async () => {
  const env = envAnswering(() => ({ blockedByMe: false, blockedByOther: false }));
  await blockedBetween(env, "caller-key", { roomID: "room-xyz" });
  assert.deepEqual(env.asked, [{ roomID: "room-xyz", userKey: "caller-key" }]);
});

test("a room that no longer lists the caller is treated as not blocked", async () => {
  const env = envAnswering(() => { throw new Error("Forbidden"); });
  assert.equal(await blockedBetween(env, "me", { roomID: "room-1" }), false);
});

test("any other failure of the room is not hidden, so an invite can't slip past a block it couldn't check", async () => {
  const env = envAnswering(() => { throw new Error("storage unavailable"); });
  await assert.rejects(() => blockedBetween(env, "me", { roomID: "room-1" }), /storage unavailable/);
  const notAnError = envAnswering(() => { throw "Forbidden"; });
  await assert.rejects(() => blockedBetween(notAnError, "me", { roomID: "room-1" }));
});

test("a missing or partial answer from the room is not a block", async () => {
  assert.equal(await blockedBetween(envAnswering(() => ({})), "me", { roomID: "room-1" }), false);
  assert.equal(await blockedBetween(envAnswering(() => ({ blockedByMe: 0, blockedByOther: "" })), "me", { roomID: "room-1" }), false);
});
