# Mathcolate implementation plan (based on approved requirements)

This work must modify the existing Mathcolate project and its existing pages/code, not create a separate product or duplicate implementation. Use `feature/preview-review-online-test` as the working branch in the same `mathcolate/mathcolate` repository, then review changes before merging to the repository's main branch. Do not treat `mathcolate-test` as the main development target. Any separate test environment is supplementary only; it must not replace fixing the actual Mathcolate project. Database changes to the main project must be handled deliberately and reviewed before execution.

## Existing architecture observed
- Static HTML pages use Supabase JS v2 from CDN and share the existing header/auth/language pattern.
- `users_acc_info` supplies the authenticated user's role, school and class codes.
- Review already has `review_topics`, `review_questions`, `review_answer_keys`, `review_question_topics`, `review_attempts`, `review_attempt_questions` and `review_attempt_answers`. Keep and extend this system rather than creating duplicate Review tables.
- Keep the existing Review implementation and data model as the starting point. Do not create duplicate Review tables or a parallel feature implementation. Prefer static/unit checks first; if database integration testing is needed, it is supplementary and must not divert implementation away from the existing Mathcolate project.

## Data model approach
1. Central Question Bank:
   - One canonical question record with teacher-assigned Question ID, MC/SQ type, bilingual stem/choices/subparts/explanations, shared image/LaTeX references, integer points and active/pending/rejected state.
   - Separate review/audit metadata for submission, moderation and Question ID changes.
   - Separate modification suggestions, allowing multiple pending suggestions per published question.
   - Reuse existing topic hierarchy and question-topic mapping where feasible.
2. Activities:
   - Separate Preview, Review and Online Test activity types/statuses.
   - Drafts reference current Question Bank content; publication creates immutable per-activity question snapshots.
   - Explicit target class codes and owner teacher ID. Membership is checked at activity entry and rechecked while answering.
   - Attempts, per-question/per-subpart saved answers and the latest official score are separate from snapshots.
   - Online Test start time is a single server-generated timestamp; deadline is start plus duration. During an active test, teacher views progress/submission metadata only, not answer payloads.
3. Server-side operations:
   - Use authenticated RPC functions for publish/start/save/submit/grade/score-edit/delete/cancel operations where transaction integrity matters.
   - Derive role and ownership from `auth.uid()` and `users_acc_info`, never trust a client-supplied role or teacher ID.
   - Keep answer keys unavailable to students until the relevant submission/release rule permits them.
   - Keep irreversible deletion behind explicit ownership checks and a second confirmation in the UI.
4. SQ grading:
   - Use exact rational/decimal parsing; do not use floating point equality.
   - Parse only a documented whitelist of numeric forms and supported English unit symbols. Unknown/invalid forms score zero.
   - Store unit-required settings per SQ subpart; integer points only; manual edits constrained by activity type, deadline and allowed window.
5. Existing requirement decisions to preserve:
   - Preview deadline auto-submits saved answers; official score is the highest valid attempt, including the deadline submission.
   - Preview score edits after deadline do not reopen it; qualifying pre-deadline score edits may reopen a previously perfect student if the specification's conditions are met.
   - Review is one submission per attempt, no class statistics, and shows answers/explanations after submit.
   - Online Test allows one submission; unanswered/not-submitted students score zero at deadline; live histogram excludes non-submitters before deadline and includes them as zero after deadline.
   - Simulations must not save student interaction or personal learning history.

## Implementation order
1. Inspect the existing project and Review flow; make changes directly in the existing HTML/JavaScript/CSS and reuse existing schema wherever possible. Draft any necessary schema changes and authorization checks for review before execution.
2. Implement bilingual Question Bank teacher form, moderation queue and suggestion workflow.
3. Implement Preview draft/publish/student attempt/autosave/retry/deadline/score correction.
4. Complete Review with question-bank compatibility, exact SQ parsing and one-submit enforcement.
5. Implement Online Test waiting/start/single deadline/autosave/teacher progress/submit status/histogram/CSV+Excel export.
6. Run static checks and regression tests against the actual code changes. Use a separate Supabase project only if a database integration test genuinely requires it; it is not the development target and must not become a substitute for fixing the main project.

## Required tests
- RLS role/owner/target-class matrix for student, teacher and admin.
- Students cannot enumerate Question Bank records or read answer keys before release.
- A teacher cannot read another teacher's private activity, scores or export.
- Student membership changes stop further answering; saved answers are graded according to the specification.
- Concurrent save/submit/start requests are idempotent and deadline checks use server time.
- MC multi-select requires exact set equality; SQ parser rejects unsupported forms and avoids float precision errors.
- Preview deadline auto-submit preserves highest score; Review cannot resubmit; Online Test late/non-submit behavior and histogram inclusion rules match the spec.
- Cancellation/deletion behavior and audit-record deletion are tested in a disposable project.
- UI regression: auth hydration, language persistence, navigation, narrow/mobile layout.

## Deployment boundary
Implementation must remain focused on the existing Mathcolate repository and its current product. Do not merge code or apply production schema changes without the appropriate review/authorization. A test project is optional supporting infrastructure, not the place where the main feature is implemented.
