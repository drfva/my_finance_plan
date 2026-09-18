-- =====================================================================
-- Кредитки и рассрочки для приложения «Финансы»
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить всё → Run.
-- Существующие таблицы и функции (get_full_state / save_full_state) не меняются.
-- =====================================================================

-- ---------- таблицы ----------
create table if not exists public.credit_cards (
  user_id     uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  id          text    not null,
  name        text    not null default '',
  credit_limit numeric not null default 0,
  grace_days  integer not null default 60,
  sort_order  integer not null default 0,
  primary key (user_id, id)
);

create table if not exists public.credit_card_ops (
  user_id    uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  id         text    not null,
  card_id    text    not null,
  op_date    date,
  amount     numeric not null default 0,
  kind       text    not null default 'spend' check (kind in ('spend', 'payment')),
  note       text    not null default '',
  sort_order integer not null default 0,
  primary key (user_id, id),
  foreign key (user_id, card_id) references public.credit_cards(user_id, id) on delete cascade
);

-- ручные / зафиксированные суммы погашения кредитки в конкретной выплате
create table if not exists public.credit_card_payment_overrides (
  user_id   uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  period_id text    not null,
  card_id   text    not null,
  amount    numeric not null default 0,
  primary key (user_id, period_id, card_id),
  foreign key (user_id, card_id) references public.credit_cards(user_id, id) on delete cascade
);

create table if not exists public.installments (
  user_id    uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  id         text    not null,
  name       text    not null default '',
  total      numeric not null default 0,
  parts      integer not null default 1,
  pay_interval text  not null default '2w' check (pay_interval in ('2w', '1m')),
  first_date date,
  sort_order integer not null default 0,
  primary key (user_id, id)
);

create table if not exists public.installment_payments (
  user_id        uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  id             text    not null,
  installment_id text    not null,
  pay_date       date,
  amount         numeric not null default 0,
  sort_order     integer not null default 0,
  primary key (user_id, id),
  foreign key (user_id, installment_id) references public.installments(user_id, id) on delete cascade
);

-- ---------- доступ: каждый видит только свои строки ----------
alter table public.credit_cards                  enable row level security;
alter table public.credit_card_ops               enable row level security;
alter table public.credit_card_payment_overrides enable row level security;
alter table public.installments                  enable row level security;
alter table public.installment_payments          enable row level security;

drop policy if exists own_rows on public.credit_cards;
create policy own_rows on public.credit_cards
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists own_rows on public.credit_card_ops;
create policy own_rows on public.credit_card_ops
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists own_rows on public.credit_card_payment_overrides;
create policy own_rows on public.credit_card_payment_overrides
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists own_rows on public.installments;
create policy own_rows on public.installments
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists own_rows on public.installment_payments;
create policy own_rows on public.installment_payments
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on
  public.credit_cards, public.credit_card_ops, public.credit_card_payment_overrides,
  public.installments, public.installment_payments
to authenticated;

-- ---------- чтение всего блока долгов одним JSON ----------
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
      ) t), '{}'::jsonb)
  );
$$;

-- ---------- сохранение: полностью заменяет долги текущего пользователя ----------
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
end;
$$;

grant execute on function public.get_debts_state() to authenticated;
grant execute on function public.save_debts_state(jsonb) to authenticated;
