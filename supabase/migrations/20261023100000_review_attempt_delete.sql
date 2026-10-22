-- Allow a student to permanently delete only their own submitted Review attempt.
-- Child answer and question snapshot rows cascade from review_attempts.
create or replace function public.review_delete_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_deleted_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  delete from public.review_attempts a
   where a.id = p_attempt_id
     and a.user_id = v_user_id
     and a.submitted_at is not null
   returning a.id into v_deleted_id;

  if v_deleted_id is null then
    -- Do not reveal whether another user's attempt exists.
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'attempt_id', v_deleted_id);
end;
$function$;

revoke all on function public.review_delete_attempt(uuid) from public;
revoke all on function public.review_delete_attempt(uuid) from anon;
grant execute on function public.review_delete_attempt(uuid) to authenticated;
