begin;
create type public.mc_activity_kind as enum ('preview','online_test');
create type public.mc_activity_state as enum ('draft','published','waiting','in_progress','ended','cancelled');
create type public.mc_attempt_state as enum ('active','submitted','auto_submitted');

create table public.mc_activities(
 id uuid primary key default gen_random_uuid(), kind public.mc_activity_kind not null,
 state public.mc_activity_state not null default 'draft', title jsonb not null,
 instructions jsonb not null default '{}'::jsonb, owner_teacher_id uuid not null references auth.users(id),
 school text not null, target_class_codes text[] not null, due_at timestamptz,
 duration_seconds integer, randomize_questions boolean not null default false,
 randomize_choices boolean not null default false,
 feedback_mode text not null default 'after_activity' check(feedback_mode in ('per_question','after_activity')),
 published_at timestamptz, started_at timestamptz, deadline_at timestamptz,
 cancelled_keep_records boolean, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(jsonb_typeof(title)='object' and nullif(trim(title->>'en'),'') is not null and nullif(trim(title->>'zh'),'') is not null),
 check(jsonb_typeof(instructions)='object'), check(cardinality(target_class_codes)>0),
 check(kind<>'preview' or due_at is not null), check(kind<>'online_test' or duration_seconds>0)
);
create index mc_activities_owner_idx on public.mc_activities(owner_teacher_id,created_at desc);
create index mc_activities_state_deadline_idx on public.mc_activities(state,deadline_at);
create table public.mc_activity_questions(
 activity_id uuid not null references public.mc_activities(id) on delete cascade,
 question_id uuid not null references public.mc_question_bank(id) on delete restrict,
 display_order integer not null check(display_order>0), question_snapshot jsonb, answer_snapshot jsonb,
 max_points integer not null check(max_points>0), primary key(activity_id,display_order), unique(activity_id,question_id)
);
create table public.mc_activity_attempts(
 id uuid primary key default gen_random_uuid(), activity_id uuid not null references public.mc_activities(id) on delete cascade,
 student_id uuid not null references auth.users(id) on delete cascade, attempt_number integer not null default 1,
 state public.mc_attempt_state not null default 'active', started_at timestamptz not null default now(),
 submitted_at timestamptz, is_auto_submitted boolean not null default false, correct_points integer,
 max_points integer not null check(max_points>=0), last_saved_at timestamptz,
 unique(activity_id,student_id,attempt_number), check(correct_points is null or correct_points between 0 and max_points)
);
create unique index mc_online_test_attempt_once on public.mc_activity_attempts(activity_id,student_id)
 where attempt_number=1;
create index mc_activity_attempts_student_idx on public.mc_activity_attempts(student_id,started_at desc);
create table public.mc_attempt_answers(
 attempt_id uuid not null references public.mc_activity_attempts(id) on delete cascade,
 question_order integer not null, subpart_key text not null default '', answer_payload jsonb not null,
 is_correct boolean, awarded_points integer, saved_at timestamptz not null default now(),
 primary key(attempt_id,question_order,subpart_key), check(jsonb_typeof(answer_payload)='object')
);
create index mc_attempt_answers_saved_idx on public.mc_attempt_answers(attempt_id,saved_at desc);
alter table public.mc_activities enable row level security;
alter table public.mc_activity_questions enable row level security;
alter table public.mc_activity_attempts enable row level security;
alter table public.mc_attempt_answers enable row level security;
revoke all on public.mc_activities,public.mc_activity_questions,public.mc_activity_attempts,public.mc_attempt_answers from public,anon,authenticated;

create or replace function public.mc_is_class_member(p_student uuid,p_school text,p_class text)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.users_acc_info u where u.id=p_student and u.role='student'::public.user_role
 and coalesce(u.school,'')=coalesce(p_school,'')
 and p_class=any(regexp_split_to_array(coalesce(u.class_codes,''),E'\\s*,\\s*')));
$$;
revoke all on function public.mc_is_class_member(uuid,text,text) from public,anon,authenticated;

