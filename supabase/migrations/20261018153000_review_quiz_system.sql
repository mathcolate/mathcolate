-- Mathcolate Review quiz foundation.
-- Answers are stored separately from the question prompt so students cannot read answer keys before submission.

create table if not exists public.review_topics (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  parent_id uuid references public.review_topics(id) on delete cascade,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists review_topics_parent_sort_idx on public.review_topics(parent_id, sort_order);

create table if not exists public.review_questions (
  id uuid primary key default gen_random_uuid(),
  question_text text not null,
  options jsonb not null,
  level smallint not null check (level in (1, 2)),
  is_active boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint review_questions_options_array check (jsonb_typeof(options) = 'array')
);
create index if not exists review_questions_active_level_idx on public.review_questions(level) where is_active;

create table if not exists public.review_answer_keys (
  question_id uuid primary key references public.review_questions(id) on delete cascade,
  correct_option text not null,
  explanation text not null default '',
  explanation_source text not null default 'teacher',
  updated_at timestamptz not null default now()
);

create table if not exists public.review_question_topics (
  question_id uuid not null references public.review_questions(id) on delete cascade,
  topic_id uuid not null references public.review_topics(id) on delete cascade,
  primary key (question_id, topic_id)
);
create index if not exists review_question_topics_topic_idx on public.review_question_topics(topic_id, question_id);

create table if not exists public.review_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  question_type text not null default 'MC' check (question_type in ('MC', 'SQ')),
  selected_topics text[] not null,
  level smallint not null check (level in (1, 2)),
  question_count integer not null check (question_count in (5,10,15,20,25,30,35,40)),
  correct_count integer,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint review_attempt_score_valid check (correct_count is null or (correct_count >= 0 and correct_count <= question_count))
);
create index if not exists review_attempts_user_recent_idx on public.review_attempts(user_id, created_at desc);

create table if not exists public.review_attempt_questions (
  attempt_id uuid not null references public.review_attempts(id) on delete cascade,
  question_id uuid not null references public.review_questions(id) on delete restrict,
  display_order integer not null,
  question_text_snapshot text not null,
  options_snapshot jsonb not null,
  primary key (attempt_id, question_id),
  unique (attempt_id, display_order)
);

create table if not exists public.review_attempt_answers (
  attempt_id uuid not null,
  question_id uuid not null,
  selected_option text,
  is_correct boolean not null,
  correct_option text not null,
  explanation_snapshot text not null default '',
  answered_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  foreign key (attempt_id, question_id) references public.review_attempt_questions(attempt_id, question_id) on delete cascade
);

alter table public.review_topics enable row level security;
alter table public.review_questions enable row level security;
alter table public.review_answer_keys enable row level security;
alter table public.review_question_topics enable row level security;
alter table public.review_attempts enable row level security;
alter table public.review_attempt_questions enable row level security;
alter table public.review_attempt_answers enable row level security;

grant select, insert, update, delete on public.review_topics to authenticated;
grant select, insert, update, delete on public.review_questions to authenticated;
grant select, insert, update, delete on public.review_question_topics to authenticated;
grant select on public.review_attempts to authenticated;
grant select on public.review_attempt_answers to authenticated;
grant select on public.review_attempt_questions to authenticated;
grant select, insert, update, delete on public.review_answer_keys to authenticated;

