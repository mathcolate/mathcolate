begin;
drop index if exists public.mc_question_bank_code_ci_uidx;
create unique index mc_question_bank_code_ci_uidx on public.mc_question_bank(lower(question_code)) where state='approved'::public.mc_question_state;
create or replace function public.mc_audit_question_code_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role;
begin
  if new.question_code is distinct from old.question_code then
    select u.role into v_role from public.users_acc_info u where u.id = (select auth.uid());
    if v_role is distinct from 'admin'::public.user_role and not (new.submitted_by=(select auth.uid()) and old.state in ('pending'::public.mc_question_state,'returned'::public.mc_question_state)) then
      raise exception 'Only the owner of an unapproved question or an admin may change a Question ID' using errcode = '42501';
    end if;
    if v_role='admin'::public.user_role then insert into public.mc_question_id_changes(question_id, old_code, new_code, admin_id) values (old.id, old.question_code, new.question_code, (select auth.uid())); end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create or replace function public.mc_moderate_question(
  p_question_id uuid,
  p_decision public.mc_question_state,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  if v_role is distinct from 'admin'::public.user_role then raise exception 'Admin role required' using errcode = '42501'; end if;
  if p_decision not in ('approved'::public.mc_question_state, 'returned'::public.mc_question_state, 'rejected'::public.mc_question_state, 'disabled'::public.mc_question_state) then
    raise exception 'Invalid moderation decision';
  end if;
  update public.mc_question_bank
  set state = p_decision, reviewed_by = v_uid, reviewed_at = now(), review_reason = nullif(trim(p_reason),'')
  where id = p_question_id;
  if not found then raise exception 'Question not found'; end if;
end;
$$;
create or replace function public.mc_exact_numeric_equal(p_left text,p_right text)
returns boolean language plpgsql immutable set search_path=''
as $$
declare l text:=regexp_replace(trim(coalesce(p_left,'')),'[[:space:]]*%$','%'); r text:=regexp_replace(trim(coalesce(p_right,'')),'[[:space:]]*%$','%'); ln numeric; ld numeric:=1; rn numeric; rd numeric:=1; dotpos integer; lp boolean:=false; rp boolean:=false;
begin
 lp:=right(l,1)='%'; rp:=right(r,1)='%'; if lp then l:=left(l,length(l)-1); end if; if rp then r:=left(r,length(r)-1); end if;
 if (l !~ '^[+-]?[0-9]+([.][0-9]+)?$' and l !~ '^[+-]?[0-9]+/[0-9]+$') or (r !~ '^[+-]?[0-9]+([.][0-9]+)?$' and r !~ '^[+-]?[0-9]+/[0-9]+$') then return false; end if;
 if position('/' in l)>0 then ln:=split_part(l,'/',1)::numeric; ld:=split_part(l,'/',2)::numeric; if ld=0 then return false; end if;
 else ln:=l::numeric; dotpos:=position('.' in l); if dotpos>0 then ld:=power(10,length(l)-dotpos); ln:=ln*ld; end if; end if;
 if position('/' in r)>0 then rn:=split_part(r,'/',1)::numeric; rd:=split_part(r,'/',2)::numeric; if rd=0 then return false; end if;
 else rn:=r::numeric; dotpos:=position('.' in r); if dotpos>0 then rd:=power(10,length(r)-dotpos); rn:=rn*rd; end if; end if;
 if lp then ld:=ld*100; end if; if rp then rd:=rd*100; end if; return ln*rd=rn*ld;
exception when others then return false;
end;
$$;
revoke all on function public.mc_exact_numeric_equal(text,text) from public,anon,authenticated;

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
    v_correct:=public.mc_exact_numeric_equal(v_payload->>'value',v_expected->>'value') and (not coalesce((ans.value->>'unit_required')::boolean,false) or v_unit=v_expunit);
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
  update public.mc_activity_attempts set state='not_submitted'::public.mc_attempt_state,correct_points=0,is_auto_submitted=false,submitted_at=null where activity_id=v_a.id and state='active';
  for v_uid in
   select u.id from public.users_acc_info u
   where u.role='student'::public.user_role and u.school=v_a.school
   and exists(select 1 from unnest(v_a.target_class_codes) c where c=any(regexp_split_to_array(coalesce(u.class_codes,''),E'\\s*,\\s*')))
   and not exists(select 1 from public.mc_activity_attempts x where x.activity_id=v_a.id and x.student_id=u.id)
  loop
   insert into public.mc_activity_attempts(activity_id,student_id,attempt_number,state,submitted_at,is_auto_submitted,correct_points,max_points)
   values(v_a.id,v_uid,1,'not_submitted',null,false,0,(select coalesce(sum(max_points),0) from public.mc_activity_questions where activity_id=v_a.id));
  end loop;
  update public.mc_activities set state='ended',updated_at=now() where id=v_a.id;
 end if;
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
  if exists(select 1 from public.mc_activity_attempts x where x.activity_id=v_a.id and x.student_id=v_uid and x.state in ('submitted'::public.mc_attempt_state,'auto_submitted'::public.mc_attempt_state) and x.correct_points>=x.max_points) then raise exception 'Preview already completed with full marks'; end if;
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
create or replace function public.mc_submit_question(
  p_question jsonb,
  p_answer_key jsonb,
  p_topic_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
  v_question_id uuid;
  v_code text;
  v_kind public.mc_question_kind;
  v_stem jsonb;
  v_choices jsonb;
  v_subparts jsonb;
  v_assets jsonb;
  v_points integer;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  if v_role is null or v_role not in ('teacher'::public.user_role, 'admin'::public.user_role) then
    raise exception 'Teacher or admin role required' using errcode = '42501';
  end if;
  if jsonb_typeof(p_question) <> 'object' or jsonb_typeof(p_answer_key) <> 'object' then
    raise exception 'Question and answer key must be JSON objects';
  end if;
  v_code := nullif(trim(p_question->>'question_code'), '');
  if v_code is null then raise exception 'Question ID is required'; end if;
  v_kind := (p_question->>'kind')::public.mc_question_kind;
  v_stem := p_question->'stem';
  v_choices := coalesce(p_question->'choices', '[]'::jsonb);
  v_subparts := coalesce(p_question->'subparts', '[]'::jsonb);
  v_assets := coalesce(p_question->'shared_assets', '[]'::jsonb);
  v_points := coalesce((p_question->>'points')::integer, 1);
  if jsonb_typeof(v_stem) <> 'object' or nullif(trim(coalesce(v_stem->>'en','')), '') is null or nullif(trim(coalesce(v_stem->>'zh','')), '') is null then
    raise exception 'Question stem is required in English and Chinese';
  end if;
  if jsonb_typeof(v_choices) <> 'array' or jsonb_typeof(v_subparts) <> 'array' or jsonb_typeof(v_assets) <> 'array' then
    raise exception 'Choices, subparts and shared assets must be arrays';
  end if;
  if v_points < 1 then raise exception 'Points must be a positive integer'; end if;
  if v_kind = 'MC' and jsonb_array_length(v_choices) < 2 then raise exception 'MC questions need at least two choices'; end if;
  if p_answer_key->'answer_payload' is null or jsonb_typeof(p_answer_key->'answer_payload') <> 'object' or p_answer_key->'answer_payload' = '{}'::jsonb then
    raise exception 'A non-empty answer payload is required';
  end if;
  if jsonb_typeof(coalesce(p_answer_key->'explanation','{}'::jsonb)) <> 'object' then raise exception 'Explanation must be a JSON object'; end if;
  if v_kind = 'MC' then
    if jsonb_array_length(v_choices) < 2 then raise exception 'MC questions need at least two choices'; end if;
    if exists (
      select 1 from jsonb_array_elements(v_choices) choice(value)
      where nullif(trim(coalesce(choice.value->>'key','')), '') is null
         or jsonb_typeof(choice.value->'text') <> 'object'
         or nullif(trim(coalesce(choice.value->'text'->>'en','')), '') is null
         or nullif(trim(coalesce(choice.value->'text'->>'zh','')), '') is null
    ) then raise exception 'Every MC choice needs a key and bilingual text'; end if;
    if (select count(*) from jsonb_array_elements(v_choices)) <>
       (select count(distinct choice.value->>'key') from jsonb_array_elements(v_choices) choice(value)) then
      raise exception 'MC choice keys must be unique';
    end if;
    if jsonb_typeof(p_answer_key->'answer_payload'->'correct_options') <> 'array'
       or jsonb_array_length(p_answer_key->'answer_payload'->'correct_options') = 0 then
      raise exception 'MC answer payload must contain correct_options';
    end if;
    if exists (
      select 1
      from jsonb_array_elements_text(p_answer_key->'answer_payload'->'correct_options') c(answer_key)
      where not exists (
        select 1 from jsonb_array_elements(v_choices) choice(value)
        where choice.value->>'key' = c.answer_key
      )
    ) then raise exception 'Correct option must match a choice key'; end if;
  end if;
  if v_kind = 'SQ' then
    if jsonb_array_length(v_subparts) = 0 then raise exception 'SQ questions need at least one subpart'; end if;
    if exists (
      select 1 from jsonb_array_elements(v_subparts) part(value)
      where nullif(trim(coalesce(part.value->>'key','')), '') is null
         or jsonb_typeof(part.value->'prompt') <> 'object'
         or nullif(trim(coalesce(part.value->'prompt'->>'en','')), '') is null
         or nullif(trim(coalesce(part.value->'prompt'->>'zh','')), '') is null
         or coalesce((part.value->>'points')::integer, 0) < 1
         or jsonb_typeof(part.value->'unit_required') <> 'boolean'
    ) then raise exception 'Every SQ subpart needs a key, bilingual prompt, positive integer points and unit_required boolean'; end if;
    if jsonb_typeof(p_answer_key->'answer_payload'->'parts') is distinct from 'object' then
      raise exception 'SQ answer payload must contain a parts object';
    end if;
  end if;
  if coalesce(array_length(p_topic_ids, 1), 0) = 0 then raise exception 'Select at least one topic'; end if;

  insert into public.mc_question_bank(question_code, kind, stem, choices, subparts, shared_assets, points, state, submitted_by)
  values (v_code, v_kind, v_stem, v_choices, v_subparts, v_assets, v_points,
          case when v_role='admin'::public.user_role and not exists(select 1 from public.mc_question_bank existing where lower(existing.question_code)=lower(v_code) and existing.state='approved'::public.mc_question_state) then 'approved'::public.mc_question_state else 'pending'::public.mc_question_state end,
          v_uid)
  returning id into v_question_id;

  insert into public.mc_question_answer_keys(question_id, answer_payload, explanation)
  values (v_question_id, coalesce(p_answer_key->'answer_payload','{}'::jsonb),
          coalesce(p_answer_key->'explanation','{}'::jsonb));

  if coalesce(array_length(p_topic_ids, 1), 0) > 0 then
    if exists (select 1 from unnest(p_topic_ids) x where not exists (select 1 from public.review_topics t where t.id=x)) then
      raise exception 'Unknown topic ID';
    end if;
    insert into public.mc_question_topics(question_id, topic_id)
    select v_question_id, x from (select distinct unnest(p_topic_ids) as x) ids;
  end if;
  return v_question_id;
exception
  when unique_violation then
    raise exception 'Question ID already exists';
end;
$;

create or replace function public.mc_moderate_question(
  p_question_id uuid,
  p_decision public.mc_question_state,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  if v_role is distinct from 'admin'::public.user_role then raise exception 'Admin role required' using errcode = '42501'; end if;
  if p_decision not in ('approved'::public.mc_question_state, 'rejected'::public.mc_question_state, 'disabled'::public.mc_question_state) then
    raise exception 'Invalid moderation decision';
  end if;
  update public.mc_question_bank
  set state = p_decision, reviewed_by = v_uid, reviewed_at = now(), review_reason = nullif(trim(p_reason),'')
  where id = p_question_id;
  if not found then raise exception 'Question not found'; end if;
end;
$;

create or replace function public.mc_suggest_question_changes(
  p_question_id uuid,
  p_suggested_changes jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
  v_suggestion_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  if v_role is null or v_role not in ('teacher'::public.user_role, 'admin'::public.user_role) then raise exception 'Teacher or admin role required' using errcode = '42501'; end if;
  if jsonb_typeof(p_suggested_changes) <> 'object' or p_suggested_changes = '{}'::jsonb then
    raise exception 'Suggested changes must be a non-empty JSON object';
  end if;
  if not exists (select 1 from public.mc_question_bank q where q.id=p_question_id and q.state='approved'::public.mc_question_state) then
    raise exception 'Approved question not found';
  end if;
  insert into public.mc_question_suggestions(question_id, teacher_id, suggested_changes)
  values (p_question_id, v_uid, p_suggested_changes)
  returning id into v_suggestion_id;
  return v_suggestion_id;
end;
$;
create or replace function public.mc_validate_question_record()
returns trigger language plpgsql set search_path=''
as $
declare v_count integer; v_sum integer;
begin
 if new.kind='MC'::public.mc_question_kind then
  if jsonb_typeof(new.choices)<>'array' or jsonb_array_length(new.choices)<2 or jsonb_array_length(new.choices)>6 then raise exception 'MC questions need at least two choices'; end if;
  if exists(select 1 from jsonb_array_elements(new.choices) c(value)
    where nullif(trim(coalesce(c.value->>'key','')),'') is null
       or jsonb_typeof(c.value->'text') is distinct from 'object'
       or nullif(trim(coalesce(c.value->'text'->>'en','')),'') is null
       or nullif(trim(coalesce(c.value->'text'->>'zh','')),'') is null) then
   raise exception 'Each MC choice requires a key and bilingual text';
  end if;
  if (select count(*) from jsonb_array_elements(new.choices))<>(select count(distinct c.value->>'key') from jsonb_array_elements(new.choices) c(value)) then raise exception 'MC choice keys must be unique'; end if;
 else
  if jsonb_typeof(new.subparts)<>'array' or jsonb_array_length(new.subparts)=0 then raise exception 'SQ needs at least one subpart'; end if;
  if exists(select 1 from jsonb_array_elements(new.subparts) p(value)
   where nullif(trim(coalesce(p.value->>'key','')),'') is null
    or jsonb_typeof(p.value->'prompt') is distinct from 'object'
    or nullif(trim(coalesce(p.value->'prompt'->>'en','')),'') is null
    or nullif(trim(coalesce(p.value->'prompt'->>'zh','')),'') is null
    or coalesce((p.value->>'points')::integer,0)<1
    or jsonb_typeof(p.value->'unit_required') is distinct from 'boolean') then
   raise exception 'Each SQ subpart requires a key, bilingual prompt, positive integer points and unit_required boolean';
  end if;
  if (select count(*) from jsonb_array_elements(new.subparts))<>(select count(distinct p.value->>'key') from jsonb_array_elements(new.subparts) p(value)) then raise exception 'SQ subpart keys must be unique'; end if;
  select coalesce(sum((p.value->>'points')::integer),0) into v_sum from jsonb_array_elements(new.subparts) p(value);
  if v_sum<>new.points then raise exception 'Question points must equal the sum of SQ subpart points'; end if;
 end if;
 return new;
end;
$;
create or replace function public.mc_validate_question_answer_key()
returns trigger language plpgsql set search_path=''
as $
declare v_q public.mc_question_bank%rowtype; v_correct jsonb; v_key text; v_part jsonb; v_num numeric;
begin
 select * into v_q from public.mc_question_bank where id=new.question_id;
 if not found then raise exception 'Question not found'; end if;
 if jsonb_typeof(new.answer_payload) is distinct from 'object' or new.answer_payload='{}'::jsonb then raise exception 'Answer payload must be a non-empty object'; end if;
 if jsonb_typeof(new.explanation) is distinct from 'object' then raise exception 'Explanation must be a JSON object'; end if;
 if v_q.kind='MC'::public.mc_question_kind then
  v_correct:=new.answer_payload->'correct_options';
  if jsonb_typeof(v_correct) is distinct from 'array' or jsonb_array_length(v_correct)=0 then raise exception 'MC answer must contain correct_options'; end if;
  if exists(select 1 from jsonb_array_elements_text(v_correct) c(value)
   where not exists(select 1 from jsonb_array_elements(v_q.choices) q(value) where q.value->>'key'=c.value)) then raise exception 'Correct option must match a choice key'; end if;
  if (select count(*) from jsonb_array_elements_text(v_correct))<>(select count(distinct c.value) from jsonb_array_elements_text(v_correct) c(value)) then raise exception 'Correct option keys must be unique'; end if;
 else
  if jsonb_typeof(new.answer_payload->'parts') is distinct from 'object' then raise exception 'SQ answer payload must contain parts object'; end if;
  if (select count(*) from jsonb_object_keys(new.answer_payload->'parts'))<>(select count(*) from jsonb_array_elements(v_q.subparts)) then raise exception 'SQ answer keys must match subparts'; end if;
  for v_part in select value from jsonb_array_elements(v_q.subparts) loop
   v_key:=v_part->>'key';
   if not (new.answer_payload->'parts' ? v_key) then raise exception 'Missing answer for SQ subpart %',v_key; end if;
   if jsonb_typeof(new.answer_payload->'parts'->v_key) is distinct from 'object' then raise exception 'SQ subpart answer must be an object'; end if;
   if coalesce(new.answer_payload->'parts'->v_key->>'value','') !~ '^[+-]?[0-9]+([.][0-9]+)?%?$|^[+-]?[0-9]+/[0-9]+ then raise exception 'SQ answer must use a supported exact decimal or fraction'; end if;
   if position('/' in (new.answer_payload->'parts'->v_key->>'value'))>0 and split_part(new.answer_payload->'parts'->v_key->>'value','/',2)::numeric=0 then raise exception 'SQ fraction denominator cannot be zero'; end if;
  end loop;
 end if;
 return new;
end;
$; then raise exception 'SQ answer must use a supported exact decimal or fraction'; end if;
   if position('/' in (new.answer_payload->'parts'->v_key->>'value'))>0 and split_part(new.answer_payload->'parts'->v_key->>'value','/',2)::numeric=0 then raise exception 'SQ fraction denominator cannot be zero'; end if;
  end loop;
 end if;
 return new;
end;
$;
commit;