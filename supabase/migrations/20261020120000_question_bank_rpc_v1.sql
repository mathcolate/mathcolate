-- Draft migration only: review and test in an isolated Supabase project before production.
create table if not exists public.mc_question_bank (
 id uuid primary key default gen_random_uuid(),
 question_code text not null,
 kind text not null check(kind in ('MC','SQ')),
 stem jsonb not null,
 choices jsonb not null default '[]'::jsonb,
 subparts jsonb not null default '[]'::jsonb,
 explanation jsonb not null default '{}'::jsonb,
 topic_ids uuid[] not null default '{}',
 state text not null default 'pending' check(state in ('pending','published','rejected','inactive')),
 submitted_by uuid not null references auth.users(id),
 updated_by uuid not null references auth.users(id),
 review_note text,
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.mc_question_bank enable row level security;
revoke all on public.mc_question_bank from public, anon, authenticated;

create table if not exists public.mc_question_bank_audit (
 id bigint generated always as identity primary key,
 question_id uuid not null,
 actor_id uuid not null references auth.users(id),
 action text not null, previous_state text, new_state text, note text,
 created_at timestamptz not null default now()
);
alter table public.mc_question_bank_audit enable row level security;
revoke all on public.mc_question_bank_audit from public, anon, authenticated;

create or replace function public.mc_qb_is_admin()
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.users_acc_info u where u.id=(select auth.uid()) and lower(u.role::text)='admin'); $$;
revoke all on function public.mc_qb_is_admin() from public, anon;
grant execute on function public.mc_qb_is_admin() to authenticated;

create or replace function public.mc_qb_validate_payload(p jsonb)
returns void language plpgsql set search_path=''
as $$
declare k text:=p->>'kind'; topics jsonb:=p->'topics'; choices jsonb:=coalesce(p->'choices','[]'::jsonb); parts jsonb:=coalesce(p->'subparts','[]'::jsonb); n int; good int;
begin
 if nullif(btrim(p->>'question_code'),'') is null or length(p->>'question_code')>120 then raise exception 'Question ID required (max 120 characters)'; end if;
 if k not in ('MC','SQ') then raise exception 'Unsupported question type'; end if;
 if jsonb_typeof(topics)<>'array' or jsonb_array_length(topics)=0 then raise exception 'At least one topic required'; end if;
 if nullif(btrim(p->'stem'->>'en'),'') is null or nullif(btrim(p->'stem'->>'zh'),'') is null then raise exception 'Both language versions are required'; end if;
 select count(distinct id) into n from public.review_topics where name in(select jsonb_array_elements_text(topics));
 if n<>(select count(distinct value) from jsonb_array_elements_text(topics) as x(value)) then raise exception 'Unknown topic'; end if;
 if k='MC' then
  if jsonb_typeof(choices)<>'array' then raise exception 'Choices must be an array'; end if;
  n:=jsonb_array_length(choices);
  if n<2 or n>6 then raise exception 'MC requires 2 to 6 choices'; end if;
  select count(*) into good from jsonb_array_elements(choices) c where coalesce((c->>'correct')::boolean,false);
  if good=0 then raise exception 'At least one correct choice required'; end if;
  if exists(select 1 from jsonb_array_elements(choices) c where nullif(btrim(c->>'en'),'') is null or nullif(btrim(c->>'zh'),'') is null) then raise exception 'Bilingual choices required'; end if;
 else
  if jsonb_typeof(parts)<>'array' or jsonb_array_length(parts)=0 then raise exception 'SQ requires at least one part'; end if;
  if exists(select 1 from jsonb_array_elements(parts) p2 where nullif(btrim(p2->>'key'),'') is null or coalesce(p2->>'marks','') !~ '^[0-9]+$' or (p2->>'marks')::int<1 or nullif(btrim(p2->>'answer_en'),'') is null or nullif(btrim(p2->>'answer_zh'),'') is null) then raise exception 'Each SQ part requires key, positive integer marks and bilingual answers'; end if;
 end if;
end $$;
revoke all on function public.mc_qb_validate_payload(jsonb) from public, anon, authenticated;

create or replace function public.mc_qb_row_json(q public.mc_question_bank)
returns jsonb language sql stable set search_path=''
as $$ select jsonb_build_object('id',q.id,'question_code',q.question_code,'kind',q.kind,'stem',q.stem,'choices',q.choices,'subparts',q.subparts,'explanation',q.explanation,'topics',coalesce((select jsonb_agg(t.name order by t.name) from public.review_topics t where t.id=any(q.topic_ids)),'[]'::jsonb),'state',q.state,'review_note',q.review_note,'submitted_by',q.submitted_by,'created_at',q.created_at,'updated_at',q.updated_at); $$;
revoke all on function public.mc_qb_row_json(public.mc_question_bank) from public, anon, authenticated;

create or replace function public.mc_question_bank_teacher_list(p_state text default 'all',p_kind text default 'all',p_query text default '')
returns jsonb language plpgsql security definer set search_path=''
as $$
declare uid uuid:=(select auth.uid()); r text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select lower(role::text) into r from public.users_acc_info where id=uid;
 if r not in ('teacher','admin') then raise exception 'Teacher role required'; end if;
 return coalesce((select jsonb_agg(public.mc_qb_row_json(q) order by q.question_code) from public.mc_question_bank q where (r='admin' or q.submitted_by=uid) and (p_state='all' or q.state=p_state) and (p_kind='all' or q.kind=p_kind) and (coalesce(p_query,'')='' or q.question_code ilike '%'||p_query||'%')),'[]'::jsonb);
end $$;

