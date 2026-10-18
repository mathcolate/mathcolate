-- Review quiz indexes identified during the post-migration advisor check.
create index if not exists review_attempt_questions_question_idx
  on public.review_attempt_questions(question_id);
create index if not exists review_questions_created_by_idx
  on public.review_questions(created_by)
  where created_by is not null;
