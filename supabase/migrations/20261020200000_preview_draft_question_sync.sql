begin;
create or replace function public.mc_update_activity_draft_questions(p_activity_id uuid,p_question_ids uuid[])
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
 v_uid uuid := (select auth.uid());
 v_activity public.mc_activities%rowtype;
begin
 if v_uid is null then raise exception 'Authentication required' using errcode='28000'; end if;
 select * into v_activity from public.mc_activities where id=p_activity_id and owner_teacher_id=v_uid for update;
 if not found then raise exception 'Activity not found' using errcode='42501'; end if;
 if v_activity.state <> 'draft' then raise exception 'Only draft activities can be edited'; end if;
 if coalesce(array_length(p_question_ids,1),0)=0 then raise exception 'A draft must contain at least one question'; end if;
 if exists(select 1 from unnest(p_question_ids) q where not exists(select 1 from public.mc_question_bank b where b.id=q and b.state='approved')) then
   raise exception 'All questions must be approved';
 end if;
 if (select count(distinct q) from unnest(p_question_ids) q) <> array_length(p_question_ids,1) then
   raise exception 'Duplicate question selected';
 end if;
 delete from public.mc_activity_questions where activity_id=p_activity_id;
 if v_activity.randomize_questions then
   insert into public.mc_activity_questions(activity_id,question_id,display_order,max_points)
   select p_activity_id,x,row_number() over(order by random())::integer,b.points
   from unnest(p_question_ids) x join public.mc_question_bank b on b.id=x;
 else
   insert into public.mc_activity_questions(activity_id,question_id,display_order,max_points)
   select p_activity_id,x,ord::integer,b.points
   from unnest(p_question_ids) with ordinality ids(x,ord) join public.mc_question_bank b on b.id=x;
 end if;
 update public.mc_activities set updated_at=now() where id=p_activity_id;
end;
$$;
revoke all on function public.mc_update_activity_draft_questions(uuid,uuid[]) from public,anon;
grant execute on function public.mc_update_activity_draft_questions(uuid,uuid[]) to authenticated;
commit;
