begin;

-- The central question bank is the canonical source for Review as well as Preview/Online Test.
-- Level 1 = basic practice; Level 2 = public-exam questions.
alter table public.mc_question_bank
  add column if not exists review_level smallint not null default 1
  check (review_level in (1,2));

-- Existing DSE-tagged approved questions are the public-exam set shown in the current bank.
update public.mc_question_bank
set review_level = 2
where question_code ~* '(^|[-_])dse([-_]|$)';

-- Never silently orphan a historic Review attempt when switching its question FK.
do $$
begin
  if exists (
    select 1
    from public.review_attempt_questions aq
    left join public.mc_question_bank b on b.id = aq.question_id
    where b.id is null
  ) then
    raise exception 'Cannot switch Review to the central question bank: historic Review attempts still reference legacy-only question IDs.';
  end if;
end $$;

alter table public.review_attempt_questions
  drop constraint if exists review_attempt_questions_question_id_fkey;
alter table public.review_attempt_questions
  add constraint review_attempt_questions_question_id_fkey
  foreign key (question_id) references public.mc_question_bank(id) on delete restrict;

create or replace function public.mc_set_question_review_level(
  p_question_id uuid,
  p_review_level smallint
) returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
  v_question public.mc_question_bank%rowtype;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  if p_review_level not in (1,2) then raise exception 'Review level must be 1 or 2'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  select * into v_question from public.mc_question_bank q where q.id = p_question_id for update;
  if not found then raise exception 'Question not found'; end if;
  if v_role is distinct from 'admin'::public.user_role
     and (v_question.submitted_by is distinct from v_uid or v_question.state not in ('pending'::public.mc_question_state,'returned'::public.mc_question_state)) then
    raise exception 'Only the owner may set the level of an unapproved question' using errcode = '42501';
  end if;
  if v_role not in ('teacher'::public.user_role,'admin'::public.user_role) then
    raise exception 'Teacher or admin role required' using errcode = '42501';
  end if;
  update public.mc_question_bank set review_level = p_review_level, updated_at = now() where id = p_question_id;
end;
$function$;
revoke all on function public.mc_set_question_review_level(uuid,smallint) from public, anon;
grant execute on function public.mc_set_question_review_level(uuid,smallint) to authenticated;

create or replace function public.review_start_quiz(
  p_topic_names text[],
  p_level smallint,
  p_question_count integer,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_available integer;
  v_attempt_id uuid;
  v_questions jsonb;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_request_id is null then raise exception 'Request ID is required'; end if;
  if p_level not in (1,2) then raise exception 'Invalid level'; end if;
  if p_question_count not in (5,10,15,20,25,30,35,40) then raise exception 'Invalid question count'; end if;
  if coalesce(array_length(p_topic_names,1),0) = 0 then raise exception 'Select at least one subtopic'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_request_id::text, 0));
  select id into v_attempt_id from public.review_attempts
  where user_id = v_user_id and start_request_id = p_request_id;

  if v_attempt_id is not null then
    select jsonb_agg(jsonb_build_object(
      'question_id', aq.question_id,
      'display_order', aq.display_order,
      'question_text', aq.question_text_snapshot,
      'options', aq.options_snapshot
    ) order by aq.display_order) into v_questions
    from public.review_attempt_questions aq where aq.attempt_id = v_attempt_id;
    if coalesce(jsonb_array_length(v_questions),0) = 0 then
      raise exception 'Existing Review request has an incomplete snapshot';
    end if;
    return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,
      'question_count',jsonb_array_length(v_questions),'questions',v_questions,'reused_request',true);
  end if;

  select count(distinct b.id) into v_available
  from public.mc_question_bank b
  join public.mc_question_topics qt on qt.question_id = b.id
  join public.review_topics t on t.id = qt.topic_id and t.parent_id is not null
  join public.mc_question_answer_keys k on k.question_id = b.id
  where b.state = 'approved'::public.mc_question_state
    and b.kind = 'MC'::public.mc_question_kind
    and b.review_level = p_level
    and t.name = any(p_topic_names);

  if v_available < p_question_count then
    return jsonb_build_object('ok',false,'code','insufficient_questions',
      'available_count',v_available,'requested_count',p_question_count);
  end if;

  insert into public.review_attempts(user_id,question_type,selected_topics,level,question_count,start_request_id)
  values(v_user_id,'MC',p_topic_names,p_level,p_question_count,p_request_id)
  returning id into v_attempt_id;

  insert into public.review_attempt_questions(
    attempt_id,question_id,display_order,question_text_snapshot,options_snapshot,
    correct_option_snapshot,explanation_snapshot
  )
  select v_attempt_id, q.id, row_number() over(order by random())::integer,
    jsonb_build_object('en',q.stem->>'en','zh',q.stem->>'zh')::text,
    q.choices,
    public.mc_review_option_set((
      select string_agg(value, ',' order by value)
      from jsonb_array_elements_text(q.answer_payload->'correct_options') correct(value)
    )),
    q.explanation::text
  from (
    select distinct b.id,b.stem,b.choices,k.answer_payload,k.explanation
    from public.mc_question_bank b
    join public.mc_question_topics qt on qt.question_id = b.id
    join public.review_topics t on t.id = qt.topic_id and t.parent_id is not null
    join public.mc_question_answer_keys k on k.question_id = b.id
    where b.state = 'approved'::public.mc_question_state
      and b.kind = 'MC'::public.mc_question_kind
      and b.review_level = p_level
      and t.name = any(p_topic_names)
  ) q
  order by random()
  limit p_question_count;

  if (select count(*) from public.review_attempt_questions where attempt_id = v_attempt_id) <> p_question_count then
    raise exception 'Review snapshot incomplete; attempt rolled back';
  end if;

  select jsonb_agg(jsonb_build_object(
    'question_id', aq.question_id,'display_order',aq.display_order,
    'question_text',aq.question_text_snapshot,'options',aq.options_snapshot
  ) order by aq.display_order) into v_questions
  from public.review_attempt_questions aq where aq.attempt_id = v_attempt_id;

  return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,
    'question_count',p_question_count,'questions',coalesce(v_questions,'[]'::jsonb),'reused_request',false);
