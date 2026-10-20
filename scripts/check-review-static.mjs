import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const pages = new Map(['review.html', 'question-bank.html'].map((path) => [path, read(path)]));

for (const [path, html] of pages) {
  const inlineScripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((match) => match[1])
    .filter((source) => source.trim().length > 0);
  assert.ok(inlineScripts.length > 0, path + ' must contain its page script');
  for (const [index, source] of inlineScripts.entries()) {
    try {
      // Compile only; do not execute browser-dependent page code in Node.
      new Function(source);
    } catch (error) {
      throw new Error(path + ' inline script ' + index + ' has invalid JavaScript: ' + error.message);
    }
  }
}

const review = pages.get('review.html');
const reviewSafeguards = [
  ['server-side answer persistence', 'review_save_answer'],
  ['idempotent attempt start', 'p_request_id:pending.requestId'],
  ['retry the same final submission before trying to save again', 'submissionRetryPending){await submitQuiz();return;'],
  ['freeze the answer payload during ambiguous submission', 'const payload=pendingSubmissionPayload'],
  ['lock answer inputs while submission is unresolved', 'input.disabled=true'],
  ['clear retry state after a valid result', 'submissionRetryPending=false;pendingSubmissionPayload=null;'],
];
for (const [description, needle] of reviewSafeguards) {
  assert.ok(review.includes(needle), 'Missing Review safeguard: ' + description);
}

const questionBank = pages.get('question-bank.html');
const questionBankSafeguards = [
  ['authenticated role lookup', ".from('users_acc_info').select('username,eng_name,chi_name,role')"],
  ['server-side question submission', "rpc('mc_submit_question'"],
  ['server-side moderation', "rpc('mc_moderate_question'"],
  ['server-side suggestion ownership check', "rpc('mc_suggest_question_changes'"],
  ['teacher/admin access gate', "!['teacher','admin'].includes(role)"],
  ['bilingual question stem', 'stem:{en:$('],
];
for (const [description, needle] of questionBankSafeguards) {
  assert.ok(questionBank.includes(needle), 'Missing Question Bank safeguard: ' + description);
}

const enLocale = JSON.parse(read('locales/en.json'));
const zhLocale = JSON.parse(read('locales/zh.json'));
for (const key of ['questionBankTitle', 'questionBankDesc']) {
  assert.ok(enLocale[key] && zhLocale[key], 'Missing bilingual locale key: ' + key);
}

const home = read('index.html');
assert.ok(home.includes("app.navigateToFeature('question-bank.html')"), 'Dashboard must link to Question Bank');
assert.ok(home.includes("questionBankCard.classList.toggle('hidden', !this.isAdminOrTeacher())"), 'Question Bank dashboard card must be role-gated');

console.log('Static checks passed: Review and Question Bank inline JavaScript, 6 Review safeguards, 6 Question Bank safeguards, bilingual locale keys and dashboard access gate.');
