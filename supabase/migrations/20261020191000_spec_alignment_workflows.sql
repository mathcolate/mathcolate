begin;

drop index if exists public.mc_question_bank_code_ci_uidx;

create unique index mc_question_bank_code_ci_uidx on public.mc_question_bank(lower(question_code)) where state='approved'::public.mc_question_state;

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

commit;