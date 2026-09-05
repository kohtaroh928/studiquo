import assert from "node:assert/strict";
import test from "node:test";
import { isExpired } from "./token.js";

function tokenIssuedSecondsAgo(seconds) {
  const issuedAt = Math.floor(Date.now() / 1000) - seconds;
  return `${issuedAt}.deadbeef`;
}

test("a freshly issued token is not expired", () => {
  assert.equal(isExpired(tokenIssuedSecondsAgo(0)), false);
});

test("a token just under 90 days old is not expired", () => {
  const eightyNineDays = 89 * 24 * 60 * 60;
  assert.equal(isExpired(tokenIssuedSecondsAgo(eightyNineDays)), false);
});

test("a token older than 90 days is expired", () => {
  const ninetyOneDays = 91 * 24 * 60 * 60;
  assert.equal(isExpired(tokenIssuedSecondsAgo(ninetyOneDays)), true);
});

test("a token with no embedded issue date is treated as expired", () => {
  assert.equal(isExpired("plainrandomtokenwithnodot"), true);
  assert.equal(isExpired(""), true);
});

test("a token with a garbage issue date is treated as expired", () => {
  assert.equal(isExpired("not-a-number.deadbeef"), true);
});