drop policy if exists "review topics read authenticated" on public.review_topics;
create policy "review topics read authenticated" on public.review_topics for select to authenticated using (true);
drop policy if exists "review topics admin manage" on public.review_topics;
create policy "review topics admin manage" on public.review_topics for all to authenticated
using (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'))
with check (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'));

drop policy if exists "review answer keys admin manage" on public.review_answer_keys;
create policy "review answer keys admin manage" on public.review_answer_keys for all to authenticated
using (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'))
with check (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'));

drop policy if exists "review active question prompt read" on public.review_questions;
create policy "review active question prompt read" on public.review_questions for select to authenticated using (is_active = true);
drop policy if exists "review questions admin manage" on public.review_questions;
create policy "review questions admin manage" on public.review_questions for all to authenticated
using (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'))
with check (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'));

drop policy if exists "review topic mappings read authenticated" on public.review_question_topics;
create policy "review topic mappings read authenticated" on public.review_question_topics for select to authenticated using (true);
drop policy if exists "review topic mappings admin manage" on public.review_question_topics;
create policy "review topic mappings admin manage" on public.review_question_topics for all to authenticated
using (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'))
with check (exists (select 1 from public.users_acc_info u where u.id = (select auth.uid()) and u.role = 'admin'));

drop policy if exists "review attempts owner read" on public.review_attempts;
create policy "review attempts owner read" on public.review_attempts for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "review attempt answers owner after submit" on public.review_attempt_answers;
create policy "review attempt answers owner after submit" on public.review_attempt_answers for select to authenticated
using (exists (select 1 from public.review_attempts a where a.id = attempt_id and a.user_id = (select auth.uid()) and a.submitted_at is not null));
drop policy if exists "review attempt questions owner after submit" on public.review_attempt_questions;
create policy "review attempt questions owner after submit" on public.review_attempt_questions for select to authenticated
using (exists (select 1 from public.review_attempts a where a.id = attempt_id and a.user_id = (select auth.uid()) and a.submitted_at is not null));

-- No client role can read answer keys, even for active questions.
revoke all on public.review_answer_keys from anon, authenticated;
revoke insert, update, delete on public.review_attempts from anon, authenticated;
revoke insert, update, delete on public.review_attempt_questions from anon, authenticated;
revoke insert, update, delete on public.review_attempt_answers from anon, authenticated;

with topic_seed(main_slug, main_name, subtopics) as (
  values
  ('numbers-and-estimation','Numbers and Estimation',array['Directed numbers','Surds','Number bases','Scientific notations','Estimation strategies','Estimation in measurements','Errors','Complex numbers']::text[]),
  ('polynomials','Polynomials',array['Fundamental operations of polynomials','Factorization','Remainder and factor theorem','HCF and LCM','Rational functions']::text[]),
  ('exponentials-and-logarithms','Exponentials and Logarithms',array['Indices and radicals','Logarithms','Exponential and logarithmic equations','Graphs of exponential and logarithmic functions','Applications of logarithms']::text[]),
  ('functions-and-graphs','Functions and graphs',array['Notation of functions','Graphs of linear functions','Graphs of quadratic functions','Optima of functions','Transformation of graphs']::text[]),
  ('transformation-and-symmetry','Transformation and Symmetry',array['Transformation of points','Transformation of plane figures','Symmetry of plane figures','3-D figures']::text[]),
  ('coordinate-geometry','Coordinate geometry',array['Polar coordinates','Distance formula','Slope and inclination','Mid-point and section formula','Equations of straight lines','Equations of circles','Intersections between straight lines and circles','Locus']::text[]),
  ('formulae-and-identities','Formulae and Identities',array['Change of subjects','Substitution','Algebraic fractions','Identities','Applications of identities']::text[]),
  ('sequences','Sequences',array['Basic sequences','General terms','Arithmetic and geometric sequences','Sum of arithmetic and geometric sequences']::text[]),
  ('inequalities','Inequalities',array['Properties of inequalities','Linear inequalities in one unknown','Compound linear inequalities','Quadratic inequalities in one unknown','Linear inequalities in two unknowns','System of linear inequalities','Linear programming']::text[]),
  ('mensuration','Mensuration',array['Length and area of plane figures','Surface area and volume of solids','Ratio of areas and volumes']::text[]),
  ('rectilinear-figures','Rectilinear figures',array['Angles and straight lines','Angles in triangles and polygons','Isosceles and equilateral triangles','Congruent and similar triangles','Special lines and centres of triangles','Triangle inequality','Quadrilaterals','Mid-point and intercept theorem']::text[]),
  ('statistics','Statistics',array['Data representation','Measures of central tendency','Measures of dispersion','Standard deviation and standard score','Effects of changing data','Uses and abuses of statistics']::text[]),
  ('equations','Equations',array['Linear equations in one unknown','Linear equations in two unknowns','Quadratic equations in one unknown','Nature of roots','Sum and product of roots','Equations reducible to quadratics','Simultaneous equations']::text[]),
  ('percentages','Percentages',array['Simple percentages','Selling problems','Interest','Successive percentage changes','Component percentage changes','Taxation and rates']::text[]),
  ('rates-ratios-and-variations','Rates, Ratios and Variations',array['Rates','Ratios','Variations']::text[]),
  ('trigonometry','Trigonometry',array['Trigonometric ratios','Trigonometric functions','Graphs of trigonometric functions','Trigonometric equations','2D trigonometry','3D trigonometry']::text[]),
  ('circles-and-tangents','Circles and tangents',array['Angles, arcs and chords','Cyclic quadrilaterals','Tangents']::text[]),
  ('counting-and-probability','Counting and Probability',array['Basic probabilities','Expected values','Permutations and combinations','Probabilities with nPr and nCr']::text[])
)
insert into public.review_topics(slug,name,parent_id,sort_order)
select main_slug,main_name,null,
  case main_slug
    when 'numbers-and-estimation' then 1 when 'polynomials' then 2 when 'exponentials-and-logarithms' then 3
    when 'functions-and-graphs' then 4 when 'transformation-and-symmetry' then 5 when 'coordinate-geometry' then 6
    when 'formulae-and-identities' then 7 when 'sequences' then 8 when 'inequalities' then 9 when 'mensuration' then 10
    when 'rectilinear-figures' then 11 when 'statistics' then 12 when 'equations' then 13 when 'percentages' then 14
    when 'rates-ratios-and-variations' then 15 when 'trigonometry' then 16 when 'circles-and-tangents' then 17
    when 'counting-and-probability' then 18 end
from topic_seed
on conflict (slug) do update set name = excluded.name;

with topic_seed(main_slug, main_name, subtopics) as (
  values
  ('numbers-and-estimation','Numbers and Estimation',array['Directed numbers','Surds','Number bases','Scientific notations','Estimation strategies','Estimation in measurements','Errors','Complex numbers']::text[]),
  ('polynomials','Polynomials',array['Fundamental operations of polynomials','Factorization','Remainder and factor theorem','HCF and LCM','Rational functions']::text[]),
  ('exponentials-and-logarithms','Exponentials and Logarithms',array['Indices and radicals','Logarithms','Exponential and logarithmic equations','Graphs of exponential and logarithmic functions','Applications of logarithms']::text[]),
  ('functions-and-graphs','Functions and graphs',array['Notation of functions','Graphs of linear functions','Graphs of quadratic functions','Optima of functions','Transformation of graphs']::text[]),
  ('transformation-and-symmetry','Transformation and Symmetry',array['Transformation of points','Transformation of plane figures','Symmetry of plane figures','3-D figures']::text[]),
  ('coordinate-geometry','Coordinate geometry',array['Polar coordinates','Distance formula','Slope and inclination','Mid-point and section formula','Equations of straight lines','Equations of circles','Intersections between straight lines and circles','Locus']::text[]),
  ('formulae-and-identities','Formulae and Identities',array['Change of subjects','Substitution','Algebraic fractions','Identities','Applications of identities']::text[]),
  ('sequences','Sequences',array['Basic sequences','General terms','Arithmetic and geometric sequences','Sum of arithmetic and geometric sequences']::text[]),
  ('inequalities','Inequalities',array['Properties of inequalities','Linear inequalities in one unknown','Compound linear inequalities','Quadratic inequalities in one unknown','Linear inequalities in two unknowns','System of linear inequalities','Linear programming']::text[]),
  ('mensuration','Mensuration',array['Length and area of plane figures','Surface area and volume of solids','Ratio of areas and volumes']::text[]),
  ('rectilinear-figures','Rectilinear figures',array['Angles and straight lines','Angles in triangles and polygons','Isosceles and equilateral triangles','Congruent and similar triangles','Special lines and centres of triangles','Triangle inequality','Quadrilaterals','Mid-point and intercept theorem']::text[]),
  ('statistics','Statistics',array['Data representation','Measures of central tendency','Measures of dispersion','Standard deviation and standard score','Effects of changing data','Uses and abuses of statistics']::text[]),
  ('equations','Equations',array['Linear equations in one unknown','Linear equations in two unknowns','Quadratic equations in one unknown','Nature of roots','Sum and product of roots','Equations reducible to quadratics','Simultaneous equations']::text[]),
  ('percentages','Percentages',array['Simple percentages','Selling problems','Interest','Successive percentage changes','Component percentage changes','Taxation and rates']::text[]),
  ('rates-ratios-and-variations','Rates, Ratios and Variations',array['Rates','Ratios','Variations']::text[]),
  ('trigonometry','Trigonometry',array['Trigonometric ratios','Trigonometric functions','Graphs of trigonometric functions','Trigonometric equations','2D trigonometry','3D trigonometry']::text[]),
  ('circles-and-tangents','Circles and tangents',array['Angles, arcs and chords','Cyclic quadrilaterals','Tangents']::text[]),
  ('counting-and-probability','Counting and Probability',array['Basic probabilities','Expected values','Permutations and combinations','Probabilities with nPr and nCr']::text[])
)
insert into public.review_topics(slug,name,parent_id,sort_order)
select s.main_slug || '--' || regexp_replace(lower(sub.topic_name),'[^a-z0-9]+','-','g'),
       sub.topic_name, p.id, sub.ordinality::integer
from topic_seed s
join public.review_topics p on p.slug = s.main_slug
cross join lateral unnest(s.subtopics) with ordinality as sub(topic_name, ordinality)
on conflict (slug) do update set name = excluded.name, parent_id = excluded.parent_id, sort_order = excluded.sort_order;

create or replace function public.review_start_quiz(p_topic_names text[], p_level smallint, p_question_count integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

  insert into public.review_attempt_questions(attempt_id,question_id,display_order,question_text_snapshot,options_snapshot)
  select v_attempt_id, q.id, row_number() over(order by random())::integer, q.question_text, q.options
  from (
    select distinct q0.id, q0.question_text, q0.options
    from public.review_questions q0
    join public.review_question_topics qt on qt.question_id = q0.id
    join public.review_topics t on t.id = qt.topic_id and t.parent_id is not null
    join public.review_answer_keys k on k.question_id = q0.id
    where q0.is_active and q0.level = p_level and t.name = any(p_topic_names)
  ) q
  order by random()
  limit p_question_count;

  select jsonb_agg(jsonb_build_object(
    'question_id', aq.question_id,
    'display_order', aq.display_order,
    'question_text', aq.question_text_snapshot,
    'options', aq.options_snapshot
  ) order by aq.display_order) into v_questions
  from public.review_attempt_questions aq where aq.attempt_id = v_attempt_id;

  return jsonb_build_object('ok',true,'attempt_id',v_attempt_id,'question_count',p_question_count,'questions',coalesce(v_questions,'[]'::jsonb));
end;
$$;

create or replace function public.review_submit_quiz(p_attempt_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  if v_attempt.submitted_at is not null then raise exception 'Attempt already submitted'; end if;

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
        select 1 from jsonb_array_elements(aq.options_snapshot) opt
        where coalesce(opt->>'key', opt->>'value') = x.selected_option
      )
  ) then raise exception 'Invalid option selected'; end if;

  insert into public.review_attempt_answers(attempt_id,question_id,selected_option,is_correct,correct_option,explanation_snapshot)
  select p_attempt_id, aq.question_id, x.selected_option,
         coalesce(x.selected_option = k.correct_option,false),
         k.correct_option, k.explanation
  from public.review_attempt_questions aq
  join public.review_answer_keys k on k.question_id=aq.question_id
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
  where a.id=p_attempt_id
  group by a.id;
  return v_details;
end;
$$;

create or replace function public.review_get_attempt_details(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_user_id uuid := auth.uid(); v_result jsonb;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select jsonb_build_object(
    'attempt_id', a.id, 'correct_count', a.correct_count, 'question_count', a.question_count,
    'selected_topics', to_jsonb(a.selected_topics), 'level', a.level,
    'created_at', a.created_at, 'submitted_at', a.submitted_at,
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
  ) into v_result
  from public.review_attempts a
  join public.review_attempt_questions aq on aq.attempt_id=a.id
  join public.review_attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
  where a.id=p_attempt_id and a.user_id=v_user_id and a.submitted_at is not null
  group by a.id;
  if v_result is null then raise exception 'Submitted attempt not found'; end if;
  return v_result;
end;
$$;

revoke all on function public.review_start_quiz(text[],smallint,integer) from public, anon;
revoke all on function public.review_submit_quiz(uuid,jsonb) from public, anon;
revoke all on function public.review_get_attempt_details(uuid) from public, anon;
grant execute on function public.review_start_quiz(text[],smallint,integer) to authenticated;
grant execute on function public.review_submit_quiz(uuid,jsonb) to authenticated;
grant execute on function public.review_get_attempt_details(uuid) to authenticated;
