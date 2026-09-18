-- =====================================================================
-- Фактические расходы по месяцам (раздел «Расходы»)
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить всё → Run.
-- Скрипт добавляет таблицы actual_expenses и goal_settings (копилка или подушка, темп подушки)
-- и обновляет функции get_debts_state / save_debts_state: теперь они возвращают и сохраняют
-- ключи actuals и goalSettings (вместе с workingDays из calendar_update.sql).
-- Таблицы и функции основного плана (get_full_state / save_full_state) не меняются.
-- =====================================================================

-- ---------- таблица ----------
-- ym          — месяц в виде 'ГГГГ-ММ'
-- category_id — id категории из плана
-- item_name   — название статьи внутри категории; пустая строка = сумма по категории целиком
-- category_name — название категории на момент ввода: нужно, чтобы история не потерялась,
--                 если категорию позже удалят из плана
create table if not exists public.actual_expenses (
  user_id     uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  ym          text    not null check (ym ~ '^[0-9]{4}-[0-9]{2}$'),
  category_id text    not null,
  item_name     text    not null default '',
  amount        numeric not null default 0,
  category_name text    not null default '',
  primary key (user_id, ym, category_id, item_name)
);

-- если таблица уже была создана прошлой версией скрипта
alter table public.actual_expenses add column if not exists category_name text not null default '';

alter table public.actual_expenses enable row level security;

drop policy if exists own_rows on public.actual_expenses;
create policy own_rows on public.actual_expenses
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.actual_expenses to authenticated;


-- =====================================================================
-- Тип цели: копилка или подушка, и темп подушки (сумма в выплату)
-- =====================================================================
create table if not exists public.goal_settings (
  user_id uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  goal_id text    not null,
  kind    text    not null default 'bucket' check (kind in ('bucket', 'reserve')),
  pace    numeric not null default 0,
  primary key (user_id, goal_id)
);

alter table public.goal_settings enable row level security;

drop policy if exists own_rows on public.goal_settings;
create policy own_rows on public.goal_settings
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.goal_settings to authenticated;

-- ---------- чтение ----------
create or replace function public.get_debts_state()
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'name', c.name,
               'limit', c.credit_limit,
               'graceDays', c.grace_days,
               'ops', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', o.id, 'date', o.op_date, 'amount', o.amount,
                          'kind', o.kind, 'note', o.note)
                        order by o.sort_order)
                 from credit_card_ops o
                 where o.user_id = c.user_id and o.card_id = c.id), '[]'::jsonb)
             ) order by c.sort_order)
      from credit_cards c
      where c.user_id = auth.uid()), '[]'::jsonb),
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id,
               'name', i.name,
               'total', i.total,
               'parts', i.parts,
               'interval', i.pay_interval,
               'firstDate', i.first_date,
               'payments', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', p.id, 'date', p.pay_date, 'amount', p.amount)
                        order by p.sort_order)
                 from installment_payments p
                 where p.user_id = i.user_id and p.installment_id = i.id), '[]'::jsonb)
             ) order by i.sort_order)
      from installments i
      where i.user_id = auth.uid()), '[]'::jsonb),
    'paymentOverrides', coalesce((
      select jsonb_object_agg(t.period_id, t.cards)
      from (
        select period_id, jsonb_object_agg(card_id, amount) as cards
        from credit_card_payment_overrides
        where user_id = auth.uid()
        group by period_id
      ) t), '{}'::jsonb),
    'workingDays', coalesce((
      select jsonb_object_agg(w.ym,
               jsonb_strip_nulls(jsonb_build_object('first', w.first_half, 'second', w.second_half)))
      from working_day_overrides w
      where w.user_id = auth.uid()), '{}'::jsonb),
    'goalSettings', coalesce((
      select jsonb_object_agg(gs.goal_id, jsonb_build_object('kind', gs.kind, 'pace', gs.pace))
      from goal_settings gs
      where gs.user_id = auth.uid()), '{}'::jsonb),
    'actuals', coalesce((
      select jsonb_object_agg(t.ym, t.cats)
      from (
        select ym, jsonb_object_agg(category_id, cat) as cats
        from (
          select ym,
                 category_id,
                 jsonb_strip_nulls(jsonb_build_object(
                   'name', max(nullif(category_name, '')),
                   'total', max(case when item_name = '' then amount end),
                   'items', nullif(coalesce(
                     jsonb_object_agg(item_name, amount) filter (where item_name <> ''),
                     '{}'::jsonb), '{}'::jsonb)
                 )) as cat
          from actual_expenses
          where user_id = auth.uid()
          group by ym, category_id
        ) c
        group by ym
      ) t), '{}'::jsonb)
  );
$$;

