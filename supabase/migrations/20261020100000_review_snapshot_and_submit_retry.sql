-- Review answer/explanation snapshots and idempotent duplicate submit response.
-- Existing attempts are backfilled from the current answer bank before functions switch to snapshots.
begin;

alter table public.review_attempt_questions
  add column if not exists correct_option_snapshot text,
  add column if not exists explanation_snapshot text;

update public.review_attempt_questions aq
set correct_option_snapshot = k.correct_option,
    explanation_snapshot = k.explanation
from public.review_answer_keys k
where k.question_id = aq.question_id
  and (aq.correct_option_snapshot is null or aq.explanation_snapshot is null);

-- Do not silently permit incomplete legacy snapshots.
do $$
begin
  if exists (
    select 1 from public.review_attempt_questions
    where correct_option_snapshot is null or explanation_snapshot is null
  ) then
    raise exception 'Cannot complete Review snapshots: one or more existing attempts have no matching answer key';
  end if;
end $$;

alter table public.review_attempt_questions
  alter column correct_option_snapshot set not null,
  alter column explanation_snapshot set not null;

create or replace function public.review_start_quiz(
  p_topic_names text[],
  p_level smallint,
  p_question_count integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_available integer;
  v_attempt_id uuid;
  v_questions jsonb;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_level not in (1,2) then raise exception 'Invalid level'; end if;
  if p_question_count not in (5,10,15,20,25,30,35,40) then raise exception 'Invalid question count'; end if;
  if coalesce(array_length(p_topic_names,1),0) = 0 then raise exception 'Select at least one subtopic'; end if;

  select count(distinct q.id) into v_available
  from public.review_questions q
  join public.review_question_topics qt on qt.question_id = q.id
  join public.review_topics t on t.id = qt.topic_id and t.parent_id is not null
  join public.review_answer_keys k on k.question_id = q.id
  where q.is_active and q.level = p_level and t.name = any(p_topic_names);

  if v_available < p_question_count then
    return jsonb_build_object('ok',false,'code','insufficient_questions','available_count',v_available,'requested_count',p_question_count);
  end if;

  insert into public.review_attempts(user_id,question_type,selected_topics,level,question_count)
  values(v_user_id,'MC',p_topic_names,p_level,p_question_count) returning id into v_attempt_id;

  insert into public.review_attempt_questions(
    attempt_id, question_id, display_order, question_text_snapshot, options_snapshot,
    correct_option_snapshot, explanation_snapshot
  )
  select v_attempt_id, q.id, row_number() over(order by random())::integer, q.question_text, q.options,
         k.correct_option, k.explanation
  from (
    select distinct q0.id, q0.question_text, q0.options
    from public.review_questions q0
    join public.review_question_topics qt on qt.question_id = q0.id
    join public.review_topics t on t.id = qt.topic_id and t.parent_id is not null
    join public.review_answer_keys k on k.question_id = q0.id
    where q0.is_active and q0.level = p_level and t.name = any(p_topic_names)
  ) q
  join public.review_answer_keys k on k.question_id=q.id
  order by random()
  limit p_question_count;

  if (select count(*) from public.review_attempt_questions where attempt_id=v_attempt_id) <> p_question_count then
    raise exception 'Review snapshot incomplete; attempt rolled back';
  end if;

  select jsonb_agg(jsonb_build_object(
    'question_id', aq.question_id,
    'display_order', aq.display_order,
    'question_text', aq.question_text_snapshot,
    'options', aq.options_snapshot
  ) order by aq.display_order) into v_questions
  from public.review_attempt_questions aq where aq.attempt_id = v_attempt_id;

  return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,'question_count',p_question_count,'questions',coalesce(v_questions,'[]'::jsonb));
end;
$function$;

