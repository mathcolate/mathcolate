-- Security hardening for the existing Review implementation.
-- Purpose: prevent authenticated students from directly listing every active question prompt.
-- Review quiz delivery remains through the SECURITY DEFINER RPC review_start_quiz.
-- This migration is committed for review only; do not apply to production until reviewed.

begin;

drop policy if exists "review active question prompt read" on public.review_questions;

-- The existing "review questions admin manage" policy remains in place.
-- Authenticated clients retain the table grant, but RLS now prevents non-admin
-- users from directly selecting the central prompt bank. The SECURITY DEFINER
-- quiz RPC can still select eligible prompts and return only the quiz snapshot.

commit;
