import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = (path) => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const pagePaths = ['review.html','question-bank.html','preview.html','online-test.html'];
const pages = new Map(pagePaths.map((path) => [path, read(path)]));
for (const [path, html] of pages) {
  const inline = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(m=>m[1]).filter(s=>s.trim());
  assert.ok(inline.length, path + ' must have inline JavaScript');
  for (const [i, source] of inline.entries()) {
    try { new Function(source); } catch (e) { throw new Error(path + ' inline script ' + i + ': ' + e.message); }
  }
}
const review=pages.get('review.html');
for(const [label,needle] of [
 ['answer persistence','review_save_answer'],
 ['idempotent start','p_request_id:pending.requestId'],
 ['submit retry before saving','submissionRetryPending){await submitQuiz();return;'],
 ['frozen submission payload','const payload=pendingSubmissionPayload'],
 ['inputs locked while submit is pending','input.disabled=true'],
 ['retry state reset after success','submissionRetryPending=false;pendingSubmissionPayload=null;']
]) assert.ok(review.includes(needle),'Missing Review safeguard: '+label);
const qb=pages.get('question-bank.html');
for(const [label,needle] of [
 ['role lookup',".from('users_acc_info').select('username,eng_name,chi_name,role')"],
 ['question submission',"rpc('mc_submit_question'"],
 ['moderation',"rpc('mc_moderate_question'"],
 ['suggestion RPC',"rpc('mc_suggest_question_changes'"],
 ['teacher/admin gate',"!['teacher','admin'].includes(role)"],
 ['bilingual stem','stem:{en:$(']
]) assert.ok(qb.includes(needle),'Missing Question Bank safeguard: '+label);
for(const key of ['questionBankTitle','questionBankDesc']){
 assert.ok(JSON.parse(read('locales/en.json'))[key]&&JSON.parse(read('locales/zh.json'))[key],'Missing locale key '+key);
}
const home=read('index.html');
assert.ok(home.includes("app.navigateToFeature('question-bank.html')"),'Dashboard must link to Question Bank');
assert.ok(home.includes("questionBankCard.classList.toggle('hidden', !this.isAdminOrTeacher())"),'Question Bank link must be role-gated');
for(const path of ['preview.html','online-test.html']){
 const html=pages.get(path);
 for(const needle of ["rpc('mc_create_activity'","rpc('mc_publish_activity'","rpc('mc_start_activity_attempt'","rpc('mc_save_activity_answer'","rpc('mc_submit_activity'","rpc('mc_teacher_activity_overview'"]){
  assert.ok(html.includes(needle),path+' missing workflow '+needle);
 }
 assert.ok(html.includes('deadlineAutoSubmitStarted'),path+' must auto-submit when the deadline is reached');
 assert.ok(html.includes('saved_answers'),path+' must restore saved answers');
}
const activitySql=read('supabase/migrations/20261020160000_activity_workflows.sql');
for(const fn of ['mc_create_activity','mc_publish_activity','mc_start_online_test','mc_start_activity_attempt','mc_save_activity_answer','mc_submit_activity','mc_finalize_due_activity','mc_teacher_activity_overview'])
 assert.ok(activitySql.includes('function public.'+fn),'Missing activity RPC '+fn);
assert.ok(activitySql.includes('mc_parse_exact_number'),'SQ grading must use exact numeric parsing');
assert.ok(activitySql.includes('revoke all on public.mc_activities,public.mc_activity_questions,public.mc_activity_attempts,public.mc_attempt_answers from public,anon,authenticated'),'Attempt answers must not be directly exposed');
const validation=read('supabase/migrations/20261020170000_question_answer_validation.sql');
assert.ok(validation.includes('sum of SQ subpart points'),'SQ point total validation is required');
console.log('Static checks passed: four page scripts, Review safeguards, Question Bank role/locale checks, Preview/Online Test RPC wiring, deadline auto-submit and schema safeguards.');