create or replace function public.review_submit_quiz(p_attempt_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.review_attempts%rowtype;
  v_correct integer;
  v_details jsonb;
  v_answer_count integer;
  v_distinct_count integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(coalesce(p_answers,'[]'::jsonb)) <> 'array' then raise exception 'Answers must be an array'; end if;

  select * into v_attempt from public.review_attempts where id = p_attempt_id and user_id = v_user_id for update;
  if not found then raise exception 'Attempt not found'; end if;

  -- A retry after a successful but network-ambiguous submission returns the same result.
  if v_attempt.submitted_at is not null then
    select jsonb_build_object(
      'attempt_id', a.id, 'correct_count', a.correct_count, 'question_count', a.question_count,
      'submitted_at', a.submitted_at,
      'answers', coalesce(jsonb_agg(jsonb_build_object(
        'question_id', aq.question_id,
        'display_order', aq.display_order,
        'question_text', aq.question_text_snapshot,
        'options', aq.options_snapshot,
        'selected_option', aa.selected_option,
        'is_correct', aa.is_correct,
        'correct_option', aa.correct_option,
        'explanation', aa.explanation_snapshot
      ) order by aq.display_order),'[]'::jsonb)
    ) into v_details
    from public.review_attempts a
    join public.review_attempt_questions aq on aq.attempt_id=a.id
    join public.review_attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
    where a.id=p_attempt_id and a.user_id=v_user_id
    group by a.id;
    if v_details is null then raise exception 'Submitted attempt result unavailable'; end if;
    return v_details;
  end if;

  select count(*), count(distinct x.question_id) into v_answer_count, v_distinct_count
  from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid, selected_option text);
  if v_answer_count <> v_distinct_count then raise exception 'Duplicate answer entries'; end if;
  if exists (
    select 1 from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid, selected_option text)
    where not exists (select 1 from public.review_attempt_questions aq where aq.attempt_id=p_attempt_id and aq.question_id=x.question_id)
  ) then raise exception 'Answer contains a question outside this attempt'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid, selected_option text)
    join public.review_attempt_questions aq on aq.attempt_id=p_attempt_id and aq.question_id=x.question_id
    where x.selected_option is not null
      and not exists (
        select 1 from jsonb_array_elements(aq.options_snapshot) with ordinality as opt(value, ordinality)
        where coalesce(opt.value->>'key', opt.value->>'value', chr(64 + opt.ordinality::integer)) = x.selected_option
      )
  ) then raise exception 'Invalid option selected'; end if;

  insert into public.review_attempt_answers(attempt_id,question_id,selected_option,is_correct,correct_option,explanation_snapshot)
  select p_attempt_id, aq.question_id, x.selected_option,
         coalesce(x.selected_option = aq.correct_option_snapshot,false),
         aq.correct_option_snapshot, aq.explanation_snapshot
  from public.review_attempt_questions aq
  left join jsonb_to_recordset(coalesce(p_answers,'[]'::jsonb)) as x(question_id uuid, selected_option text) on x.question_id=aq.question_id
  where aq.attempt_id=p_attempt_id;

  select count(*) filter (where is_correct) into v_correct
  from public.review_attempt_answers where attempt_id=p_attempt_id;

  update public.review_attempts set correct_count=coalesce(v_correct,0), submitted_at=now() where id=p_attempt_id;

  select jsonb_build_object(
    'attempt_id', a.id, 'correct_count', a.correct_count, 'question_count', a.question_count,
    'submitted_at', a.submitted_at,
    'answers', coalesce(jsonb_agg(jsonb_build_object(
      'question_id', aq.question_id,
      'display_order', aq.display_order,
      'question_text', aq.question_text_snapshot,
      'options', aq.options_snapshot,
      'selected_option', aa.selected_option,
      'is_correct', aa.is_correct,
      'correct_option', aa.correct_option,
      'explanation', aa.explanation_snapshot
    ) order by aq.display_order),'[]'::jsonb)
  ) into v_details
  from public.review_attempts a
  join public.review_attempt_questions aq on aq.attempt_id=a.id
  join public.review_attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
  where a.id=p_attempt_id and a.user_id=v_user_id
  group by a.id;
  return v_details;
end;
$function$;

commit;
