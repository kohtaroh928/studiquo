// Refuses a password that already appears in a public breach corpus, using
// Have I Been Pwned's k-anonymity range API: only the first 5 hex characters
// of the password's SHA-1 leave this Worker, never the password or its full
// hash, and HIBP can't tell which of the ~500 returned suffixes (if any) we
// were after. Per NIST SP 800-63B this, plus a length floor, is the password
// policy — no composition rules, no forced rotation.
//
// Availability beats strictness here: if HIBP is slow, down or returns
// something unreadable, the check is skipped (and logged) rather than
// blocking every signup and password reset behind a third party.

const RANGE_URL = "https://api.pwnedpasswords.com/range/";
const TIMEOUT_MS = 3_000;

async function sha1HexUpper(value) {
  const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
}

/**
 * True if `password` is known to appear in a breach, false if it isn't — or
 * if that couldn't be determined (see above). `fetchImpl` is injectable so
 * tests never touch the network.
 */
export async function isBreachedPassword(password, fetchImpl = fetch) {
  try {
    const hash = await sha1HexUpper(password);
    const prefix = hash.slice(0, 5);
    const suffix = hash.slice(5);
    const response = await fetchImpl(`${RANGE_URL}${prefix}`, {
      // Pads the response with fake entries so its size reveals nothing about the prefix.
      headers: { "Add-Padding": "true" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`HIBP responded ${response.status}`);
    const text = await response.text();
    for (const line of text.split("\n")) {
      const [candidate, count] = line.trim().split(":");
      // Padding entries have a count of 0 and must not count as a match.
      if (candidate === suffix && Number(count) > 0) return true;
    }
    return false;
  } catch (error) {
    console.error(JSON.stringify({ message: "pwned-passwords check skipped", error: error instanceof Error ? error.message : String(error) }));
    return false;
  }
}
