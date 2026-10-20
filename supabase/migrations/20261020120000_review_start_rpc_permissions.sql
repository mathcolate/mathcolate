-- Keep Review start RPC permissions reproducible across environments.
begin;
revoke all on function public.review_start_quiz(text[],smallint,integer) from public, anon, authenticated;
revoke all on function public.review_start_quiz(text[],smallint,integer,uuid) from public, anon, authenticated;
grant execute on function public.review_start_quiz(text[],smallint,integer,uuid) to authenticated;
commit;
