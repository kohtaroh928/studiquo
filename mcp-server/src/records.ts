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
  /** Kept while a deletion is under way so a retry can finish it. */
  emails?: string[];
  deletionKeys?: string[];
  tokenHashes?: string[];
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

/** An entry of a person's friend list. */
export interface FriendEntry {
  code: string;
  name: string;
  /** The direct-message room shared with this friend. */
  roomID?: string;
  [field: string]: unknown;
}

/** An entry of a person's group list or group-invite list. */
export interface GroupEntry {
  code: string;
  name: string;
  roomID?: string;
  updatedAt?: number | string;
  avatarUpdatedAt?: number | string | null;
  [field: string]: unknown;
}

/** chat:user:<key>: a person's chat profile with their friends and groups. */
export interface ChatUser {
  code: string;
  name: string;
  linkToken?: string;
  bio?: string | null;
  todayStudySeconds?: number;
  studyDate?: string | null;
  avatarUpdatedAt?: number | string | null;
  friends?: FriendEntry[];
  incomingRequests?: FriendEntry[];
  outgoingRequests?: FriendEntry[];
  groups?: GroupEntry[];
  incomingGroupInvites?: GroupEntry[];
  [field: string]: unknown;
}

/** An image kept as base64 text: chat:avatar:<code>, group avatars, report screenshots. */
export interface StoredImage {
  contentType: string;
  data: string;
  updatedAt?: number | string;
}

/** issue-report:<id>: a hand-written problem report, until it is moved to D1 (and for its screenshot). */
export interface IssueReportRecord {
  id: string;
  description: string;
  reporterKey?: string;
  accountKey?: string | null;
  appVersion?: string;
  osVersion?: string;
  deviceModel?: string;
  language?: string;
  hasScreenshot?: boolean;
  createdAt?: number;
}

/** privacy-account-delete:<hash>: a queued account deletion. */
export interface DeletionJob {
  canonicalSub: string;
  requestedAt: number;
  generation?: number;
}