create or replace function public.mc_parse_exact_number(p_value text)
returns numeric language plpgsql immutable set search_path=''
as $$
declare v text:=trim(coalesce(p_value,'')); a numeric; b numeric;
begin
 if v !~ '^[+-]?[0-9]+([.][0-9]+)?$' and v !~ '^[+-]?[0-9]+/[0-9]+$' then return null; end if;
 if position('/' in v)>0 then a:=split_part(v,'/',1)::numeric; b:=split_part(v,'/',2)::numeric; if b=0 then return null; end if; return a/b; end if;
 return v::numeric;
exception when others then return null;
end;
$$;
revoke all on function public.mc_parse_exact_number(text) from public,anon,authenticated;

create or replace function public.mc_create_activity(
 p_kind public.mc_activity_kind,p_title jsonb,p_instructions jsonb,p_target_class_codes text[],
 p_due_at timestamptz,p_duration_seconds integer,p_question_ids uuid[],
 p_randomize_questions boolean default false,p_randomize_choices boolean default false,p_feedback_mode text default 'after_activity')
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_profile public.users_acc_info%rowtype; v_id uuid;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_profile from public.users_acc_info where id=v_uid;
 if v_profile.id is null or v_profile.role not in ('teacher'::public.user_role,'admin'::public.user_role) then raise exception 'Teacher or admin role required' using errcode='42501'; end if;
 if jsonb_typeof(p_title)<>'object' or nullif(trim(p_title->>'en'),'') is null or nullif(trim(p_title->>'zh'),'') is null then raise exception 'Title must include English and Chinese'; end if;
 if coalesce(array_length(p_target_class_codes,1),0)=0 then raise exception 'Select at least one class'; end if;
 if p_kind='preview' and (p_due_at is null or p_due_at<=now()) then raise exception 'Preview deadline must be in the future'; end if;
 if p_kind='online_test' and coalesce(p_duration_seconds,0)<=0 then raise exception 'Online Test duration must be positive'; end if;
 if p_feedback_mode not in ('per_question','after_activity') then raise exception 'Invalid feedback mode'; end if;
 if v_profile.role='teacher'::public.user_role and exists(select 1 from unnest(p_target_class_codes) c where not(trim(c)=any(regexp_split_to_array(coalesce(v_profile.class_codes,''),E'\\s*,\\s*')))) then raise exception 'A teacher may only assign their own classes'; end if;
 if coalesce(array_length(p_question_ids,1),0)=0 then raise exception 'Select at least one question'; end if;
 if exists(select 1 from unnest(p_question_ids) q where not exists(select 1 from public.mc_question_bank b where b.id=q and b.state='approved'::public.mc_question_state)) then raise exception 'All questions must be approved'; end if;
 if (select count(distinct x) from unnest(p_question_ids) x)<>array_length(p_question_ids,1) then raise exception 'Duplicate question selected'; end if;
 insert into public.mc_activities(kind,title,instructions,owner_teacher_id,school,target_class_codes,due_at,duration_seconds,randomize_questions,randomize_choices,feedback_mode)
 values(p_kind,p_title,coalesce(p_instructions,'{}'::jsonb),v_uid,coalesce(v_profile.school,''),array(select trim(c) from unnest(p_target_class_codes) c),p_due_at,p_duration_seconds,coalesce(p_randomize_questions,false),coalesce(p_randomize_choices,false),p_feedback_mode)
 returning id into v_id;
 if p_randomize_questions then
  insert into public.mc_activity_questions(activity_id,question_id,display_order,max_points)
  select v_id,x,row_number() over(order by random())::integer,b.points from unnest(p_question_ids) x join public.mc_question_bank b on b.id=x;
 else
  insert into public.mc_activity_questions(activity_id,question_id,display_order,max_points)
  select v_id,x,ord::integer,b.points from unnest(p_question_ids) with ordinality ids(x,ord) join public.mc_question_bank b on b.id=x;
 end if;
 return v_id;
end;
$$;

