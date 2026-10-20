alter type public.mc_question_state add value if not exists 'returned';
alter type public.mc_attempt_state add value if not exists 'not_submitted';