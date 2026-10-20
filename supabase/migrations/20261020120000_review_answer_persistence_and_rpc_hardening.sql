-- Review answer persistence and RPC hardening.
-- Existing review tables are retained; this migration adds one narrowly scoped RPC
-- and makes submission compatible with answers saved before final submission.

create or replace function public.review_save_answer(
  p_attempt_id uuid,
  p_question_id uuid,
  p_selected_option text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.review_attempts%rowtype;
  v_question public.review_attempt_questions%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_attempt
  from public.review_attempts
  where id = p_attempt_id and user_id = v_user_id
  for update;

  if not found then
    raise exception 'Attempt not found';
  end if;
  if v_attempt.submitted_at is not null then
    raise exception 'Submitted attempt is immutable';
  end if;

  select * into v_question
  from public.review_attempt_questions
  where attempt_id = p_attempt_id and question_id = p_question_id;

  if not found then
    raise exception 'Question is not part of this attempt';
  end if;

  if p_selected_option is not null and not exists (
    select 1
    from jsonb_array_elements(v_question.options_snapshot) with ordinality as opt(value, ordinality)
    where coalesce(
      opt.value->>'key',
      opt.value->>'value',
      chr(64 + opt.ordinality::integer)
    ) = p_selected_option
  ) then
    raise exception 'Invalid option selected';
  end if;

  insert into public.review_attempt_answers(
    attempt_id, question_id, selected_option, is_correct, correct_option, explanation_snapshot
  )
  values (
    p_attempt_id,
    p_question_id,
    p_selected_option,
    coalesce(p_selected_option = v_question.correct_option_snapshot, false),
    v_question.correct_option_snapshot,
    v_question.explanation_snapshot
  )
  on conflict (attempt_id, question_id) do update
  set selected_option = excluded.selected_option,
      is_correct = excluded.is_correct,
      correct_option = excluded.correct_option,
      explanation_snapshot = excluded.explanation_snapshot,
      answered_at = pg_catalog.now();

  return jsonb_build_object('ok', true, 'attempt_id', p_attempt_id, 'question_id', p_question_id);
end;
$function$;

create or replace function public.review_submit_quiz(p_attempt_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.review_attempts%rowtype;
  v_correct integer;
  v_details jsonb;
  v_answer_count integer;
  v_distinct_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(coalesce(p_answers, '[]'::jsonb)) <> 'array' then
    raise exception 'Answers must be an array';
  end if;

  select * into v_attempt
  from public.review_attempts
  where id = p_attempt_id and user_id = v_user_id
  for update;

  if not found then
    raise exception 'Attempt not found';
  end if;

  -- A retry after a successful but network-ambiguous submission returns the original result.
  if v_attempt.submitted_at is not null then
    select jsonb_build_object(
      'attempt_id', a.id,
      'correct_count', a.correct_count,
      'question_count', a.question_count,
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
      ) order by aq.display_order), '[]'::jsonb)
    ) into v_details
    from public.review_attempts a
    join public.review_attempt_questions aq on aq.attempt_id = a.id
    join public.review_attempt_answers aa on aa.attempt_id = aq.attempt_id and aa.question_id = aq.question_id
    where a.id = p_attempt_id and a.user_id = v_user_id
    group by a.id;
    if v_details is null then
      raise exception 'Submitted attempt result unavailable';
    end if;
    return v_details;
  end if;

  select count(*), count(distinct x.question_id)
  into v_answer_count, v_distinct_count
  from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(question_id uuid, selected_option text);

  if v_answer_count <> v_distinct_count then
    raise exception 'Duplicate answer entries';
  end if;
  if v_answer_count <> v_attempt.question_count then
    raise exception 'One answer entry is required for each question';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(question_id uuid, selected_option text)
    where x.question_id is null
       or not exists (
         select 1 from public.review_attempt_questions aq
         where aq.attempt_id = p_attempt_id and aq.question_id = x.question_id
       )
  ) then
    raise exception 'Answer contains a question outside this attempt';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(question_id uuid, selected_option text)
    join public.review_attempt_questions aq
      on aq.attempt_id = p_attempt_id and aq.question_id = x.question_id
    where x.selected_option is not null
      and not exists (
        select 1
        from jsonb_array_elements(aq.options_snapshot) with ordinality as opt(value, ordinality)
        where coalesce(
          opt.value->>'key',
          opt.value->>'value',
          chr(64 + opt.ordinality::integer)
        ) = x.selected_option
      )
  ) then
    raise exception 'Invalid option selected';
  end if;

  -- Upsert allows the same rows written by review_save_answer to be finalized safely.
  insert into public.review_attempt_answers(
    attempt_id, question_id, selected_option, is_correct, correct_option, explanation_snapshot
  )
  select
    p_attempt_id,
    aq.question_id,
    x.selected_option,
    coalesce(x.selected_option = aq.correct_option_snapshot, false),
    aq.correct_option_snapshot,
    aq.explanation_snapshot
  from public.review_attempt_questions aq
  join jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(question_id uuid, selected_option text)
    on x.question_id = aq.question_id
  where aq.attempt_id = p_attempt_id
  on conflict (attempt_id, question_id) do update
  set selected_option = excluded.selected_option,
      is_correct = excluded.is_correct,
      correct_option = excluded.correct_option,
      explanation_snapshot = excluded.explanation_snapshot,
      answered_at = pg_catalog.now();

  select count(*) filter (where is_correct)
  into v_correct
  from public.review_attempt_answers
  where attempt_id = p_attempt_id;

  update public.review_attempts
  set correct_count = coalesce(v_correct, 0), submitted_at = pg_catalog.now()
  where id = p_attempt_id and user_id = v_user_id and submitted_at is null;

  select jsonb_build_object(
    'attempt_id', a.id,
    'correct_count', a.correct_count,
    'question_count', a.question_count,
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
    ) order by aq.display_order), '[]'::jsonb)
  ) into v_details
  from public.review_attempts a
  join public.review_attempt_questions aq on aq.attempt_id = a.id
  join public.review_attempt_answers aa on aa.attempt_id = aq.attempt_id and aa.question_id = aq.question_id
  where a.id = p_attempt_id and a.user_id = v_user_id
  group by a.id;

  if v_details is null then
    raise exception 'Submitted attempt result unavailable';
  end if;
  return v_details;
end;
$function$;

-- Keep the older non-idempotent entry point unavailable to client roles.
revoke all on function public.review_start_quiz(text[], smallint, integer) from public, anon, authenticated;
grant execute on function public.review_start_quiz(text[], smallint, integer) to service_role;

-- RPCs are authenticated APIs; do not inherit the default PUBLIC execute grant.
revoke all on function public.review_start_quiz(text[], smallint, integer, uuid) from public, anon;
revoke all on function public.review_save_answer(uuid, uuid, text) from public, anon;
revoke all on function public.review_submit_quiz(uuid, jsonb) from public, anon;
revoke all on function public.review_get_attempt_details(uuid) from public, anon;

grant execute on function public.review_start_quiz(text[], smallint, integer, uuid) to authenticated, service_role;
grant execute on function public.review_save_answer(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.review_submit_quiz(uuid, jsonb) to authenticated, service_role;
grant execute on function public.review_get_attempt_details(uuid) to authenticated, service_role;

-- Empty search_path plus fully-qualified object names avoids search_path shadowing.
alter function public.review_start_quiz(text[], smallint, integer) set search_path = '';
alter function public.review_start_quiz(text[], smallint, integer, uuid) set search_path = '';
alter function public.review_get_attempt_details(uuid) set search_path = '';
