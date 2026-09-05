import { DurableObject } from "cloudflare:workers";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_FRIENDS = 500;

function generateCode() {
  const bytes = new Uint8Array(7);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => CODE_ALPHABET[value % 32]).join("");
}

// Every request for the same key resolves to the same object instance, and a
// Durable Object handles its incoming requests one at a time — so two
// concurrent "this user doesn't exist yet" registrations for the same key
// can no longer each mint and persist a different friend code for it.
export class UserRegistry extends DurableObject {
  async ensureUser(key, name) {
    const storageKey = `chat:user:${key}`;
    let user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (user) {
      const cleaned = name == null ? "" : String(name).trim().slice(0, 80);
      if (cleaned && cleaned !== user.name) {
        user.name = cleaned;
        await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
      }
      return user;
    }
    let friendCode;
    do { friendCode = generateCode(); } while (await this.env.STUDIQUO_DATA.get(`chat:code:${friendCode}`));
    user = { key, name: String(name ?? "").trim().slice(0, 80) || "Studiquoユーザー", code: friendCode, friends: [] };
    await Promise.all([
      this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user)),
      this.env.STUDIQUO_DATA.put(`chat:code:${friendCode}`, key),
    ]);
    return user;
  }

  // Recording a pending request is also routed through this per-key instance
  // (called via getByName(key), the recipient's own key) so that two people
  // requesting the same recipient at nearly the same moment can't each read
  // the same stale incomingRequests array and overwrite one another's
  // addition — the DO's one-at-a-time handling serializes them instead.
  async addIncomingRequest(key, requesterCode, requesterName) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return { status: "not_found" };
    if ((user.friends ?? []).some(item => item.code === requesterCode)) {
      return { status: "already_friends" };
    }
    if (!(user.incomingRequests ?? []).some(item => item.code === requesterCode)) {
      user.incomingRequests = [
        ...(user.incomingRequests ?? []),
        { code: requesterCode, name: requesterName, requestedAt: Date.now() },
      ].slice(-500);
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
    // The recipient's own code/name is already loaded here, so the caller
    // (the requester, recording this on their own outgoingRequests list) can
    // use it without a second KV read.
    return { status: "pending", recipient: { code: user.code, name: user.name } };
  }

  // Lets the requester show "sent, awaiting approval" for their own pending
  // requests. Routed through this per-key instance for the same reason as
  // addIncomingRequest: a requester sending to two different people at
  // nearly the same moment must not have one addition overwrite the other.
  async addOutgoingRequest(key, recipientCode, recipientName) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return;
    if (!(user.outgoingRequests ?? []).some(item => item.code === recipientCode)) {
      user.outgoingRequests = [
        ...(user.outgoingRequests ?? []),
        { code: recipientCode, name: recipientName, requestedAt: Date.now() },
      ].slice(-500);
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
  }

  // Clears a resolved (accepted or rejected) request from the original
  // requester's own outgoingRequests list, keyed by the recipient's code.
  async removeOutgoingRequest(key, recipientCode) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user) return;
    const filtered = (user.outgoingRequests ?? []).filter(item => item.code !== recipientCode);
    if (filtered.length !== (user.outgoingRequests ?? []).length) {
      user.outgoingRequests = filtered;
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    }
  }

  // Accept and reject are both initiated by the recipient (called via
  // getByName(key), the recipient's own key) against their own
  // incomingRequests/friends. Routing both through this one per-key
  // instance closes the race where accept and reject fire for the same
  // pending request at nearly the same moment: without this, both read the
  // same stale record and whichever writes last silently wins — even
  // undoing a friendship the other one just created.
  async resolveIncomingRequest(key, action, otherCode, otherName, roomID) {
    const storageKey = `chat:user:${key}`;
    const user = await this.env.STUDIQUO_DATA.get(storageKey, "json");
    if (!user || !(user.incomingRequests ?? []).some(item => item.code === otherCode)) {
      return { status: "not_found" };
    }
    user.incomingRequests = (user.incomingRequests ?? []).filter(item => item.code !== otherCode);
    if (action === "reject") {
      await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
      return { status: "rejected", recipient: { code: user.code, name: user.name } };
    }
    if ((user.friends ?? []).length >= MAX_FRIENDS) {
      return { status: "friends_full" };
    }
    user.friends = [...(user.friends ?? []).filter(item => item.code !== otherCode), { code: otherCode, name: otherName, roomID }];
    await this.env.STUDIQUO_DATA.put(storageKey, JSON.stringify(user));
    return { status: "accepted", friend: { code: user.code, name: user.name } };
  }
}
