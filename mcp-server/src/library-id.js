// The opaque id the app keeps one on-device library per account under.
//
// It is made at random and kept in a Durable Object (UserRegistry.libraryID),
// one per account, named by a hash of the account's canonical identity. The
// name is internal and never leaves the server; the id handed to the app is the
// random value, so it says nothing about the account, cannot be worked out from
// an e-mail address, and needs no secret key to protect. When the account is
// deleted the object's id is erased, so signing up again gives a new one.
export function libraryIdObjectName(canonicalIdentityHash) {
  return `library-id:${canonicalIdentityHash}`;
}

// 64 lowercase hex characters from 32 random bytes.
export function newLibraryID() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, "0")).join("");
}

// Kept in the object's own storage under one key. The Durable Object runs one
// request at a time on a strongly consistent store; blockConcurrencyWhile keeps
// a second first-request from slipping in between the read and the write.
export async function getOrCreateLibraryID(ctx) {
  const existing = await ctx.storage.get("libraryID");
  if (existing) return existing;
  return ctx.blockConcurrencyWhile(async () => {
    const saved = await ctx.storage.get("libraryID");
    if (saved) return saved;
    const id = newLibraryID();
    await ctx.storage.put("libraryID", id);
    return id;
  });
}

export async function eraseLibraryID(ctx) {
  await ctx.storage.delete("libraryID");
}
