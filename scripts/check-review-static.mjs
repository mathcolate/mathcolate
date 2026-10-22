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
 ['role lookup',".from('users_acc_info')"],
 ['question submission',"rpc('mc_submit_question'"],
 ['moderation',"rpc('mc_moderate_question'"],
 ['suggestion RPC',"rpc('mc_suggest_question_changes'"],
 ['teacher/admin gate',"!['teacher','admin'].includes(role)"],
 ['bilingual stem','stem:{en:$('],
 ['teacher-owned edit RPC',"rpc('mc_update_pending_question'"],
 ['discard RPC',"rpc('mc_delete_pending_question'"],
 ['teacher-owned queue filter',"query=query.eq('submitted_by',user.id)"],
 ['approved-only browse',"query=query.eq('state','approved')"],
 ['admin browse delete control','data-delete-context="bank"'],
 ['teacher browse read-only',"if(context==='bank'&&admin&&q.state==='approved')actions="],
 ['admin Question ID change refreshes bank','if(b.closest(\'#bank-list\')){if(activeBankTopic)await loadBank(activeBankTopic);else await loadBankTopics();}else await loadModeration();'],
 ['question attachment clear control',"function renderStemImagePreviews()"],
 ['option image state survives language rerender','const previousImages=Array.from(document.querySelectorAll(\'[data-choice-image]\')).map(el=>el.files?.[0]||null);'],
 ['option image remove control','data-remove-choice-image'],
 ['option image preview rendering','function renderChoiceImagePreview(key,file)'],
 ['option image restored after render','input.files=dt.files;}renderChoiceImagePreview(input.dataset.choiceImage,input.files?.[0]||null);'],
 ['individual attachment removal updates FileList','input.files=dt.files;renderStemImagePreviews();'],
 ['attachment previews render selected files','Array.from(input.files||[]).forEach((file,index)=>'],
 ['synced option updates counterpart preview','target.dispatchEvent(new Event(\'input\',{bubbles:true}));'],
 ['browse language refresh uses cached data',"if(!$('tab-bank').classList.contains('hidden')){renderBankTopicMenu();if(activeBankTopic)renderBankQuestions();}"],
 ['browser Back restores Question Bank view and selected topics',"window.addEventListener('popstate',event=>{if(event.state?.questionBankPage)restoreQuestionBankState(event.state);});"],
 ['topic selection state is stored in browser history',"questionBankHistoryState('questions',{questionBankTopics:[...topicIds]})"],
 ['topic selection restored from browser history',"selectedBankTopics=new Set(state.questionBankTopics)"],
 ['browser Back restores the topic selection screen',"state.questionBankView==='questions'&&Array.isArray(state.questionBankTopics)"],
 ['tab state and subview are distinguished',"questionBankView:view"],

 ['Question Bank tabs record browser history',"history.pushState(state,'',location.href)"],
 ['initial Question Bank tab does not add history entry',"setTab('submit','replace');"],
 ['moderation language refresh uses cached data',"if(!$('tab-moderation').classList.contains('hidden'))renderModerationQuestions();"],
 ['explicit math render after browse render','window.MathcolateMath.render(box)'],
 ['remove image button is outside file input label','<div class="block text-sm font-semibold"><label for="stem-images"'],
 ['choice text is math-renderable',`<span class="math-content">'+esc((lang==='zh'?(c.text?.zh||c.text?.en):(c.text?.en||c.text?.zh))||'')+'</span>`]
]) assert.ok(qb.includes(needle),'Missing Question Bank safeguard: '+label);
const submissionSql=read('supabase/migrations/20261022100000_question_submission_edit_delete.sql');
assert.ok(submissionSql.includes('function public.mc_update_pending_question'),'Missing secure question update RPC');
assert.ok(submissionSql.includes('function public.mc_delete_pending_question'),'Missing secure question delete RPC');
assert.ok(submissionSql.includes('v_existing.submitted_by is distinct from v_uid'),'Teacher update must enforce ownership');
assert.ok(submissionSql.includes('v_question.submitted_by is distinct from v_uid'),'Teacher delete must enforce ownership');
for(const key of ['questionBankTitle','questionBankDesc']){
 assert.ok(JSON.parse(read('locales/en.json'))[key]&&JSON.parse(read('locales/zh.json'))[key],'Missing locale key '+key);
}
const home=read('index.html');
assert.ok(!home.includes('id="question-bank-card"'),'Homepage must not show a standalone Question Bank card');
assert.ok(home.includes('id="view-manage"')&&home.includes('data-i18n="btnUpdateQb"')&&home.includes("app.navigateToFeature('question-bank.html')"),'Admin Manage Website must link to Question Bank');
assert.ok(home.includes('id="view-my-school"')&&home.includes('data-i18n="btnUpdateQb"')&&home.includes("app.navigateToFeature('question-bank.html')"),'Teacher My School must link to Question Bank');
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

