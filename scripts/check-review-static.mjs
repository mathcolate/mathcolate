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
const exactSql=read('supabase/migrations/20261020180000_exact_rational_sq_grading.sql');
assert.ok(exactSql.includes('mc_exact_numeric_equal'),'SQ grading must compare exact rationals');
assert.ok(exactSql.includes('ln*rd=rn*ld'),'SQ grading must use cross multiplication, not rounded division');
assert.ok(exactSql.includes("v_correct:=public.mc_exact_numeric_equal"),'SQ score calculation must use exact comparison');
const specSql=read('supabase/migrations/20261020191000_spec_alignment_workflows.sql');
assert.ok(specSql.includes("'not_submitted'::public.mc_attempt_state"),'Online Test non-submitters must remain not submitted');
assert.ok(specSql.includes('Preview already completed with full marks'),'Preview must stop retrying at full marks');
assert.ok(specSql.includes("where state='approved'::public.mc_question_state"),'Question IDs are unique when approved, not while pending');
assert.ok(specSql.includes("lp then ld:=ld*100"),'SQ percentage answers must be normalized exactly');
assert.ok(pages.get('question-bank.html').includes("data-decision=\"returned\""),'Moderation UI must support return for revision');
assert.ok(pages.get('question-bank.html').includes("['A','B','C','D','E','F']"),'MC Question Bank must support 2–6 choices');
assert.ok(read('supabase/migrations/20261020192000_question_moderation_return.sql').includes("'returned'::public.mc_question_state"),'Moderation RPC must accept returned state');
console.log('Static checks passed: four page scripts, Review/Question Bank safeguards, Preview/Online Test workflows, exact rational/percentage grading, not-submitted state, full-mark retry rule and moderation return.');

