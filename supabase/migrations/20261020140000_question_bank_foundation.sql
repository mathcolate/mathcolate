begin;

create type public.mc_question_kind as enum ('MC', 'SQ');
create type public.mc_question_state as enum ('pending', 'approved', 'rejected', 'disabled');

create table public.mc_question_bank (
  id uuid primary key default gen_random_uuid(),
  question_code text not null,
  kind public.mc_question_kind not null,
  stem jsonb not null,
  choices jsonb not null default '[]'::jsonb,
  subparts jsonb not null default '[]'::jsonb,
  shared_assets jsonb not null default '[]'::jsonb,
  points integer not null default 1 check (points > 0),
  state public.mc_question_state not null default 'pending',
  submitted_by uuid not null references auth.users(id) on delete restrict,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mc_question_code_nonempty check (length(trim(question_code)) > 0),
  constraint mc_question_stem_object check (jsonb_typeof(stem) = 'object'),
  constraint mc_question_choices_array check (jsonb_typeof(choices) = 'array'),
  constraint mc_question_subparts_array check (jsonb_typeof(subparts) = 'array'),
  constraint mc_question_assets_array check (jsonb_typeof(shared_assets) = 'array'),
  constraint mc_question_review_metadata check (
    (state = 'pending' and reviewed_at is null and reviewed_by is null)
    or state <> 'pending'
  )
);
create unique index mc_question_bank_code_ci_uidx on public.mc_question_bank (lower(question_code));
create index mc_question_bank_state_kind_idx on public.mc_question_bank (state, kind, updated_at desc);
create index mc_question_bank_submitter_idx on public.mc_question_bank (submitted_by, created_at desc);

create table public.mc_question_answer_keys (
  question_id uuid primary key references public.mc_question_bank(id) on delete cascade,
  answer_payload jsonb not null,
  explanation jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint mc_question_answer_payload_object check (jsonb_typeof(answer_payload) = 'object'),
  constraint mc_question_explanation_object check (jsonb_typeof(explanation) = 'object')
);

create table public.mc_question_topics (
  question_id uuid not null references public.mc_question_bank(id) on delete cascade,
  topic_id uuid not null references public.review_topics(id) on delete restrict,
  primary key (question_id, topic_id)
);
create index mc_question_topics_topic_idx on public.mc_question_topics(topic_id, question_id);

create table public.mc_question_id_changes (
  id bigint generated always as identity primary key,
  question_id uuid not null references public.mc_question_bank(id) on delete restrict,
  old_code text not null,
  new_code text not null,
  admin_id uuid not null references auth.users(id) on delete restrict,
  changed_at timestamptz not null default now()
);
create index mc_question_id_changes_question_idx on public.mc_question_id_changes(question_id, changed_at desc);

create table public.mc_question_suggestions (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.mc_question_bank(id) on delete cascade,
  teacher_id uuid not null references auth.users(id) on delete restrict,
  suggested_changes jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_reason text,
  constraint mc_question_suggestion_object check (jsonb_typeof(suggested_changes) = 'object')
);
create index mc_question_suggestions_question_status_idx on public.mc_question_suggestions(question_id, status, created_at);

create or replace function public.mc_is_teacher_or_admin()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from public.users_acc_info u
    where u.id = (select auth.uid()) and u.role in ('teacher'::public.user_role, 'admin'::public.user_role)
  );
$$;

create or replace function public.mc_touch_question_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

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
    if v_role is distinct from 'admin'::public.user_role then
      raise exception 'Only an admin may change a Question ID' using errcode = '42501';
    end if;
    insert into public.mc_question_id_changes(question_id, old_code, new_code, admin_id)
    values (old.id, old.question_code, new.question_code, (select auth.uid()));
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger mc_question_bank_audit_code
before update on public.mc_question_bank
for each row execute function public.mc_audit_question_code_change();

