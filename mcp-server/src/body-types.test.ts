import assert from "node:assert/strict";
import test from "node:test";
import { bodyNumber, bodyText, InvalidBodyError, invalidBodyResponse } from "./http.ts";

const poison = JSON.parse('{"toString":{}}');

test("bodyText passes text, numbers and booleans as String() did, and refuses objects and arrays", () => {
  assert.equal(bodyText("abc"), "abc");
  assert.equal(bodyText(12), "12");
  assert.equal(bodyText(true), "true");
  assert.equal(bodyText(undefined), "");
  assert.equal(bodyText(null, null), null);
  assert.throws(() => bodyText(poison), InvalidBodyError);
  assert.throws(() => bodyText([]), InvalidBodyError);
  assert.equal(invalidBodyResponse(new InvalidBodyError())?.status, 400);
  assert.equal(invalidBodyResponse(new Error("x")), null);
});

test("bodyNumber converts like Number() but never throws on an object", () => {
  assert.equal(bodyNumber(5), 5);
  assert.equal(bodyNumber("7"), 7);
  assert.equal(bodyNumber(undefined), NaN);
  assert.ok(Number.isNaN(bodyNumber(poison)));
  assert.ok(Number.isNaN(bodyNumber([1])));
  assert.throws(() => Number(poison), TypeError); // why the helper exists
});