create or replace function public.mc_publish_activity(p_activity_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_a public.mc_activities%rowtype; v_count integer;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_a from public.mc_activities where id=p_activity_id and owner_teacher_id=v_uid for update;
 if not found then raise exception 'Activity not found' using errcode='42501'; end if;
 if v_a.state<>'draft' then raise exception 'Only drafts can be published'; end if;
 if v_a.kind='preview' and v_a.due_at<=now() then raise exception 'Preview deadline must be in future'; end if;
 if exists(select 1 from public.mc_activity_questions aq join public.mc_question_bank q on q.id=aq.question_id where aq.activity_id=p_activity_id and q.state<>'approved') then raise exception 'A selected question is no longer approved'; end if;
 update public.mc_activity_questions aq set
 question_snapshot=jsonb_build_object('kind',q.kind,'question_code',q.question_code,'stem',q.stem,
 'choices',case when v_a.randomize_choices and q.kind='MC' then (select jsonb_agg(x.value order by random()) from jsonb_array_elements(q.choices) x(value)) else q.choices end,
 'subparts',q.subparts,'shared_assets',q.shared_assets),
 answer_snapshot=jsonb_build_object('kind',q.kind,'answer_payload',k.answer_payload,'explanation',k.explanation),max_points=q.points
 from public.mc_question_bank q join public.mc_question_answer_keys k on k.question_id=q.id
 where aq.activity_id=p_activity_id and aq.question_id=q.id;
 select count(*) into v_count from public.mc_activity_questions where activity_id=p_activity_id and question_snapshot is not null and answer_snapshot is not null;
 if v_count<>(select count(*) from public.mc_activity_questions where activity_id=p_activity_id) then raise exception 'Question snapshot incomplete'; end if;
 update public.mc_activities set state=case when kind='preview' then 'published'::public.mc_activity_state else 'waiting'::public.mc_activity_state end,published_at=now(),updated_at=now() where id=p_activity_id;
 return jsonb_build_object('activity_id',p_activity_id,'state',case when v_a.kind='preview' then 'published' else 'waiting' end,'question_count',v_count);
end;
$$;

create or replace function public.mc_start_online_test(p_activity_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_a public.mc_activities%rowtype;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_a from public.mc_activities where id=p_activity_id and owner_teacher_id=v_uid for update;
 if not found or v_a.kind<>'online_test' then raise exception 'Online Test not found'; end if;
 if v_a.state='waiting' then update public.mc_activities set state='in_progress',started_at=now(),deadline_at=now()+make_interval(secs=>duration_seconds),updated_at=now() where id=p_activity_id returning * into v_a;
 elsif v_a.state<>'in_progress' then raise exception 'Online Test cannot start in this state'; end if;
 return jsonb_build_object('activity_id',v_a.id,'state',v_a.state,'started_at',v_a.started_at,'deadline_at',v_a.deadline_at);
end;
$$;

create or replace function public.mc_grade_activity_attempt(p_attempt_id uuid,p_auto boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_att public.mc_activity_attempts%rowtype; v_a public.mc_activities%rowtype; q record; ans record;
 v_score integer:=0; v_max integer:=0; v_correct boolean; v_award integer; v_payload jsonb; v_expected jsonb;
 v_val numeric; v_expval numeric; v_unit text; v_expunit text; v_sel text[]; v_exp text[]; v_key text;
begin
 select * into v_att from public.mc_activity_attempts where id=p_attempt_id for update;
 if not found then raise exception 'Attempt not found'; end if;
 if v_att.state<>'active' then return jsonb_build_object('attempt_id',v_att.id,'state',v_att.state,'correct_points',v_att.correct_points,'max_points',v_att.max_points); end if;
 select * into v_a from public.mc_activities where id=v_att.activity_id;
 for q in select * from public.mc_activity_questions where activity_id=v_a.id order by display_order loop
  v_max:=v_max+q.max_points;
  if q.question_snapshot->>'kind'='MC' then
   select a.answer_payload into v_payload from public.mc_attempt_answers a where a.attempt_id=p_attempt_id and a.question_order=q.display_order and a.subpart_key='';
   v_expected:=q.answer_snapshot->'answer_payload'->'correct_options'; v_correct:=false;
   if v_payload is not null and jsonb_typeof(v_payload->'selected_options')='array' and jsonb_typeof(v_expected)='array' then
    select coalesce(array_agg(value order by value),'{}'::text[]) into v_sel from jsonb_array_elements_text(v_payload->'selected_options') vals(value);
    select coalesce(array_agg(value order by value),'{}'::text[]) into v_exp from jsonb_array_elements_text(v_expected) vals(value);
    v_correct:=v_sel=v_exp;
   end if;
   v_award:=case when v_correct then q.max_points else 0 end; v_score:=v_score+v_award;
   update public.mc_attempt_answers set is_correct=v_correct,awarded_points=v_award where attempt_id=p_attempt_id and question_order=q.display_order and subpart_key='';
  else
   for ans in select value from jsonb_array_elements(q.question_snapshot->'subparts') parts(value) loop
    v_key:=ans.value->>'key'; v_payload:=null;
    select a.answer_payload into v_payload from public.mc_attempt_answers a where a.attempt_id=p_attempt_id and a.question_order=q.display_order and a.subpart_key=v_key;
    v_expected:=q.answer_snapshot->'answer_payload'->'parts'->v_key;
    v_val:=public.mc_parse_exact_number(v_payload->>'value'); v_expval:=public.mc_parse_exact_number(v_expected->>'value');
    v_unit:=coalesce(v_payload->>'unit',''); v_expunit:=coalesce(v_expected->>'unit','');
    v_correct:=v_val is not null and v_expval is not null and v_val=v_expval and (not coalesce((ans.value->>'unit_required')::boolean,false) or v_unit=v_expunit);
    v_award:=case when v_correct then coalesce((ans.value->>'points')::integer,0) else 0 end; v_score:=v_score+v_award;
    update public.mc_attempt_answers set is_correct=v_correct,awarded_points=v_award where attempt_id=p_attempt_id and question_order=q.display_order and subpart_key=v_key;
   end loop;
  end if;
 end loop;
 update public.mc_activity_attempts set state=case when p_auto then 'auto_submitted'::public.mc_attempt_state else 'submitted'::public.mc_attempt_state end,
 submitted_at=now(),is_auto_submitted=p_auto,correct_points=v_score,max_points=v_max where id=p_attempt_id;
 return jsonb_build_object('attempt_id',p_attempt_id,'correct_points',v_score,'max_points',v_max,'state',case when p_auto then 'auto_submitted' else 'submitted' end);
end;
$$;
revoke all on function public.mc_grade_activity_attempt(uuid,boolean) from public,anon,authenticated;

create or replace function public.mc_finalize_due_activity(p_activity_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_a public.mc_activities%rowtype; v_id uuid; v_uid uuid;
begin
 select * into v_a from public.mc_activities where id=p_activity_id for update;
 if not found then return; end if;
 if v_a.kind='preview' and v_a.state='published' and now()>=v_a.due_at then
  for v_id in select id from public.mc_activity_attempts where activity_id=v_a.id and state='active' loop perform public.mc_grade_activity_attempt(v_id,true); end loop;
  update public.mc_activities set state='ended',updated_at=now() where id=v_a.id;
 elsif v_a.kind='online_test' and v_a.state='in_progress' and now()>=v_a.deadline_at then
  for v_id in select id from public.mc_activity_attempts where activity_id=v_a.id and state='active' loop perform public.mc_grade_activity_attempt(v_id,true); end loop;
  for v_uid in
   select u.id from public.users_acc_info u
   where u.role='student'::public.user_role and u.school=v_a.school
   and exists(select 1 from unnest(v_a.target_class_codes) c where c=any(regexp_split_to_array(coalesce(u.class_codes,''),E'\\s*,\\s*')))
   and not exists(select 1 from public.mc_activity_attempts x where x.activity_id=v_a.id and x.student_id=u.id)
  loop
   insert into public.mc_activity_attempts(activity_id,student_id,attempt_number,state,submitted_at,is_auto_submitted,correct_points,max_points)
   values(v_a.id,v_uid,1,'auto_submitted',now(),true,0,(select coalesce(sum(max_points),0) from public.mc_activity_questions where activity_id=v_a.id));
  end loop;
  update public.mc_activities set state='ended',updated_at=now() where id=v_a.id;
 end if;
end;
$$;
revoke all on function public.mc_finalize_due_activity(uuid) from public,anon,authenticated;

create or replace function public.mc_list_activities(p_kind public.mc_activity_kind)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_profile public.users_acc_info%rowtype; v_result jsonb; a record;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_profile from public.users_acc_info where id=v_uid;
 if v_profile.id is null then raise exception 'Profile not found' using errcode='42501'; end if;
 if v_profile.role in ('teacher'::public.user_role,'admin'::public.user_role) then
  for a in select id from public.mc_activities where owner_teacher_id=v_uid and kind=p_kind loop perform public.mc_finalize_due_activity(a.id); end loop;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'kind',x.kind,'state',x.state,'title',x.title,'instructions',x.instructions,'target_class_codes',x.target_class_codes,'due_at',x.due_at,'duration_seconds',x.duration_seconds,'started_at',x.started_at,'deadline_at',x.deadline_at,'created_at',x.created_at,'question_count',(select count(*) from public.mc_activity_questions q where q.activity_id=x.id)) order by x.created_at desc),'[]'::jsonb)
  into v_result from public.mc_activities x where x.owner_teacher_id=v_uid and x.kind=p_kind and x.state<>'cancelled';
 else
  for a in select x.id from public.mc_activities x where x.kind=p_kind and x.state in ('published','waiting','in_progress') and exists(select 1 from unnest(x.target_class_codes) c where public.mc_is_class_member(v_uid,x.school,c)) loop perform public.mc_finalize_due_activity(a.id); end loop;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'kind',x.kind,'state',x.state,'title',x.title,'instructions',x.instructions,'due_at',x.due_at,'duration_seconds',x.duration_seconds,'started_at',x.started_at,'deadline_at',x.deadline_at,'created_at',x.created_at,'question_count',(select count(*) from public.mc_activity_questions q where q.activity_id=x.id),'my_attempt_state',att.state,'my_attempt_id',att.id,'best_points',(select max(t.correct_points) from public.mc_activity_attempts t where t.activity_id=x.id and t.student_id=v_uid),'best_max_points',(select max(t.max_points) from public.mc_activity_attempts t where t.activity_id=x.id and t.student_id=v_uid)) order by x.created_at desc),'[]'::jsonb)
  into v_result from public.mc_activities x
  left join lateral(select y.id,y.state from public.mc_activity_attempts y where y.activity_id=x.id and y.student_id=v_uid order by y.attempt_number desc limit 1) att on true
  where x.kind=p_kind and x.state in ('published','waiting','in_progress','ended') and exists(select 1 from unnest(x.target_class_codes) c where public.mc_is_class_member(v_uid,x.school,c))
    and (p_kind='online_test' or x.due_at>now() or att.id is not null);
 end if;
 return coalesce(v_result,'[]'::jsonb);