end;
$function$;

create or replace function public.mc_review_option_set(p_value text)
returns text
language sql
immutable
set search_path = ''
as $function$
  select case when p_value is null then null else (
    select string_agg(trim(value), ',' order by trim(value))
    from unnest(string_to_array(p_value, ',')) as items(value)
    where trim(value) <> ''
  ) end;
$function$;

create or replace function public.review_save_answer(
  p_attempt_id uuid, p_question_id uuid, p_selected_option text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_attempt public.review_attempts%rowtype;
  v_question public.review_attempt_questions%rowtype;
  v_selected text := public.mc_review_option_set(p_selected_option);
  v_keys text[];
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select * into v_attempt from public.review_attempts
  where id = p_attempt_id and user_id = v_user_id for update;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.submitted_at is not null then raise exception 'Submitted attempt is immutable'; end if;
  select * into v_question from public.review_attempt_questions
  where attempt_id = p_attempt_id and question_id = p_question_id;
  if not found then raise exception 'Question is not part of this attempt'; end if;

  if v_selected is not null then
    v_keys := string_to_array(v_selected, ',');
    if cardinality(v_keys) <> (select count(distinct x) from unnest(v_keys) x) then
      raise exception 'Duplicate option selected';
    end if;
    if exists (
      select 1 from unnest(v_keys) selected(key)
      where not exists (
        select 1 from jsonb_array_elements(v_question.options_snapshot) with ordinality opt(value,ordinality)
        where coalesce(opt.value->>'key',opt.value->>'value',chr(64+opt.ordinality::integer)) = selected.key
      )
    ) then raise exception 'Invalid option selected'; end if;
  end if;

  insert into public.review_attempt_answers(
    attempt_id,question_id,selected_option,is_correct,correct_option,explanation_snapshot
  ) values (
    p_attempt_id,p_question_id,v_selected,
    coalesce(v_selected = v_question.correct_option_snapshot,false),
    v_question.correct_option_snapshot,v_question.explanation_snapshot
  )
  on conflict (attempt_id,question_id) do update
  set selected_option=excluded.selected_option,is_correct=excluded.is_correct,
      correct_option=excluded.correct_option,explanation_snapshot=excluded.explanation_snapshot,
      answered_at=now();

  return jsonb_build_object('ok',true,'attempt_id',p_attempt_id,'question_id',p_question_id);
end;
$function$;

create or replace function public.review_submit_quiz(p_attempt_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_attempt public.review_attempts%rowtype;
  v_correct integer;
  v_details jsonb;
  v_answer_count integer;
  v_distinct_count integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(coalesce(p_answers,'[]'::jsonb)) <> 'array' then raise exception 'Answers must be an array'; end if;
  select * into v_attempt from public.review_attempts
  where id = p_attempt_id and user_id = v_user_id for update;
  if not found then raise exception 'Attempt not found'; end if;

  if v_attempt.submitted_at is not null then
    select jsonb_build_object('attempt_id',a.id,'correct_count',a.correct_count,
      'question_count',a.question_count,'submitted_at',a.submitted_at,
      'answers',coalesce(jsonb_agg(jsonb_build_object(
        'question_id',aq.question_id,'display_order',aq.display_order,
        'question_text',aq.question_text_snapshot,'options',aq.options_snapshot,
        'selected_option',aa.selected_option,'is_correct',aa.is_correct,
        'correct_option',aa.correct_option,'explanation',aa.explanation_snapshot
      ) order by aq.display_order),'[]'::jsonb))
    into v_details
    from public.review_attempts a
    join public.review_attempt_questions aq on aq.attempt_id = a.id
    join public.review_attempt_answers aa on aa.attempt_id = aq.attempt_id and aa.question_id = aq.question_id
    where a.id = p_attempt_id and a.user_id = v_user_id group by a.id;
    if v_details is null then raise exception 'Submitted attempt result unavailable'; end if;
    return v_details;
  end if;

  select count(*),count(distinct x.question_id) into v_answer_count,v_distinct_count
  from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid,selected_option text);
  if v_answer_count <> v_distinct_count or v_answer_count <> v_attempt.question_count then
    raise exception 'One unique answer entry is required for each question';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid,selected_option text)
    where x.question_id is null or not exists (
      select 1 from public.review_attempt_questions aq
      where aq.attempt_id = p_attempt_id and aq.question_id = x.question_id
    )
  ) then raise exception 'Answer contains a question outside this attempt'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid,selected_option text)
    cross join lateral unnest(string_to_array(coalesce(x.selected_option,''),',')) selected(key)
    where trim(selected.key) <> ''
      and not exists (
        select 1 from public.review_attempt_questions aq
        cross join lateral jsonb_array_elements(aq.options_snapshot) with ordinality opt(value,ordinality)
        where aq.attempt_id = p_attempt_id and aq.question_id = x.question_id
          and coalesce(opt.value->>'key',opt.value->>'value',chr(64+opt.ordinality::integer)) = trim(selected.key)
      )
  ) then raise exception 'Invalid option selected'; end if;
  if exists (
    select 1 from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid,selected_option text)
    where x.selected_option is not null and cardinality(string_to_array(public.mc_review_option_set(x.selected_option),',')) <>
      (select count(distinct trim(k)) from unnest(string_to_array(x.selected_option,',')) k)
  ) then raise exception 'Duplicate option selected'; end if;

  insert into public.review_attempt_answers(
    attempt_id,question_id,selected_option,is_correct,correct_option,explanation_snapshot
  )
  select p_attempt_id,aq.question_id,public.mc_review_option_set(x.selected_option),
    coalesce(public.mc_review_option_set(x.selected_option)=aq.correct_option_snapshot,false),
    aq.correct_option_snapshot,aq.explanation_snapshot
  from public.review_attempt_questions aq
  join jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid,selected_option text)
    on x.question_id=aq.question_id
  where aq.attempt_id=p_attempt_id
  on conflict (attempt_id,question_id) do update
  set selected_option=excluded.selected_option,is_correct=excluded.is_correct,
      correct_option=excluded.correct_option,explanation_snapshot=excluded.explanation_snapshot,
      answered_at=now();

  select count(*) filter(where is_correct) into v_correct
  from public.review_attempt_answers where attempt_id=p_attempt_id;
  update public.review_attempts set correct_count=coalesce(v_correct,0),submitted_at=now() where id=p_attempt_id;

  select jsonb_build_object('attempt_id',a.id,'correct_count',a.correct_count,
    'question_count',a.question_count,'submitted_at',a.submitted_at,
    'answers',coalesce(jsonb_agg(jsonb_build_object(
      'question_id',aq.question_id,'display_order',aq.display_order,
      'question_text',aq.question_text_snapshot,'options',aq.options_snapshot,
      'selected_option',aa.selected_option,'is_correct',aa.is_correct,
      'correct_option',aa.correct_option,'explanation',aa.explanation_snapshot
    ) order by aq.display_order),'[]'::jsonb))
  into v_details
  from public.review_attempts a
  join public.review_attempt_questions aq on aq.attempt_id=a.id
  join public.review_attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
  where a.id=p_attempt_id and a.user_id=v_user_id group by a.id;
  return v_details;
end;
$function$;

revoke all on function public.mc_review_option_set(text) from public, anon;
revoke all on function public.review_start_quiz(text[],smallint,integer,uuid) from public, anon;
revoke all on function public.review_save_answer(uuid,uuid,text) from public, anon;
revoke all on function public.review_submit_quiz(uuid,jsonb) from public, anon;
grant execute on function public.review_start_quiz(text[],smallint,integer,uuid) to authenticated;
grant execute on function public.review_save_answer(uuid,uuid,text) to authenticated;
grant execute on function public.review_submit_quiz(uuid,jsonb) to authenticated;

commit;
