/**
 * Unit tests for the pre-transmission helpers.
 *
 * Run: npm test (from the package root; the script lists every suite)
 */

import assert from "node:assert/strict";
import test from "node:test";
import { choosePrewarmMember, headersMatch, isShapeRejection, messagesPrefixEnd, moveMessagesLast, prewarmPrefix, staleClaimMs } from "../lib/prewarm.js";

/** One OpenAI-compatible body with a two-message history and trailing fields. */
const BODY = JSON.stringify({
	model: "deepseek-flash",
	messages: [
		{ role: "system", content: "be brief" },
		{ role: "user", content: "hello" }
	],
	stream: true,
	temperature: 0.2
});

test("finds the end of the last message, not the end of the body", () => {
	const end = messagesPrefixEnd(BODY);
	const prefix = prewarmPrefix(BODY);
	assert.equal(prefix, BODY.slice(0, end));
	assert.ok(prefix.endsWith('"hello"}'), "the prefix stops at the last message");
	assert.ok(!prefix.includes('"stream"'), "the fields after messages are not part of the prefix");

	// The follow-up appends to the history, so the prefix must still hold.
	const followUp = JSON.stringify({
		model: "deepseek-flash",
		messages: [
			{ role: "system", content: "be brief" },
			{ role: "user", content: "hello" },
			{ role: "assistant", content: "hi" }
		],
		stream: true,
		temperature: 0.2
	});
	assert.ok(followUp.startsWith(prefix), "the next request shares the prefix byte for byte");
});

test("is not fooled by braces, brackets, or escaped quotes inside content", () => {
	const body = JSON.stringify({
		messages: [
			{ role: "user", content: 'curly } and [bracket] and an escaped \\" quote' }
		],
		stream: true
	});
	const prefix = prewarmPrefix(body);
	assert.ok(prefix.endsWith("}"), "the prefix ends at the message object");
	const replayed = JSON.parse(`${prefix}]}`);
	assert.equal(replayed.messages.length, 1, "the prefix reparses as one complete message");
	assert.match(replayed.messages[0].content, /escaped \\" quote/u, "escapes survive the scan");
});

test("declines a body with no usable history", () => {
	assert.equal(prewarmPrefix(JSON.stringify({ model: "m", stream: true })), undefined, "no messages key");
	assert.equal(prewarmPrefix(JSON.stringify({ messages: [], stream: true })), undefined, "empty history");
	assert.equal(prewarmPrefix(undefined), undefined);
	assert.equal(prewarmPrefix(42), undefined);
});

test("tolerates whitespace after the messages key", () => {
	const body = '{ "messages" : [ {"role":"user","content":"x"} ], "stream": true }';
	const prefix = prewarmPrefix(body);
	assert.equal(prefix, '{ "messages" : [ {"role":"user","content":"x"}');
});

test("compares headers case-insensitively and rejects any difference", () => {
	const prewarmed = { authorization: "Bearer k", "content-type": "application/json" };
	assert.equal(headersMatch(prewarmed, { Authorization: "Bearer k", "Content-Type": "application/json" }), true);
	assert.equal(headersMatch(prewarmed, { authorization: "Bearer other", "content-type": "application/json" }), false, "a different credential must not reuse the request");
	assert.equal(headersMatch(prewarmed, { authorization: "Bearer k" }), false, "a missing header is a difference");
	assert.equal(headersMatch(prewarmed, { authorization: "Bearer k", "content-type": "application/json", "x-deepseek-harness-compact": "1" }), false, "an added marker is a difference");
	assert.equal(headersMatch(undefined, {}), true, "nothing declared, nothing to contradict");
});

test("only shape rejections are worth resending", () => {
	assert.equal(isShapeRejection(411), true, "Length Required — a chunked body");
	assert.equal(isShapeRejection(415), true, "Unsupported Media Type");
	assert.equal(isShapeRejection(501), true);
	assert.equal(isShapeRejection(400), false, "a real provider answer; the adapter owns it");
	assert.equal(isShapeRejection(429), false, "resending would duplicate a rate-limited call");
	assert.equal(isShapeRejection(200), false);
});

test("reads the conversation from whichever field carries it", () => {
	// Chat-completions and Anthropic bodies use `messages`; Responses-shaped ones
	// use `input`. Both are append-only arrays, so both can share a prefix.
	const messagesBody = JSON.stringify({ model: "m", messages: [{ role: "user", content: "a" }], stream: true });
	const inputBody = JSON.stringify({ model: "m", input: [{ role: "user", content: "a" }], stream: true });
	// The prefix ends with the last element: the closing bracket and the trailing
	// fields are written when the request actually arrives.
	assert.equal(prewarmPrefix(messagesBody), '{"model":"m","messages":[{"role":"user","content":"a"}');
	assert.equal(prewarmPrefix(inputBody), '{"model":"m","input":[{"role":"user","content":"a"}');
});

test("refuses a body whose conversation is not an array", () => {
	// A Responses body may pass `input` as a plain string, which has no
	// append-only structure to share — and a body with neither field is not a
	// conversation at all.
	assert.equal(prewarmPrefix(JSON.stringify({ model: "m", input: "just a prompt" })), undefined);
	assert.equal(prewarmPrefix(JSON.stringify({ model: "m", stream: true })), undefined);
	assert.equal(prewarmPrefix("not json"), undefined);
});

test("moves whichever field carries the conversation to the end", () => {
	const inputBody = JSON.stringify({ model: "m", input: [{ role: "user", content: "a" }], stream: true, tools: [{}] });
	const moved = moveMessagesLast(inputBody);
	assert.notEqual(moved, undefined);
	assert.deepEqual(Object.keys(JSON.parse(moved)), ["model", "stream", "tools", "input"]);
	assert.deepEqual(JSON.parse(moved).input, JSON.parse(inputBody).input, "and the conversation itself is untouched");
	// Already last, or no conversation at all: nothing to do.
	assert.equal(moveMessagesLast(JSON.stringify({ model: "m", input: [] })), undefined);
	assert.equal(moveMessagesLast(JSON.stringify({ model: "m", stream: true })), undefined);
});

test("a member that has sat idle past its stale bound is not claimed", () => {
	const prefix = prewarmPrefix(BODY);
	const url = "https://gateway.example/v1/chat/completions";
	const member = { url, prefix, headers: {}, settled: false, lastWriteAt: 0 };
	const fresh = choosePrewarmMember([member], { url, body: BODY, headers: {}, now: 30_000, staleMs: 60_000 });
	assert.equal(fresh.member, member, "inside the bound the member is still claimable");
	assert.equal(fresh.staleIdleMs, 0, "nothing stale was seen");

	const stale = choosePrewarmMember([member], { url, body: BODY, headers: {}, now: 90_000, staleMs: 60_000 });
	assert.equal(stale.member, undefined, "past the bound it is not claimed");
	assert.equal(stale.staleIdleMs, 90_000, "the age it reached is reported");
});

test("the stale bound is half the hold window, capped at a minute", () => {
	assert.equal(staleClaimMs(120_000), 60_000, "the shipped default lands on a minute");
	assert.equal(staleClaimMs(30_000), 15_000, "a short window halves with it");
	assert.equal(staleClaimMs(600_000), 60_000, "and it never exceeds a minute");
});
