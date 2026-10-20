# Question Bank RPC v1 — isolated test checklist

This is a draft migration and must only be tested in a disposable/local Supabase environment until the technical and production migration plans are approved. Never create test questions in production.

## Role and confidentiality tests
- Anonymous caller cannot execute any Question Bank RPC.
- Student cannot execute teacher submission, teacher listing, admin listing, admin save, or moderation successfully.
- Teacher can submit a bilingual MC and SQ question; new rows are pending.
- Teacher A cannot see Teacher B's submissions through the teacher list.
- Teacher cannot approve, reject, disable, re-enable, or edit another submission.
- Teacher and student cannot read the underlying tables through PostgREST.
- Admin can list all submissions, create a question, edit a question, approve own submissions, and moderate others' submissions.
- Audit rows record actor, action, old/new state, note, and timestamp.

## Payload validation tests
- Reject blank/overlong Question ID, unknown topics, missing Chinese or English stem, malformed topic arrays, and unsupported question type.
- MC accepts 2 and 6 options; rejects 1 or 7; requires bilingual text and at least one correct option; supports multiple correct options.
- SQ requires at least one part, non-empty part keys, positive integer marks, and bilingual answers.
- A malformed or missing field must fail closed (not silently pass due to SQL NULL semantics).
- Duplicate Question ID may be submitted but cannot be published when another published question already uses it.
- return moves a pending submission back to pending; reject marks rejected; disable marks published inactive; enable republishes after duplicate-ID check.

## UI regression tests
- Signed-out, student, teacher and admin access paths show the expected messages/permissions.
- Teacher list only contains own submissions; admin list contains all submissions.
- Cancelling the optional-reason prompt aborts moderation.
- Admin can disable published questions and re-enable inactive questions.
- English/Chinese language preference survives navigation and refresh.
- Empty bank renders as an empty state; no seeded production questions are required.

## Release gates
- Run SQL migration in an isolated test project and execute the role/payload cases above.
- Inspect SECURITY DEFINER function search_path and EXECUTE grants.
- Run Supabase security and performance advisors in the test project.
- Confirm rollback procedure and snapshot/activity compatibility before production deployment.
- Do not merge as production-ready until these checks pass; do not apply this draft to production without explicit approval of the migration plan.