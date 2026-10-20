begin;
create or replace function public.mc_exact_numeric_equal(p_left text,p_right text)
returns boolean language plpgsql immutable set search_path=''
as $$
declare l text:=trim(coalesce(p_left,'')); r text:=trim(coalesce(p_right,'')); ln numeric; ld numeric:=1; rn numeric; rd numeric:=1; dotpos integer;
begin
 if (l !~ '^[+-]?[0-9]+([.][0-9]+)?$' and l !~ '^[+-]?[0-9]+/[0-9]+$')
 or (r !~ '^[+-]?[0-9]+([.][0-9]+)?$' and r !~ '^[+-]?[0-9]+/[0-9]+$') then return false; end if;
 if position('/' in l)>0 then ln:=split_part(l,'/',1)::numeric; ld:=split_part(l,'/',2)::numeric; if ld=0 then return false; end if;
 else ln:=l::numeric; dotpos:=position('.' in l); if dotpos>0 then ld:=power(10,length(l)-dotpos); ln:=ln*ld; end if; end if;
 if position('/' in r)>0 then rn:=split_part(r,'/',1)::numeric; rd:=split_part(r,'/',2)::numeric; if rd=0 then return false; end if;
 else rn:=r::numeric; dotpos:=position('.' in r); if dotpos>0 then rd:=power(10,length(r)-dotpos); rn:=rn*rd; end if; end if;
 return ln*rd=rn*ld;
exception when others then return false;
end;
$$;
revoke all on function public.mc_exact_numeric_equal(text,text) from public,anon,authenticated;

create or replace function public.mc_grade_activity_attempt(p_attempt_id uuid,p_auto boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_att public.mc_activity_attempts%rowtype; v_a public.mc_activities%rowtype; q record; ans record;
 v_score integer:=0; v_max integer:=0; v_correct boolean; v_award integer; v_payload jsonb; v_expected jsonb;
 v_val numeric; v_expval numeric; v_unit text; v_expunit text; v_sel text[]; v_exp text[]; v_key text;
begin
 select * into v_att from public.mc_activity_attempts where id=p_attempt_id for update;
 if not found then raise exception 'Attempt not found'; end if;
 if v_att.state<>'active' then return jsonb_build_object('attempt_id',v_att.id,'state',v_att.state,'correct_points',v_att.correct_points,'max_points',v_att.max_points); end if;
 select * into v_a from public.mc_activities where id=v_att.activity_id;
 for q in select * from public.mc_activity_questions where activity_id=v_a.id order by display_order loop
  v_max:=v_max+q.max_points;
  if q.question_snapshot->>'kind'='MC' then
   select a.answer_payload into v_payload from public.mc_attempt_answers a where a.attempt_id=p_attempt_id and a.question_order=q.display_order and a.subpart_key='';
   v_expected:=q.answer_snapshot->'answer_payload'->'correct_options'; v_correct:=false;
   if v_payload is not null and jsonb_typeof(v_payload->'selected_options')='array' and jsonb_typeof(v_expected)='array' then
    select coalesce(array_agg(value order by value),'{}'::text[]) into v_sel from jsonb_array_elements_text(v_payload->'selected_options') vals(value);
    select coalesce(array_agg(value order by value),'{}'::text[]) into v_exp from jsonb_array_elements_text(v_expected) vals(value);
    v_correct:=v_sel=v_exp;
   end if;
   v_award:=case when v_correct then q.max_points else 0 end; v_score:=v_score+v_award;
   update public.mc_attempt_answers set is_correct=v_correct,awarded_points=v_award where attempt_id=p_attempt_id and question_order=q.display_order and subpart_key='';
  else
   for ans in select value from jsonb_array_elements(q.question_snapshot->'subparts') parts(value) loop
    v_key:=ans.value->>'key'; v_payload:=null;
    select a.answer_payload into v_payload from public.mc_attempt_answers a where a.attempt_id=p_attempt_id and a.question_order=q.display_order and a.subpart_key=v_key;
    v_expected:=q.answer_snapshot->'answer_payload'->'parts'->v_key;
    v_val:=public.mc_parse_exact_number(v_payload->>'value'); v_expval:=public.mc_parse_exact_number(v_expected->>'value');
    v_unit:=coalesce(v_payload->>'unit',''); v_expunit:=coalesce(v_expected->>'unit','');
    v_correct:=public.mc_exact_numeric_equal(v_payload->>'value',v_expected->>'value') and (not coalesce((ans.value->>'unit_required')::boolean,false) or v_unit=v_expunit);
    v_award:=case when v_correct then coalesce((ans.value->>'points')::integer,0) else 0 end; v_score:=v_score+v_award;
    update public.mc_attempt_answers set is_correct=v_correct,awarded_points=v_award where attempt_id=p_attempt_id and question_order=q.display_order and subpart_key=v_key;
   end loop;
  end if;
 end loop;
 update public.mc_activity_attempts set state=case when p_auto then 'auto_submitted'::public.mc_attempt_state else 'submitted'::public.mc_attempt_state end,
 submitted_at=now(),is_auto_submitted=p_auto,correct_points=v_score,max_points=v_max where id=p_attempt_id;
 return jsonb_build_object('attempt_id',p_attempt_id,'correct_points',v_score,'max_points',v_max,'state',case when p_auto then 'auto_submitted' else 'submitted' end);
end;
$$;
commit;