create or replace function public.mc_submit_question(
  p_question jsonb,
  p_answer_key jsonb,
  p_topic_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
  if v_role not in ('teacher'::public.user_role, 'admin'::public.user_role) then
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
    if jsonb_typeof(p_answer_key->'answer_payload'->'parts') <> 'object' then
      raise exception 'SQ answer payload must contain a parts object';
    end if;
  end if;
  if coalesce(array_length(p_topic_ids, 1), 0) = 0 then raise exception 'Select at least one topic'; end if;

  insert into public.mc_question_bank(question_code, kind, stem, choices, subparts, shared_assets, points, state, submitted_by)
  values (v_code, v_kind, v_stem, v_choices, v_subparts, v_assets, v_points,
          case when v_role = 'admin'::public.user_role then 'approved'::public.mc_question_state else 'pending'::public.mc_question_state end,
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
  if p_decision not in ('approved'::public.mc_question_state, 'rejected'::public.mc_question_state, 'disabled'::public.mc_question_state) then
    raise exception 'Invalid moderation decision';
  end if;
  update public.mc_question_bank
  set state = p_decision, reviewed_by = v_uid, reviewed_at = now(), review_reason = nullif(trim(p_reason),'')
  where id = p_question_id;
  if not found then raise exception 'Question not found'; end if;
end;
$$;

create or replace function public.mc_suggest_question_changes(
  p_question_id uuid,
  p_suggested_changes jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.user_role;
  v_suggestion_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode = '28000'; end if;
  select u.role into v_role from public.users_acc_info u where u.id = v_uid;
  if v_role not in ('teacher'::public.user_role, 'admin'::public.user_role) then raise exception 'Teacher or admin role required' using errcode = '42501'; end if;
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
$$;

create or replace function public.mc_update_question_id(
  p_question_id uuid,
  p_new_question_code text
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
  if nullif(trim(p_new_question_code), '') is null then raise exception 'Question ID is required'; end if;
  update public.mc_question_bank set question_code=trim(p_new_question_code) where id=p_question_id;
  if not found then raise exception 'Question not found'; end if;
exception
  when unique_violation then raise exception 'Question ID already exists';
end;
$;

create or replace function public.mc_review_question_suggestion(
  p_suggestion_id uuid,
  p_decision text,
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
  if p_decision is distinct from 'rejected' then raise exception 'Invalid suggestion decision'; end if;
  update public.mc_question_suggestions
  set status='rejected', reviewed_by=v_uid, reviewed_at=now(), review_reason=nullif(trim(p_reason),'')
  where id=p_suggestion_id and status='pending';
  if not found then raise exception 'Pending suggestion not found'; end if;
end;
$$;

alter table public.mc_question_bank enable row level security;
alter table public.mc_question_answer_keys enable row level security;
alter table public.mc_question_topics enable row level security;
alter table public.mc_question_id_changes enable row level security;
alter table public.mc_question_suggestions enable row level security;

grant select on public.mc_question_bank, public.mc_question_topics, public.mc_question_suggestions to authenticated;
-- Suggestion writes go through the ownership-checked RPC only.
grant select on public.mc_question_answer_keys to authenticated;
grant select on public.mc_question_id_changes to authenticated;
revoke all on public.mc_question_answer_keys from anon, public;
revoke all on public.mc_question_id_changes from anon, public;

create policy mc_question_bank_select_teacher_admin on public.mc_question_bank
for select to authenticated
using (
  exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role='admin'::public.user_role)
  or (exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role='teacher'::public.user_role)
      and (state='approved'::public.mc_question_state or submitted_by=(select auth.uid())))
);
create policy mc_question_answer_keys_select_teacher_admin on public.mc_question_answer_keys
for select to authenticated
using (
  exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role='admin'::public.user_role)
  or exists (
    select 1 from public.users_acc_info u join public.mc_question_bank q on q.id=public.mc_question_answer_keys.question_id
    where u.id=(select auth.uid()) and u.role='teacher'::public.user_role
      and (q.state='approved'::public.mc_question_state or q.submitted_by=(select auth.uid()))
  )
);
create policy mc_question_topics_select_teacher_admin on public.mc_question_topics
for select to authenticated
using (exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role in ('teacher'::public.user_role,'admin'::public.user_role)));
create policy mc_question_id_changes_admin_select on public.mc_question_id_changes
for select to authenticated
using (exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role='admin'::public.user_role));
create policy mc_question_suggestions_select_owner_admin on public.mc_question_suggestions
for select to authenticated
using (teacher_id=(select auth.uid()) or exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role='admin'::public.user_role));
create policy mc_question_suggestions_insert_teacher on public.mc_question_suggestions
for insert to authenticated
with check (
  teacher_id=(select auth.uid())
  and exists (select 1 from public.users_acc_info u where u.id=(select auth.uid()) and u.role in ('teacher'::public.user_role,'admin'::public.user_role))
);

revoke all on function public.mc_is_teacher_or_admin() from public, anon;
revoke all on function public.mc_touch_question_updated_at() from public, anon, authenticated;
revoke all on function public.mc_audit_question_code_change() from public, anon, authenticated;
revoke all on function public.mc_submit_question(jsonb,jsonb,uuid[]) from public, anon;
revoke all on function public.mc_moderate_question(uuid,public.mc_question_state,text) from public, anon;
revoke all on function public.mc_suggest_question_changes(uuid,jsonb) from public, anon;
revoke all on function public.mc_review_question_suggestion(uuid,text,text) from public, anon;
revoke all on function public.mc_update_question_id(uuid,text) from public, anon;
grant execute on function public.mc_submit_question(jsonb,jsonb,uuid[]) to authenticated;
grant execute on function public.mc_moderate_question(uuid,public.mc_question_state,text) to authenticated;
grant execute on function public.mc_suggest_question_changes(uuid,jsonb) to authenticated;
grant execute on function public.mc_review_question_suggestion(uuid,text,text) to authenticated;
grant execute on function public.mc_update_question_id(uuid,text) to authenticated;

commit;
