begin;
create or replace function public.mc_update_pending_question(p_question_id uuid,p_question jsonb,p_answer_key jsonb,p_topic_ids uuid[])
returns void language plpgsql security definer set search_path=''
as $$
declare
 v_uid uuid:=(select auth.uid()); v_role public.user_role; v_existing public.mc_question_bank%rowtype;
 v_code text; v_kind public.mc_question_kind; v_stem jsonb; v_choices jsonb; v_subparts jsonb; v_assets jsonb; v_points integer;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select u.role into v_role from public.users_acc_info u where u.id=v_uid;
 if v_role is null or v_role not in ('teacher'::public.user_role,'admin'::public.user_role) then raise exception 'Teacher or admin role required' using errcode='42501'; end if;
 if jsonb_typeof(p_question) is distinct from 'object' or jsonb_typeof(p_answer_key) is distinct from 'object' then raise exception 'Question and answer key must be JSON objects'; end if;
 select * into v_existing from public.mc_question_bank where id=p_question_id for update;
 if not found then raise exception 'Question not found'; end if;
 if v_role='teacher'::public.user_role and (v_existing.submitted_by is distinct from v_uid or v_existing.state not in ('pending'::public.mc_question_state,'returned'::public.mc_question_state)) then
  raise exception 'Teachers may only edit their own pending or returned submissions' using errcode='42501';
 end if;
 v_code:=nullif(trim(p_question->>'question_code'),'');
 if v_code is null then raise exception 'Question ID is required'; end if;
 v_kind:=(p_question->>'kind')::public.mc_question_kind; v_stem:=p_question->'stem';
 v_choices:=coalesce(p_question->'choices','[]'::jsonb); v_subparts:=coalesce(p_question->'subparts','[]'::jsonb);
 v_assets:=coalesce(p_question->'shared_assets','[]'::jsonb); v_points:=coalesce((p_question->>'points')::integer,1);
 if jsonb_typeof(v_stem) is distinct from 'object' or nullif(trim(coalesce(v_stem->>'en','')),'') is null or nullif(trim(coalesce(v_stem->>'zh','')),'') is null then raise exception 'Question stem is required in English and Chinese'; end if;
 if jsonb_typeof(v_choices) is distinct from 'array' or jsonb_typeof(v_subparts) is distinct from 'array' or jsonb_typeof(v_assets) is distinct from 'array' then raise exception 'Choices, subparts and shared assets must be arrays'; end if;
 if v_points<1 then raise exception 'Points must be a positive integer'; end if;
 if p_answer_key->'answer_payload' is null or jsonb_typeof(p_answer_key->'answer_payload') is distinct from 'object' or p_answer_key->'answer_payload'='{}'::jsonb then raise exception 'A non-empty answer payload is required'; end if;
 if jsonb_typeof(coalesce(p_answer_key->'explanation','{}'::jsonb)) is distinct from 'object' then raise exception 'Explanation must be a JSON object'; end if;
 if coalesce(array_length(p_topic_ids,1),0)=0 then raise exception 'Select at least one topic'; end if;
 if exists(select 1 from unnest(p_topic_ids) x where not exists(select 1 from public.review_topics t where t.id=x)) then raise exception 'Unknown topic ID'; end if;
 update public.mc_question_bank set question_code=v_code,kind=v_kind,stem=v_stem,choices=v_choices,subparts=v_subparts,shared_assets=v_assets,points=v_points,
  state=case when state='returned'::public.mc_question_state then 'pending'::public.mc_question_state else state end,
  reviewed_by=case when state='returned'::public.mc_question_state then null else reviewed_by end,
  reviewed_at=case when state='returned'::public.mc_question_state then null else reviewed_at end,
  review_reason=case when state='returned'::public.mc_question_state then null else review_reason end
 where id=p_question_id;
 insert into public.mc_question_answer_keys(question_id,answer_payload,explanation)
 values(p_question_id,p_answer_key->'answer_payload',coalesce(p_answer_key->'explanation','{}'::jsonb))
 on conflict(question_id) do update set answer_payload=excluded.answer_payload,explanation=excluded.explanation,updated_at=now();
 delete from public.mc_question_topics where question_id=p_question_id;
 insert into public.mc_question_topics(question_id,topic_id) select p_question_id,x from (select distinct unnest(p_topic_ids) x) ids;
exception when unique_violation then raise exception 'Question ID already exists';
end;
$$;
create or replace function public.mc_delete_pending_question(p_question_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_role public.user_role; v_question public.mc_question_bank%rowtype;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select u.role into v_role from public.users_acc_info u where u.id=v_uid;
 if v_role is null or v_role not in ('teacher'::public.user_role,'admin'::public.user_role) then raise exception 'Teacher or admin role required' using errcode='42501'; end if;
 select * into v_question from public.mc_question_bank where id=p_question_id for update;
 if not found then raise exception 'Question not found'; end if;
 if v_role='teacher'::public.user_role and (v_question.submitted_by is distinct from v_uid or v_question.state not in ('pending'::public.mc_question_state,'returned'::public.mc_question_state)) then
  raise exception 'Teachers may only discard their own pending or returned submissions' using errcode='42501';
 end if;
 delete from public.mc_question_bank where id=p_question_id;
end;
$$;
revoke all on function public.mc_update_pending_question(uuid,jsonb,jsonb,uuid[]) from public,anon;
revoke all on function public.mc_delete_pending_question(uuid) from public,anon;
grant execute on function public.mc_update_pending_question(uuid,jsonb,jsonb,uuid[]) to authenticated;
grant execute on function public.mc_delete_pending_question(uuid) to authenticated;
commit;
