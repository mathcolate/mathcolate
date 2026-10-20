begin;
alter table public.review_attempts
  add column if not exists start_request_id uuid;
create unique index if not exists review_attempts_user_start_request_uidx
  on public.review_attempts(user_id, start_request_id)
  where start_request_id is not null;
create or replace function public.review_start_quiz(
  p_topic_names text[], p_level smallint, p_question_count integer, p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
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
  where user_id=v_user_id and start_request_id=p_request_id;

  if v_attempt_id is not null then
    select jsonb_agg(jsonb_build_object(
      'question_id',aq.question_id,'display_order',aq.display_order,
      'question_text',aq.question_text_snapshot,'options',aq.options_snapshot
    ) order by aq.display_order) into v_questions
    from public.review_attempt_questions aq where aq.attempt_id=v_attempt_id;
    if coalesce(jsonb_array_length(v_questions),0)=0 then
      raise exception 'Existing Review request has an incomplete snapshot';
    end if;
    return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,
      'question_count',jsonb_array_length(v_questions),'questions',v_questions,'reused_request',true);
  end if;

  select count(distinct q.id) into v_available
  from public.review_questions q
  join public.review_question_topics qt on qt.question_id=q.id
  join public.review_topics t on t.id=qt.topic_id and t.parent_id is not null
  join public.review_answer_keys k on k.question_id=q.id
  where q.is_active and q.level=p_level and t.name=any(p_topic_names);

  if v_available<p_question_count then
    return jsonb_build_object('ok',false,'code','insufficient_questions',
      'available_count',v_available,'requested_count',p_question_count);
  end if;

  insert into public.review_attempts(user_id,question_type,selected_topics,level,question_count,start_request_id)
  values(v_user_id,'MC',p_topic_names,p_level,p_question_count,p_request_id) returning id into v_attempt_id;

  insert into public.review_attempt_questions(
    attempt_id,question_id,display_order,question_text_snapshot,options_snapshot,
    correct_option_snapshot,explanation_snapshot
  )
  select v_attempt_id,q.id,row_number() over(order by random())::integer,q.question_text,q.options,
    k.correct_option,k.explanation
  from (
    select distinct q0.id,q0.question_text,q0.options
    from public.review_questions q0
    join public.review_question_topics qt on qt.question_id=q0.id
    join public.review_topics t on t.id=qt.topic_id and t.parent_id is not null
    join public.review_answer_keys k on k.question_id=q0.id
    where q0.is_active and q0.level=p_level and t.name=any(p_topic_names)
  ) q
  join public.review_answer_keys k on k.question_id=q.id
  order by random() limit p_question_count;

  if (select count(*) from public.review_attempt_questions where attempt_id=v_attempt_id)<>p_question_count then
    raise exception 'Review snapshot incomplete; attempt rolled back';
  end if;

  select jsonb_agg(jsonb_build_object('question_id',aq.question_id,'display_order',aq.display_order,
    'question_text',aq.question_text_snapshot,'options',aq.options_snapshot) order by aq.display_order)
  into v_questions from public.review_attempt_questions aq where aq.attempt_id=v_attempt_id;

  return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,'question_count',p_question_count,
    'questions',coalesce(v_questions,'[]'::jsonb),'reused_request',false);
end;
$function$;
revoke all on function public.review_start_quiz(text[],smallint,integer) from public;
revoke all on function public.review_start_quiz(text[],smallint,integer,uuid) from public;
grant execute on function public.review_start_quiz(text[],smallint,integer,uuid) to authenticated;
commit;