create or replace function public.mc_question_bank_admin_list(p_state text default 'all',p_kind text default 'all',p_query text default '')
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not public.mc_qb_is_admin() then raise exception 'Administrator role required'; end if;
 return coalesce((select jsonb_agg(public.mc_qb_row_json(q) order by q.question_code) from public.mc_question_bank q where (p_state='all' or q.state=p_state) and (p_kind='all' or q.kind=p_kind) and (coalesce(p_query,'')='' or q.question_code ilike '%'||p_query||'%')),'[]'::jsonb);
end $$;

create or replace function public.mc_question_bank_teacher_submit(p_question jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare uid uuid:=(select auth.uid()); id_out uuid; tids uuid[];
begin
 if uid is null or not exists(select 1 from public.users_acc_info where id=uid and lower(role::text)='teacher') then raise exception 'Teacher role required'; end if;
 perform public.mc_qb_validate_payload(p_question);
 select array_agg(id) into tids from public.review_topics where name in(select jsonb_array_elements_text(p_question->'topics'));
 insert into public.mc_question_bank(question_code,kind,stem,choices,subparts,explanation,topic_ids,state,submitted_by,updated_by)
 values(btrim(p_question->>'question_code'),p_question->>'kind',p_question->'stem',coalesce(p_question->'choices','[]'::jsonb),coalesce(p_question->'subparts','[]'::jsonb),coalesce(p_question->'explanation','{}'::jsonb),tids,'pending',uid,uid) returning id into id_out;
 insert into public.mc_question_bank_audit(question_id,actor_id,action,new_state) values(id_out,uid,'teacher_submit','pending');
 return id_out;
end $$;

create or replace function public.mc_question_bank_admin_save(p_question jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare uid uuid:=(select auth.uid()); id_out uuid; tids uuid[]; old_state text;
begin
 if not public.mc_qb_is_admin() then raise exception 'Administrator role required'; end if;
 perform public.mc_qb_validate_payload(p_question);
 select array_agg(id) into tids from public.review_topics where name in(select jsonb_array_elements_text(p_question->'topics'));
 if nullif(p_question->>'id','') is null then
  insert into public.mc_question_bank(question_code,kind,stem,choices,subparts,explanation,topic_ids,state,submitted_by,updated_by)
  values(btrim(p_question->>'question_code'),p_question->>'kind',p_question->'stem',coalesce(p_question->'choices','[]'::jsonb),coalesce(p_question->'subparts','[]'::jsonb),coalesce(p_question->'explanation','{}'::jsonb),tids,'pending',uid,uid) returning id into id_out;
  insert into public.mc_question_bank_audit(question_id,actor_id,action,new_state) values(id_out,uid,'admin_create','pending');
 else
  id_out:=(p_question->>'id')::uuid;
  select state into old_state from public.mc_question_bank where id=id_out;
  if not found then raise exception 'Question not found'; end if;
  update public.mc_question_bank set question_code=btrim(p_question->>'question_code'),kind=p_question->>'kind',stem=p_question->'stem',choices=coalesce(p_question->'choices','[]'::jsonb),subparts=coalesce(p_question->'subparts','[]'::jsonb),explanation=coalesce(p_question->'explanation','{}'::jsonb),topic_ids=tids,updated_by=uid,updated_at=now() where id=id_out;
  insert into public.mc_question_bank_audit(question_id,actor_id,action,previous_state,new_state) values(id_out,uid,'admin_edit',old_state,old_state);
 end if;
 return id_out;
end $$;

create or replace function public.mc_question_bank_admin_moderate(p_question_id uuid,p_action text,p_reason text default '')
returns boolean language plpgsql security definer set search_path=''
as $$
declare uid uuid:=(select auth.uid()); old_state text; new_state text; code text;
begin
 if not public.mc_qb_is_admin() then raise exception 'Administrator role required'; end if;
 select state,question_code into old_state,code from public.mc_question_bank where id=p_question_id for update;
 if not found then raise exception 'Question not found'; end if;
 if p_action='approve' or p_action='enable' then
  if exists(select 1 from public.mc_question_bank where question_code=code and state='published' and id<>p_question_id) then raise exception 'Question ID already published'; end if;
  new_state:='published';
 elsif p_action='return' then new_state:='pending';
 elsif p_action='reject' then new_state:='rejected';
 elsif p_action='disable' then new_state:='inactive';
 else raise exception 'Unsupported moderation action'; end if;
 update public.mc_question_bank set state=new_state,review_note=nullif(btrim(coalesce(p_reason,'')),''),reviewed_by=uid,reviewed_at=now(),updated_by=uid,updated_at=now() where id=p_question_id;
 insert into public.mc_question_bank_audit(question_id,actor_id,action,previous_state,new_state,note) values(p_question_id,uid,p_action,old_state,new_state,nullif(btrim(coalesce(p_reason,'')),''));
 return true;
end $$;

revoke all on function public.mc_question_bank_teacher_list(text,text,text) from public, anon;
revoke all on function public.mc_question_bank_admin_list(text,text,text) from public, anon;
revoke all on function public.mc_question_bank_teacher_submit(jsonb) from public, anon;
revoke all on function public.mc_question_bank_admin_save(jsonb) from public, anon;
revoke all on function public.mc_question_bank_admin_moderate(uuid,text,text) from public, anon;
grant execute on function public.mc_question_bank_teacher_list(text,text,text) to authenticated;
grant execute on function public.mc_question_bank_admin_list(text,text,text) to authenticated;
grant execute on function public.mc_question_bank_teacher_submit(jsonb) to authenticated;
grant execute on function public.mc_question_bank_admin_save(jsonb) to authenticated;
grant execute on function public.mc_question_bank_admin_moderate(uuid,text,text) to authenticated;
