// Shapes of the JSON records the Worker keeps in KV and shares between files.
// Records only one file touches are typed in that file.
import type { AuthenticatorTransportFuture } from "@simplewebauthn/server";

/** account-deletion:<hash>: where an account is in its deletion. */
export interface DeletionState {
  status: "active" | "deleting" | "deleted";
  generation?: number;
  reregisteredAt?: number;
  /** Hashes of the account's identities (older records kept the identities themselves, in identityKeys). */
  identityHashes?: string[];
  identityKeys?: string[];
  /** Provider records that could not be cleared at re-registration and are retried at the next sign-in. */
  pendingCustomerClear?: string[];
  [field: string]: unknown;
}

/** session:<token hash>: one signed-in device's session. */
export interface SessionRecord {
  sub: string;
  issuedAt?: number;
  issuedAtMs?: number;
  /** The identity the session was minted for, when `sub` has since been replaced by the canonical account. */
  originalSub?: string;
  [field: string]: unknown;
}

/** passkeys:credential:<id>, and the entries of passkeys:user:<userKey>. */
export interface PasskeyRecord {
  id: string;
  /** The credential's public key, as bytes. */
  publicKey: number[];
  counter: number;
  transports?: AuthenticatorTransportFuture[];
  email: string;
  userKey: string;
  createdAt?: number;
}

/** passkeys:challenge:<transaction>: a WebAuthn challenge that has been handed out. */
export interface PasskeyChallenge {
  kind: "registration" | "authentication" | "reauth";
  challenge: string;
  /** registration */
  userKey?: string;
  email?: string;
  /** reauth */
  tokenHash?: string;
  action?: string;
}