end;
$$;

create or replace function public.mc_start_activity_attempt(p_activity_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_profile public.users_acc_info%rowtype; v_a public.mc_activities%rowtype; v_att public.mc_activity_attempts%rowtype; v_q jsonb;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_profile from public.users_acc_info where id=v_uid and role='student'::public.user_role;
 if not found then raise exception 'Student role required' using errcode='42501'; end if;
 select * into v_a from public.mc_activities where id=p_activity_id for update;
 if not found then raise exception 'Activity not found'; end if;
 if not exists(select 1 from unnest(v_a.target_class_codes) c where public.mc_is_class_member(v_uid,v_a.school,c)) then raise exception 'You are not in the target class'; end if;
 if v_a.kind='preview' then
  if v_a.state<>'published' or now()>v_a.due_at then raise exception 'Preview is not available'; end if;
 else
  if v_a.state<>'in_progress' or now()>v_a.deadline_at then raise exception 'Online Test is not in progress'; end if;
  select * into v_att from public.mc_activity_attempts where activity_id=p_activity_id and student_id=v_uid for update;
  if found then
   if v_att.state<>'active' then raise exception 'This Online Test has already been submitted'; end if;
   select jsonb_agg(jsonb_build_object('display_order',q.display_order,'question',q.question_snapshot) order by q.display_order) into v_q from public.mc_activity_questions q where q.activity_id=p_activity_id;
   return jsonb_build_object('attempt_id',v_att.id,'deadline_at',v_a.deadline_at,'questions',coalesce(v_q,'[]'::jsonb),
    'saved_answers',coalesce((select jsonb_agg(jsonb_build_object('question_order',aa.question_order,'subpart_key',aa.subpart_key,'answer_payload',aa.answer_payload)) from public.mc_attempt_answers aa where aa.attempt_id=v_att.id),'[]'::jsonb));
  end if;
 end if;
 select * into v_att from public.mc_activity_attempts where activity_id=p_activity_id and student_id=v_uid and state='active' order by attempt_number desc limit 1 for update;
 if found then
  select jsonb_agg(jsonb_build_object('display_order',q.display_order,'question',q.question_snapshot) order by q.display_order) into v_q from public.mc_activity_questions q where q.activity_id=p_activity_id;
  return jsonb_build_object('attempt_id',v_att.id,'deadline_at',coalesce(v_a.deadline_at,v_a.due_at),'questions',coalesce(v_q,'[]'::jsonb),
   'saved_answers',coalesce((select jsonb_agg(jsonb_build_object('question_order',aa.question_order,'subpart_key',aa.subpart_key,'answer_payload',aa.answer_payload)) from public.mc_attempt_answers aa where aa.attempt_id=v_att.id),'[]'::jsonb));
 end if;
 insert into public.mc_activity_attempts(activity_id,student_id,attempt_number,max_points)
 values(p_activity_id,v_uid,coalesce((select max(attempt_number)+1 from public.mc_activity_attempts where activity_id=p_activity_id and student_id=v_uid),1),(select coalesce(sum(max_points),0) from public.mc_activity_questions where activity_id=p_activity_id))
 returning * into v_att;
 select jsonb_agg(jsonb_build_object('display_order',q.display_order,'question',q.question_snapshot) order by q.display_order) into v_q from public.mc_activity_questions q where q.activity_id=p_activity_id;
 return jsonb_build_object('attempt_id',v_att.id,'deadline_at',coalesce(v_a.deadline_at,v_a.due_at),'questions',coalesce(v_q,'[]'::jsonb));
end;
$$;

create or replace function public.mc_save_activity_answer(p_attempt_id uuid,p_question_order integer,p_subpart_key text,p_answer_payload jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_att public.mc_activity_attempts%rowtype; v_a public.mc_activities%rowtype; v_q public.mc_activity_questions%rowtype;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 if jsonb_typeof(p_answer_payload)<>'object' then raise exception 'Answer must be a JSON object'; end if;
 select * into v_att from public.mc_activity_attempts where id=p_attempt_id and student_id=v_uid for update;
 if not found then raise exception 'Attempt not found' using errcode='42501'; end if;
 if v_att.state<>'active' then raise exception 'Attempt is already submitted'; end if;
 select * into v_a from public.mc_activities where id=v_att.activity_id;
 if v_a.kind='preview' and now()>v_a.due_at then raise exception 'Preview deadline has passed'; end if;
 if v_a.kind='online_test' and (v_a.state<>'in_progress' or now()>v_a.deadline_at) then raise exception 'Online Test deadline has passed'; end if;
 if not exists(select 1 from unnest(v_a.target_class_codes) c where public.mc_is_class_member(v_uid,v_a.school,c)) then raise exception 'Class membership changed'; end if;
 select * into v_q from public.mc_activity_questions where activity_id=v_att.activity_id and display_order=p_question_order;
 if not found then raise exception 'Question not found'; end if;
 if coalesce(p_subpart_key,'')<>'' and not exists(select 1 from jsonb_array_elements(v_q.question_snapshot->'subparts') p(value) where p.value->>'key'=p_subpart_key) then raise exception 'Subpart not found'; end if;
 if v_q.question_snapshot->>'kind'='MC' and p_subpart_key<>'' then raise exception 'MC answer cannot have subpart key'; end if;
 if v_q.question_snapshot->>'kind'='MC' and jsonb_typeof(p_answer_payload->'selected_options') is distinct from 'array' then raise exception 'MC answer must include selected_options array'; end if;
 insert into public.mc_attempt_answers(attempt_id,question_order,subpart_key,answer_payload,saved_at)
 values(p_attempt_id,p_question_order,coalesce(p_subpart_key,''),p_answer_payload,now())
 on conflict(attempt_id,question_order,subpart_key) do update set answer_payload=excluded.answer_payload,saved_at=excluded.saved_at,is_correct=null,awarded_points=null;
 update public.mc_activity_attempts set last_saved_at=now() where id=p_attempt_id;
 return jsonb_build_object('saved',true,'saved_at',now());
end;
$$;

create or replace function public.mc_activity_result(p_attempt_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_att public.mc_activity_attempts%rowtype; v_a public.mc_activities%rowtype;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_att from public.mc_activity_attempts where id=p_attempt_id;
 if not found then raise exception 'Attempt not found'; end if;
 select * into v_a from public.mc_activities where id=v_att.activity_id;
 if v_a.owner_teacher_id<>v_uid and v_att.student_id<>v_uid then raise exception 'Not allowed' using errcode='42501'; end if;
 if v_att.state='active' then
  if v_a.owner_teacher_id=v_uid then return jsonb_build_object('attempt_id',v_att.id,'activity_id',v_a.id,'state',v_att.state,'saved_questions',(select count(distinct question_order) from public.mc_attempt_answers where attempt_id=v_att.id),'max_points',v_att.max_points); end if;
  raise exception 'Result not released yet';
 end if;
 return jsonb_build_object('attempt_id',v_att.id,'activity_id',v_a.id,'state',v_att.state,'correct_points',v_att.correct_points,'max_points',v_att.max_points,'submitted_at',v_att.submitted_at,'is_auto_submitted',v_att.is_auto_submitted,
  'answers',coalesce((select jsonb_agg(jsonb_build_object('display_order',q.display_order,'question',q.question_snapshot,'answer',a.answer_payload,'is_correct',a.is_correct,'awarded_points',a.awarded_points,'correct_answer',q.answer_snapshot->'answer_payload','explanation',q.answer_snapshot->'explanation') order by q.display_order,a.subpart_key) from public.mc_activity_questions q left join public.mc_attempt_answers a on a.attempt_id=v_att.id and a.question_order=q.display_order where q.activity_id=v_a.id),'[]'::jsonb));
end;
$$;

create or replace function public.mc_submit_activity(p_attempt_id uuid,p_auto_submit boolean default false)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_att public.mc_activity_attempts%rowtype; v_a public.mc_activities%rowtype; v_auto boolean:=p_auto_submit;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_att from public.mc_activity_attempts where id=p_attempt_id and student_id=v_uid for update;
 if not found then raise exception 'Attempt not found' using errcode='42501'; end if;
 select * into v_a from public.mc_activities where id=v_att.activity_id;
 if v_att.state<>'active' then return public.mc_activity_result(p_attempt_id); end if;
 if v_a.kind='preview' and now()>=v_a.due_at then v_auto:=true; end if;
 if v_a.kind='online_test' and now()>=v_a.deadline_at then v_auto:=true; end if;
 if p_auto_submit and not v_auto then raise exception 'Deadline has not passed'; end if;
 if not v_auto and v_a.kind='online_test' and v_a.state<>'in_progress' then raise exception 'Online Test is not active'; end if;
 if not exists(select 1 from unnest(v_a.target_class_codes) c where public.mc_is_class_member(v_uid,v_a.school,c)) then raise exception 'Class membership changed'; end if;
 perform public.mc_grade_activity_attempt(p_attempt_id,v_auto);
 perform public.mc_finalize_due_activity(v_a.id);
 return public.mc_activity_result(p_attempt_id);
end;
$$;

create or replace function public.mc_teacher_activity_overview(p_activity_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_a public.mc_activities%rowtype; v_students jsonb; v_hist jsonb;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_a from public.mc_activities where id=p_activity_id and owner_teacher_id=v_uid;
 if not found then raise exception 'Activity not found' using errcode='42501'; end if;
 perform public.mc_finalize_due_activity(v_a.id);
 select * into v_a from public.mc_activities where id=p_activity_id;
 select coalesce(jsonb_agg(jsonb_build_object('student_id',u.id,'username',u.username,'name',coalesce(nullif(u.eng_name,''),u.username),'state',att.state,'started_at',att.started_at,'submitted_at',att.submitted_at,'last_saved_at',att.last_saved_at,'score',case when att.state in ('submitted'::public.mc_attempt_state,'auto_submitted'::public.mc_attempt_state) then att.correct_points else null end,'max_points',att.max_points,'progress',case when att.id is null then 0 else least(100,(select count(distinct a.question_order) from public.mc_attempt_answers a where a.attempt_id=att.id)::numeric/greatest((select count(*) from public.mc_activity_questions q where q.activity_id=v_a.id),1)*100) end) order by u.username),'[]'::jsonb)
 into v_students from public.users_acc_info u left join public.mc_activity_attempts att on att.activity_id=v_a.id and att.student_id=u.id
 where u.role='student'::public.user_role and u.school=v_a.school and exists(select 1 from unnest(v_a.target_class_codes) c where c=any(regexp_split_to_array(coalesce(u.class_codes,''),E'\\s*,\\s*')));
 if v_a.kind='online_test' then
  select coalesce(jsonb_agg(jsonb_build_object('score',bucket,'count',n) order by bucket),'[]'::jsonb) into v_hist
  from (
   select coalesce(round((att.correct_points::numeric/greatest(att.max_points,1))*100)::integer,0) bucket,count(*) n
   from public.users_acc_info u
   left join public.mc_activity_attempts att on att.activity_id=v_a.id and att.student_id=u.id
   where u.role='student'::public.user_role and u.school=v_a.school
    and exists(select 1 from unnest(v_a.target_class_codes) c where c=any(regexp_split_to_array(coalesce(u.class_codes,''),E'\\s*,\\s*')))
    and (v_a.state='ended' or att.state in ('submitted'::public.mc_attempt_state,'auto_submitted'::public.mc_attempt_state))
   group by 1
  ) h;
 else v_hist:='[]'::jsonb; end if;
 return jsonb_build_object('activity_id',v_a.id,'state',v_a.state,'started_at',v_a.started_at,'deadline_at',v_a.deadline_at,'students',v_students,'histogram',v_hist);
end;
$$;

revoke all on function public.mc_create_activity(public.mc_activity_kind,jsonb,jsonb,text[],timestamptz,integer,uuid[],boolean,boolean,text) from public,anon;
revoke all on function public.mc_publish_activity(uuid) from public,anon;
revoke all on function public.mc_start_online_test(uuid) from public,anon;
revoke all on function public.mc_list_activities(public.mc_activity_kind) from public,anon;
revoke all on function public.mc_start_activity_attempt(uuid) from public,anon;
revoke all on function public.mc_save_activity_answer(uuid,integer,text,jsonb) from public,anon;
revoke all on function public.mc_activity_result(uuid) from public,anon;
revoke all on function public.mc_submit_activity(uuid,boolean) from public,anon;
revoke all on function public.mc_teacher_activity_overview(uuid) from public,anon;
grant execute on function public.mc_create_activity(public.mc_activity_kind,jsonb,jsonb,text[],timestamptz,integer,uuid[],boolean,boolean,text) to authenticated;
grant execute on function public.mc_publish_activity(uuid) to authenticated;
grant execute on function public.mc_start_online_test(uuid) to authenticated;
grant execute on function public.mc_list_activities(public.mc_activity_kind) to authenticated;
grant execute on function public.mc_start_activity_attempt(uuid) to authenticated;
grant execute on function public.mc_save_activity_answer(uuid,integer,text,jsonb) to authenticated;
grant execute on function public.mc_activity_result(uuid) to authenticated;
grant execute on function public.mc_submit_activity(uuid,boolean) to authenticated;
grant execute on function public.mc_teacher_activity_overview(uuid) to authenticated;
commit;