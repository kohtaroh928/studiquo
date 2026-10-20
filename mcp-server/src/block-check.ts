// Whether either side has blocked the other in their direct room. A pair that
// has no room yet has nothing blocked. Shared by every route that lets one
// person put another in front of someone (document and group invites).
import type { Env } from "./env.ts";

export async function blockedBetween(env: Env, userKey: string, friend?: { roomID?: string | null } | null): Promise<boolean> {
  if (!friend?.roomID) return false;
  try {
    const state = await env.CHAT_ROOM.getByName(friend.roomID).blockStatus(userKey);
    return Boolean(state.blockedByMe || state.blockedByOther);
  } catch (error) {
    if (error instanceof Error && error.message === "Forbidden") return false;
    throw error;
  }
}
