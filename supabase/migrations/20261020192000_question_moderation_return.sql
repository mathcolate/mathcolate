begin;
create or replace function public.mc_moderate_question(
 p_question_id uuid,p_decision public.mc_question_state,p_reason text default null)
returns void language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=(select auth.uid()); v_role public.user_role;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select u.role into v_role from public.users_acc_info u where u.id=v_uid;
 if v_role is distinct from 'admin'::public.user_role then raise exception 'Admin role required' using errcode='42501'; end if;
 if p_decision not in ('approved'::public.mc_question_state,'returned'::public.mc_question_state,'rejected'::public.mc_question_state,'disabled'::public.mc_question_state) then raise exception 'Invalid moderation decision'; end if;
 update public.mc_question_bank set state=p_decision,reviewed_by=v_uid,reviewed_at=now(),review_reason=nullif(trim(p_reason),'') where id=p_question_id;
 if not found then raise exception 'Question not found'; end if;
end;
$$;
revoke all on function public.mc_moderate_question(uuid,public.mc_question_state,text) from public,anon;
grant execute on function public.mc_moderate_question(uuid,public.mc_question_state,text) to authenticated;
commit;