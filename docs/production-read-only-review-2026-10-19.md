# Production read-only review — 2026-10-19

## Scope and safety
This is a read-only observation of the existing `mathcolate` Supabase project. No SQL migration, policy, function, account setting, or production data was changed.

## Existing schema observations
- The production project has the existing `users_acc_info` role/profile table and the Review tables, including `review_topics`, `review_questions`, `review_answer_keys`, `review_question_topics`, and attempt-related tables.
- RLS is enabled on the inspected profile and Review tables.
- The production role field uses the `user_role` enum with `student`, `teacher`, and `admin`.

## Security Advisor findings observed
1. Supabase Advisor reports three callable `SECURITY DEFINER` Review RPC functions: `review_get_attempt_details`, `review_start_quiz`, and `review_submit_quiz`. This warning is not, by itself, proof of a vulnerability: the application intentionally calls RPCs. Before changing grants or security mode, inspect each function body and verify it checks `auth.uid()`, attempt ownership, allowed state transitions, and that answer keys are not returned before submission. A blanket revoke could break Review.
2. Supabase Advisor reports leaked-password protection is disabled. This is an Auth project setting, not a code migration. Review the current password policy and enable leaked-password protection only after confirming the intended Auth configuration.

## Immediate implementation safeguards
- Do not apply the draft `review_prompt_access_hardening.sql` migration to production yet. Its policy name and effects must first be verified against the live policy definitions and the three RPC bodies.
- Do not merge the draft Question Bank/activity schema until its RLS policies and server-side RPC contracts have been completed and tested.
- Continue implementing in `mathcolate/mathcolate` on `feature/preview-review-online-test`; keep production database changes separate from code review.

## Next checks before a production migration
- Read the exact definitions and grants of the three Review RPC functions.
- Read all policies and grants on `review_questions` and `review_answer_keys`.
- Verify student/teacher/admin access using role-based tests.
- Confirm that direct table reads cannot expose central question prompts or answer keys outside the intended flow.
- Prepare a reviewed migration and rollback plan; do not execute until separately approved.
