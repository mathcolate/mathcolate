-- DRAFT ONLY: Central Question Bank + activity foundation.
-- This file is intentionally not applied to any Supabase project.
-- Review the full policy and RPC design before deployment.

create type public.mc_question_kind as enum ('MC', 'SQ');
create type public.mc_question_state as enum ('pending', 'approved', 'rejected', 'disabled');
create type public.mc_activity_kind as enum ('preview', 'review', 'online_test');
create type public.mc_activity_state as enum ('draft', 'published', 'waiting', 'in_progress', 'ended', 'cancelled');

create table public.mc_question_bank (
  id uuid primary key default gen_random_uuid(),
  question_code text not null,
  kind public.mc_question_kind not null,
  stem jsonb not null,
  choices jsonb not null default '[]'::jsonb,
  subparts jsonb not null default '[]'::jsonb,
  shared_assets jsonb not null default '[]'::jsonb,
  topic_ids uuid[] not null default '{}',
  state public.mc_question_state not null default 'pending',
  submitted_by uuid not null references auth.users(id),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_reason text,
  usage_count bigint not null default 0 check (usage_count >= 0),
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mc_question_code_nonempty check (length(trim(question_code)) > 0),
  constraint mc_question_stem_object check (jsonb_typeof(stem) = 'object'),
  constraint mc_question_choices_array check (jsonb_typeof(choices) = 'array'),
  constraint mc_question_subparts_array check (jsonb_typeof(subparts) = 'array'),
  constraint mc_question_assets_array check (jsonb_typeof(shared_assets) = 'array')
);
create index mc_question_bank_code_idx on public.mc_question_bank(question_code);
create index mc_question_bank_state_kind_idx on public.mc_question_bank(state, kind);
create index mc_question_bank_submitter_idx on public.mc_question_bank(submitted_by);

create table public.mc_question_id_changes (
  id bigint generated always as identity primary key,
  question_id uuid not null references public.mc_question_bank(id) on delete cascade,
  old_code text not null,
  new_code text not null,
  admin_id uuid not null references auth.users(id),
  changed_at timestamptz not null default now()
);
create index mc_question_id_changes_question_idx on public.mc_question_id_changes(question_id, changed_at desc);

create table public.mc_question_suggestions (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.mc_question_bank(id) on delete cascade,
  teacher_id uuid not null references auth.users(id),
  suggested_changes jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'rejected')),
  created_at timestamptz not null default now(),
  constraint mc_suggestion_payload_object check (jsonb_typeof(suggested_changes) = 'object')
);
create index mc_question_suggestions_question_status_idx on public.mc_question_suggestions(question_id, status, created_at);

create table public.mc_activities (
  id uuid primary key default gen_random_uuid(),
  kind public.mc_activity_kind not null,
  state public.mc_activity_state not null default 'draft',
  title jsonb not null,
  instructions jsonb not null default '{}'::jsonb,
  owner_teacher_id uuid not null references auth.users(id),
  target_class_codes text[] not null default '{}',
  due_at timestamptz,
  duration_seconds integer,
  randomize_questions boolean not null default false,
  randomize_choices boolean not null default false,
  feedback_mode text not null default 'after_activity' check (feedback_mode in ('per_question', 'after_activity')),
  published_at timestamptz,
  started_at timestamptz,
  deadline_at timestamptz,
  cancelled_keep_records boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mc_activity_title_object check (jsonb_typeof(title) = 'object'),
  constraint mc_activity_instructions_object check (jsonb_typeof(instructions) = 'object'),
  constraint mc_activity_target_classes_nonempty check (cardinality(target_class_codes) > 0 or kind = 'review'),
  constraint mc_activity_due_required check (kind <> 'preview' or due_at is not null),
  constraint mc_activity_duration_positive check (duration_seconds is null or duration_seconds > 0),
  constraint mc_activity_online_duration check (kind <> 'online_test' or duration_seconds is not null)
);
create index mc_activities_owner_kind_state_idx on public.mc_activities(owner_teacher_id, kind, state, created_at desc);
create index mc_activities_state_deadline_idx on public.mc_activities(state, deadline_at);

create table public.mc_activity_questions (
  activity_id uuid not null references public.mc_activities(id) on delete cascade,
  question_id uuid not null references public.mc_question_bank(id) on delete restrict,
  display_order integer not null check (display_order > 0),
  question_snapshot jsonb not null,
  answer_snapshot jsonb not null,
  max_points integer not null check (max_points > 0),
  primary key (activity_id, display_order),
  unique (activity_id, question_id),
  constraint mc_activity_question_snapshot_object check (jsonb_typeof(question_snapshot) = 'object'),
  constraint mc_activity_answer_snapshot_object check (jsonb_typeof(answer_snapshot) = 'object')
);

create table public.mc_activity_attempts (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.mc_activities(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  attempt_number integer not null default 1 check (attempt_number > 0),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  is_auto_submitted boolean not null default false,
  correct_points integer,
  max_points integer not null check (max_points >= 0),
  last_saved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (activity_id, student_id, attempt_number),
  constraint mc_attempt_score_range check (correct_points is null or (correct_points >= 0 and correct_points <= max_points))
);
create index mc_activity_attempts_activity_student_idx on public.mc_activity_attempts(activity_id, student_id, attempt_number desc);
create index mc_activity_attempts_student_recent_idx on public.mc_activity_attempts(student_id, created_at desc);

create table public.mc_attempt_answers (
  attempt_id uuid not null references public.mc_activity_attempts(id) on delete cascade,
  activity_id uuid not null,
  question_order integer not null,
  subpart_key text not null default '',
  answer_payload jsonb not null,
  is_correct boolean,
  awarded_points integer,
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_order, subpart_key),
  foreign key (activity_id, question_order) references public.mc_activity_questions(activity_id, display_order) on delete cascade,
  constraint mc_attempt_answer_payload_object check (jsonb_typeof(answer_payload) = 'object'),
  constraint mc_attempt_awarded_nonnegative check (awarded_points is null or awarded_points >= 0)
);
create index mc_attempt_answers_activity_idx on public.mc_attempt_answers(activity_id, attempt_id);

alter table public.mc_question_bank enable row level security;
alter table public.mc_question_id_changes enable row level security;
alter table public.mc_question_suggestions enable row level security;
alter table public.mc_activities enable row level security;
alter table public.mc_activity_questions enable row level security;
alter table public.mc_activity_attempts enable row level security;
alter table public.mc_attempt_answers enable row level security;

-- Deliberately no direct grants/policies yet: privileged reads/writes will be exposed
-- through reviewed SECURITY DEFINER RPCs with explicit auth.uid(), role, ownership,
-- target-class membership, lifecycle and deadline checks. This avoids exposing answer
-- snapshots or student answer payloads while the RPC policy contract is being finalized.