-- ---------- сохранение ----------
create or replace function public.save_debts_state(p_state jsonb)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Нужно войти в приложение';
  end if;

  -- операции, платежи и ручные погашения удаляются каскадом
  delete from credit_cards where user_id = v_uid;
  delete from installments where user_id = v_uid;
  delete from working_day_overrides where user_id = v_uid;
  delete from actual_expenses where user_id = v_uid;
  delete from goal_settings where user_id = v_uid;

  insert into credit_cards (user_id, id, name, credit_limit, grace_days, sort_order)
  select v_uid,
         c.value->>'id',
         coalesce(c.value->>'name', ''),
         coalesce(nullif(c.value->>'limit', '')::numeric, 0),
         coalesce(nullif(c.value->>'graceDays', '')::integer, 60),
         c.ord
  from jsonb_array_elements(coalesce(p_state->'cards', '[]'::jsonb)) with ordinality as c(value, ord);

  insert into credit_card_ops (user_id, id, card_id, op_date, amount, kind, note, sort_order)
  select v_uid,
         coalesce(o.value->>'id', gen_random_uuid()::text),
         c.value->>'id',
         nullif(o.value->>'date', '')::date,
         coalesce(nullif(o.value->>'amount', '')::numeric, 0),
         case when o.value->>'kind' = 'payment' then 'payment' else 'spend' end,
         coalesce(o.value->>'note', ''),
         o.ord
  from jsonb_array_elements(coalesce(p_state->'cards', '[]'::jsonb)) as c(value)
  cross join lateral jsonb_array_elements(coalesce(c.value->'ops', '[]'::jsonb)) with ordinality as o(value, ord);

  insert into credit_card_payment_overrides (user_id, period_id, card_id, amount)
  select v_uid, po.key, co.key, coalesce(nullif(co.value #>> '{}', '')::numeric, 0)
  from jsonb_each(coalesce(p_state->'paymentOverrides', '{}'::jsonb)) as po
  cross join lateral jsonb_each(po.value) as co
  where exists (select 1 from credit_cards cc where cc.user_id = v_uid and cc.id = co.key);

  insert into installments (user_id, id, name, total, parts, pay_interval, first_date, sort_order)
  select v_uid,
         i.value->>'id',
         coalesce(i.value->>'name', ''),
         coalesce(nullif(i.value->>'total', '')::numeric, 0),
         greatest(1, coalesce(nullif(i.value->>'parts', '')::integer, 1)),
         case when i.value->>'interval' = '1m' then '1m' else '2w' end,
         nullif(i.value->>'firstDate', '')::date,
         i.ord
  from jsonb_array_elements(coalesce(p_state->'installments', '[]'::jsonb)) with ordinality as i(value, ord);

  insert into installment_payments (user_id, id, installment_id, pay_date, amount, sort_order)
  select v_uid,
         coalesce(p.value->>'id', gen_random_uuid()::text),
         i.value->>'id',
         nullif(p.value->>'date', '')::date,
         coalesce(nullif(p.value->>'amount', '')::numeric, 0),
         p.ord
  from jsonb_array_elements(coalesce(p_state->'installments', '[]'::jsonb)) as i(value)
  cross join lateral jsonb_array_elements(coalesce(i.value->'payments', '[]'::jsonb)) with ordinality as p(value, ord);

  insert into working_day_overrides (user_id, ym, first_half, second_half)
  select v_uid,
         w.key,
         nullif(w.value->>'first', '')::integer,
         nullif(w.value->>'second', '')::integer
  from jsonb_each(coalesce(p_state->'workingDays', '{}'::jsonb)) as w
  where w.key ~ '^[0-9]{4}-[0-9]{2}$'
    and (w.value->>'first' is not null or w.value->>'second' is not null);

  insert into goal_settings (user_id, goal_id, kind, pace)
  select v_uid,
         g.key,
         case when g.value->>'kind' = 'reserve' then 'reserve' else 'bucket' end,
         coalesce(nullif(g.value->>'pace', '')::numeric, 0)
  from jsonb_each(coalesce(p_state->'goalSettings', '{}'::jsonb)) as g;

  -- фактические расходы: сумма по категории целиком
  insert into actual_expenses (user_id, ym, category_id, item_name, amount, category_name)
  select v_uid, mm.key, cc.key, '', coalesce(nullif(cc.value->>'total', '')::numeric, 0),
         coalesce(cc.value->>'name', '')
  from jsonb_each(coalesce(p_state->'actuals', '{}'::jsonb)) as mm
  cross join lateral jsonb_each(mm.value) as cc
  where mm.key ~ '^[0-9]{4}-[0-9]{2}$'
    and cc.value->>'total' is not null;

  -- фактические расходы: суммы по статьям внутри категории
  insert into actual_expenses (user_id, ym, category_id, item_name, amount, category_name)
  select v_uid, mm.key, cc.key, ii.key, coalesce(nullif(ii.value #>> '{}', '')::numeric, 0),
         coalesce(cc.value->>'name', '')
  from jsonb_each(coalesce(p_state->'actuals', '{}'::jsonb)) as mm
  cross join lateral jsonb_each(mm.value) as cc
  cross join lateral jsonb_each(coalesce(cc.value->'items', '{}'::jsonb)) as ii
  where mm.key ~ '^[0-9]{4}-[0-9]{2}$'
    and ii.key <> '';
end;
$$;

grant execute on function public.get_debts_state() to authenticated;
grant execute on function public.save_debts_state(jsonb) to authenticated;
