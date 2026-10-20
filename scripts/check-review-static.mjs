import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../review.html', import.meta.url), 'utf8');
const inlineScripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
  .map((match) => match[1])
  .filter((source) => source.trim().length > 0);

assert.ok(inlineScripts.length > 0, 'review.html must contain its page script');
for (const [index, source] of inlineScripts.entries()) {
  try {
    // Compile only; do not execute browser-dependent page code in Node.
    new Function(source);
  } catch (error) {
    throw new Error(`review.html inline script ${index} has invalid JavaScript: ${error.message}`);
  }
}

const requiredSafeguards = [
  ['server-side answer persistence', 'review_save_answer'],
  ['idempotent attempt start', 'p_request_id:pending.requestId'],
  ['retry the same final submission before trying to save again', 'submissionRetryPending){await submitQuiz();return;'],
  ['freeze the answer payload during ambiguous submission', 'const payload=pendingSubmissionPayload'],
  ['lock answer inputs while submission is unresolved', 'input.disabled=true'],
  ['clear retry state after a valid result', 'submissionRetryPending=false;pendingSubmissionPayload=null;'],
];

for (const [description, needle] of requiredSafeguards) {
  assert.ok(html.includes(needle), `Missing Review safeguard: ${description}`);
}

console.log(`Review static checks passed: ${inlineScripts.length} inline script(s), ${requiredSafeguards.length} safeguards.`);
