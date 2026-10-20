begin;
create or replace function public.mc_validate_question_record()
returns trigger language plpgsql set search_path=''
as $$
declare v_count integer; v_sum integer;
begin
 if new.kind='MC'::public.mc_question_kind then
  if jsonb_typeof(new.choices)<>'array' or jsonb_array_length(new.choices)<2 then raise exception 'MC questions need at least two choices'; end if;
  if exists(select 1 from jsonb_array_elements(new.choices) c(value)
    where nullif(trim(coalesce(c.value->>'key','')),'') is null
       or jsonb_typeof(c.value->'text') is distinct from 'object'
       or nullif(trim(coalesce(c.value->'text'->>'en','')),'') is null
       or nullif(trim(coalesce(c.value->'text'->>'zh','')),'') is null) then
   raise exception 'Each MC choice requires a key and bilingual text';
  end if;
  if (select count(*) from jsonb_array_elements(new.choices))<>(select count(distinct c.value->>'key') from jsonb_array_elements(new.choices) c(value)) then raise exception 'MC choice keys must be unique'; end if;
 else
  if jsonb_typeof(new.subparts)<>'array' or jsonb_array_length(new.subparts)=0 then raise exception 'SQ needs at least one subpart'; end if;
  if exists(select 1 from jsonb_array_elements(new.subparts) p(value)
   where nullif(trim(coalesce(p.value->>'key','')),'') is null
    or jsonb_typeof(p.value->'prompt') is distinct from 'object'
    or nullif(trim(coalesce(p.value->'prompt'->>'en','')),'') is null
    or nullif(trim(coalesce(p.value->'prompt'->>'zh','')),'') is null
    or coalesce((p.value->>'points')::integer,0)<1
    or jsonb_typeof(p.value->'unit_required') is distinct from 'boolean') then
   raise exception 'Each SQ subpart requires a key, bilingual prompt, positive integer points and unit_required boolean';
  end if;
  if (select count(*) from jsonb_array_elements(new.subparts))<>(select count(distinct p.value->>'key') from jsonb_array_elements(new.subparts) p(value)) then raise exception 'SQ subpart keys must be unique'; end if;
  select coalesce(sum((p.value->>'points')::integer),0) into v_sum from jsonb_array_elements(new.subparts) p(value);
  if v_sum<>new.points then raise exception 'Question points must equal the sum of SQ subpart points'; end if;
 end if;
 return new;
end;
$$;
create trigger mc_validate_question_record_before_write
before insert or update of kind,choices,subparts,points on public.mc_question_bank
for each row execute function public.mc_validate_question_record();
revoke all on function public.mc_validate_question_record() from public,anon,authenticated;

create or replace function public.mc_validate_question_answer_key()
returns trigger language plpgsql set search_path=''
as $$
declare v_q public.mc_question_bank%rowtype; v_correct jsonb; v_key text; v_part jsonb; v_num numeric;
begin
 select * into v_q from public.mc_question_bank where id=new.question_id;
 if not found then raise exception 'Question not found'; end if;
 if jsonb_typeof(new.answer_payload) is distinct from 'object' or new.answer_payload='{}'::jsonb then raise exception 'Answer payload must be a non-empty object'; end if;
 if jsonb_typeof(new.explanation) is distinct from 'object' then raise exception 'Explanation must be a JSON object'; end if;
 if v_q.kind='MC'::public.mc_question_kind then
  v_correct:=new.answer_payload->'correct_options';
  if jsonb_typeof(v_correct) is distinct from 'array' or jsonb_array_length(v_correct)=0 then raise exception 'MC answer must contain correct_options'; end if;
  if exists(select 1 from jsonb_array_elements_text(v_correct) c(value)
   where not exists(select 1 from jsonb_array_elements(v_q.choices) q(value) where q.value->>'key'=c.value)) then raise exception 'Correct option must match a choice key'; end if;
  if (select count(*) from jsonb_array_elements_text(v_correct))<>(select count(distinct c.value) from jsonb_array_elements_text(v_correct) c(value)) then raise exception 'Correct option keys must be unique'; end if;
 else
  if jsonb_typeof(new.answer_payload->'parts') is distinct from 'object' then raise exception 'SQ answer payload must contain parts object'; end if;
  if (select count(*) from jsonb_object_keys(new.answer_payload->'parts'))<>(select count(*) from jsonb_array_elements(v_q.subparts)) then raise exception 'SQ answer keys must match subparts'; end if;
  for v_part in select value from jsonb_array_elements(v_q.subparts) loop
   v_key:=v_part->>'key';
   if not (new.answer_payload->'parts' ? v_key) then raise exception 'Missing answer for SQ subpart %',v_key; end if;
   if jsonb_typeof(new.answer_payload->'parts'->v_key) is distinct from 'object' then raise exception 'SQ subpart answer must be an object'; end if;
   if coalesce(new.answer_payload->'parts'->v_key->>'value','') !~ '^[+-]?[0-9]+([.][0-9]+)?$|^[+-]?[0-9]+/[0-9]+$' then raise exception 'SQ answer must use a supported exact decimal or fraction'; end if;
   if position('/' in (new.answer_payload->'parts'->v_key->>'value'))>0 and split_part(new.answer_payload->'parts'->v_key->>'value','/',2)::numeric=0 then raise exception 'SQ fraction denominator cannot be zero'; end if;
  end loop;
 end if;
 return new;
end;
$$;
create trigger mc_validate_question_answer_key_before_write
before insert or update of answer_payload,explanation on public.mc_question_answer_keys
for each row execute function public.mc_validate_question_answer_key();
revoke all on function public.mc_validate_question_answer_key() from public,anon,authenticated;
commit;