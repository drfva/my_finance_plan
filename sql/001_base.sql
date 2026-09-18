-- =====================================================================
-- 001_base.sql — основа плана: таблицы, права и функции get_full_state / save_full_state
-- Выполнять первым на чистом проекте Supabase (SQL Editor → New query → Run).
-- Скрипт идемпотентный: повторный запуск ничего не ломает.
--
-- ВАЖНО: в боевом проекте функции уже есть. Этот файл создаёт их заново в том виде,
-- в каком их ждёт приложение. Перед запуском на боевом проекте сохраните текущие версии:
--   select pg_get_functiondef(p.oid) from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname in ('get_full_state','save_full_state');
-- =====================================================================

-- ---------------------------------------------------------------- таблицы
create table if not exists public.oklad_history (
  id             uuid    not null default gen_random_uuid(),
  user_id        uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  effective_from date    not null,
  amount         numeric not null,
  primary key (id)
);

create table if not exists public.ndfl_brackets (
  id         uuid    not null default gen_random_uuid(),
  user_id    uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  sort_order integer not null,
  up_to      numeric,
  rate       numeric not null,
  primary key (id)
);

create table if not exists public.income_history (
  id      uuid    not null default gen_random_uuid(),
  user_id uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  year    integer not null,
  month   integer not null check (month >= 1 and month <= 12),
  amount  numeric not null,
  primary key (id)
);

create table if not exists public.sick_leaves (
  id         text not null,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  start_date date,
  end_date   date,
  note       text,
  primary key (id)
);

create table if not exists public.vacations (
  id         text    not null,
  user_id    uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  start_date date    not null,
  end_date   date    not null,
  note       text,
  manual_pay numeric not null default 0,
  primary key (id)
);

create table if not exists public.categories (
  id             text    not null,
  user_id        uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  name           text    not null,
  planned_amount numeric not null default 0,
  sort_order     integer not null default 0,
  primary key (id)
);
-- сезонность категории целиком (например, горные лыжи 01.12–20.03)
alter table public.categories add column if not exists season_from text;
alter table public.categories add column if not exists season_to   text;

create table if not exists public.category_items (
  id          uuid    not null default gen_random_uuid(),
  category_id text    not null references public.categories(id) on delete cascade,
  user_id     uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  name        text    not null,
  amount      numeric not null default 0,
  season_from text,
  season_to   text,
  sort_order  integer not null default 0,
  primary key (id)
);

create table if not exists public.goals (
  id               text    not null,
  user_id          uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  name             text    not null,
  priority         integer not null,
  target           numeric not null,
  deadline         date,
  starting_balance numeric not null default 0,
  completed        boolean not null default false,
  primary key (id)
);

create table if not exists public.goal_subgoals (
  id       text    not null,
  goal_id  text    not null references public.goals(id) on delete cascade,
  user_id  uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  name     text    not null,
  target   numeric not null,
  deadline date,
  primary key (id)
);

create table if not exists public.goal_withdrawals (
  id      uuid    not null default gen_random_uuid(),
  goal_id text    not null references public.goals(id) on delete cascade,
  user_id uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  date    date    not null,
  amount  numeric not null,
  note    text,
  primary key (id)
);

create table if not exists public.periods (
  id              text    not null,
  user_id         uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  date            date    not null,
  label           text,
  type            text    not null check (type in ('zp', 'avans')),
  half            text    not null check (half in ('first', 'second')),
  month_ref_year  integer not null,
  month_ref_month integer not null,
  calc            text    not null check (calc in ('auto', 'manual')),
  income_actual   numeric not null default 0,
  note            text,
  locked          boolean not null default false,
  primary key (id)
);

create table if not exists public.period_assigned_vacations (
  period_id   text    not null references public.periods(id) on delete cascade,
  vacation_id text    not null,
  user_id     uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  share       numeric not null default 1,
  primary key (period_id, vacation_id)
);

-- таблица осталась от разового дохода; приложение её больше не использует
create table if not exists public.period_extra_incomes (
  id           text    not null,
  period_id    text    not null references public.periods(id) on delete cascade,
  user_id      uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  amount       numeric not null default 0,
  note         text,
  expenses_pct numeric,
  primary key (id)
);

create table if not exists public.category_overrides (
  period_id   text    not null references public.periods(id) on delete cascade,
  category_id text    not null,
  user_id     uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  amount      numeric not null,
  primary key (period_id, category_id)
);

create table if not exists public.savings_overrides (
  period_id text    not null references public.periods(id) on delete cascade,
  goal_id   text    not null,
  user_id   uuid    not null default auth.uid() references auth.users(id) on delete cascade,
  amount    numeric not null,
  primary key (period_id, goal_id)
);

create table if not exists public.holidays (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date    date not null,
  primary key (user_id, date)
);

-- ---------------------------------------------------------------- права
do $$
declare t text;
begin
  foreach t in array array[
    'oklad_history','ndfl_brackets','income_history','sick_leaves','vacations',
    'categories','category_items','goals','goal_subgoals','goal_withdrawals',
    'periods','period_assigned_vacations','period_extra_incomes',
    'category_overrides','savings_overrides','holidays'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists owner_all on public.%I', t);
    execute format(
      'create policy owner_all on public.%I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- чтение
create or replace function public.get_full_state()
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_res jsonb;
begin
  if v_uid is null then
    return null;
  end if;
  -- у нового пользователя плана ещё нет: приложение подставит свой стартовый шаблон
  if not exists (select 1 from periods where user_id = v_uid)
     and not exists (select 1 from categories where user_id = v_uid)
     and not exists (select 1 from goals where user_id = v_uid) then
    return null;
  end if;

  select jsonb_build_object(
    'oklad', jsonb_build_object('history', coalesce((
      select jsonb_agg(jsonb_build_object('effectiveFrom', o.effective_from, 'amount', o.amount)
             order by o.effective_from)
      from oklad_history o where o.user_id = v_uid), '[]'::jsonb)),

    'ndfl', jsonb_build_object('brackets', coalesce((
      select jsonb_agg(jsonb_build_object('upTo', b.up_to, 'rate', b.rate) order by b.sort_order)
      from ndfl_brackets b where b.user_id = v_uid), '[]'::jsonb)),

    'income2026', coalesce((
      select jsonb_agg(coalesce(h.amount, 0) order by m.month)
      from generate_series(1, 12) as m(month)
      left join income_history h
        on h.user_id = v_uid and h.year = 2026 and h.month = m.month), '[]'::jsonb),

    'sickLeaves', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'start', s.start_date, 'end', s.end_date,
                                          'note', coalesce(s.note, '')) order by s.start_date nulls last, s.id)
      from sick_leaves s where s.user_id = v_uid), '[]'::jsonb),

    'vacations', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'start', v.start_date, 'end', v.end_date,
                                          'note', coalesce(v.note, ''), 'manualPay', v.manual_pay)
             order by v.start_date, v.id)
      from vacations v where v.user_id = v_uid), '[]'::jsonb),

    'categories', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'id', c.id,
               'name', c.name,
               'amount', c.planned_amount,
               'season', case when c.season_from is not null and c.season_to is not null
                              then jsonb_build_object('from', c.season_from, 'to', c.season_to) end,
               'items', coalesce((
                 select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                          'name', i.name,
                          'amount', i.amount,
                          'season', case when i.season_from is not null and i.season_to is not null
                                         then jsonb_build_object('from', i.season_from, 'to', i.season_to) end))
                        order by i.sort_order)
                 from category_items i
                 where i.user_id = c.user_id and i.category_id = c.id), '[]'::jsonb)
             )) order by c.sort_order)
      from categories c where c.user_id = v_uid), '[]'::jsonb),

    'goals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', g.id,
               'name', g.name,
               'priority', g.priority,
               'target', g.target,
               'deadline', coalesce(g.deadline::text, ''),
               'startingBalance', g.starting_balance,
               'completed', g.completed,
               'subgoals', coalesce((
                 select jsonb_agg(jsonb_build_object('id', sg.id, 'name', sg.name, 'target', sg.target,
                                                     'deadline', coalesce(sg.deadline::text, ''))
                        order by sg.deadline nulls last, sg.id)
                 from goal_subgoals sg
                 where sg.user_id = g.user_id and sg.goal_id = g.id), '[]'::jsonb),
               'withdrawals', coalesce((
                 select jsonb_agg(jsonb_build_object('date', w.date, 'amount', w.amount,
                                                     'note', coalesce(w.note, ''), 'label', coalesce(w.note, ''))
                        order by w.date, w.id)
                 from goal_withdrawals w
                 where w.user_id = g.user_id and w.goal_id = g.id), '[]'::jsonb)
             ) order by g.priority)
      from goals g where g.user_id = v_uid), '[]'::jsonb),

    'periods', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'date', p.date,
               'label', coalesce(p.label, ''),
               'type', p.type,
               'half', p.half,
               'monthRef', jsonb_build_object('y', p.month_ref_year, 'm', p.month_ref_month),
               'calc', p.calc,
               'incomeActual', p.income_actual,
               'note', coalesce(p.note, ''),
               'locked', p.locked,
               'assignedVacations', coalesce((
                 select jsonb_agg(jsonb_build_object('id', av.vacation_id, 'share', av.share))
                 from period_assigned_vacations av
                 where av.user_id = p.user_id and av.period_id = p.id), '[]'::jsonb)
             ) order by p.date)
      from periods p where p.user_id = v_uid), '[]'::jsonb),

    'categoryOverrides', coalesce((
      select jsonb_object_agg(t.period_id, t.cats)
      from (select co.period_id, jsonb_object_agg(co.category_id, co.amount) as cats
            from category_overrides co where co.user_id = v_uid
            group by co.period_id) t), '{}'::jsonb),

    'savingsOverrides', coalesce((
      select jsonb_object_agg(t.period_id, t.goals)
      from (select so.period_id, jsonb_object_agg(so.goal_id, so.amount) as goals
            from savings_overrides so where so.user_id = v_uid
            group by so.period_id) t), '{}'::jsonb),

    'meta', jsonb_build_object('holidays', coalesce((
      select jsonb_agg(h.date order by h.date)
      from holidays h where h.user_id = v_uid), '[]'::jsonb))
  ) into v_res;

  return v_res;
end;
$$;

-- ---------------------------------------------------------------- сохранение
-- Полностью заменяет план текущего пользователя данными из JSON.
create or replace function public.save_full_state(p_state jsonb)
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
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'Ожидался объект состояния';
  end if;

  -- порядок удаления важен из-за внешних ключей
  delete from period_assigned_vacations where user_id = v_uid;
  delete from period_extra_incomes      where user_id = v_uid;
  delete from category_overrides        where user_id = v_uid;
  delete from savings_overrides         where user_id = v_uid;
  delete from goal_subgoals             where user_id = v_uid;
  delete from goal_withdrawals          where user_id = v_uid;
  delete from category_items            where user_id = v_uid;
  delete from periods                   where user_id = v_uid;
  delete from goals                     where user_id = v_uid;
  delete from categories                where user_id = v_uid;
  delete from vacations                 where user_id = v_uid;
  delete from sick_leaves               where user_id = v_uid;
  delete from oklad_history             where user_id = v_uid;
  delete from ndfl_brackets             where user_id = v_uid;
  delete from income_history            where user_id = v_uid;
  delete from holidays                  where user_id = v_uid;

  -- оклад
  insert into oklad_history (user_id, effective_from, amount)
  select v_uid, (x.value->>'effectiveFrom')::date, coalesce(nullif(x.value->>'amount', '')::numeric, 0)
  from jsonb_array_elements(coalesce(p_state#>'{oklad,history}', '[]'::jsonb)) as x(value)
  where nullif(x.value->>'effectiveFrom', '') is not null;

  -- шкала НДФЛ
  insert into ndfl_brackets (user_id, sort_order, up_to, rate)
  select v_uid, x.ord, nullif(x.value->>'upTo', '')::numeric, coalesce(nullif(x.value->>'rate', '')::numeric, 0)
  from jsonb_array_elements(coalesce(p_state#>'{ndfl,brackets}', '[]'::jsonb)) with ordinality as x(value, ord);

  -- доходы за 2026 год
  insert into income_history (user_id, year, month, amount)
  select v_uid, 2026, x.ord, coalesce(nullif(x.value #>> '{}', '')::numeric, 0)
  from jsonb_array_elements(coalesce(p_state->'income2026', '[]'::jsonb)) with ordinality as x(value, ord)
  where x.ord between 1 and 12;

  -- больничные
  insert into sick_leaves (user_id, id, start_date, end_date, note)
  select v_uid, coalesce(nullif(x.value->>'id', ''), gen_random_uuid()::text),
         nullif(x.value->>'start', '')::date, nullif(x.value->>'end', '')::date,
         coalesce(x.value->>'note', '')
  from jsonb_array_elements(coalesce(p_state->'sickLeaves', '[]'::jsonb)) as x(value);

  -- отпуска
  insert into vacations (user_id, id, start_date, end_date, note, manual_pay)
  select v_uid, coalesce(nullif(x.value->>'id', ''), gen_random_uuid()::text),
         (x.value->>'start')::date, (x.value->>'end')::date,
         coalesce(x.value->>'note', ''), coalesce(nullif(x.value->>'manualPay', '')::numeric, 0)
  from jsonb_array_elements(coalesce(p_state->'vacations', '[]'::jsonb)) as x(value)
  where nullif(x.value->>'start', '') is not null and nullif(x.value->>'end', '') is not null;

  -- категории и статьи
  insert into categories (user_id, id, name, planned_amount, sort_order, season_from, season_to)
  select v_uid, x.value->>'id', coalesce(x.value->>'name', ''),
         coalesce(nullif(x.value->>'amount', '')::numeric, 0), x.ord,
         nullif(x.value#>>'{season,from}', ''), nullif(x.value#>>'{season,to}', '')
  from jsonb_array_elements(coalesce(p_state->'categories', '[]'::jsonb)) with ordinality as x(value, ord)
  where nullif(x.value->>'id', '') is not null;

  insert into category_items (user_id, category_id, name, amount, season_from, season_to, sort_order)
  select v_uid, c.value->>'id', coalesce(i.value->>'name', ''),
         coalesce(nullif(i.value->>'amount', '')::numeric, 0),
         nullif(i.value#>>'{season,from}', ''), nullif(i.value#>>'{season,to}', ''), i.ord
  from jsonb_array_elements(coalesce(p_state->'categories', '[]'::jsonb)) as c(value)
  cross join lateral jsonb_array_elements(coalesce(c.value->'items', '[]'::jsonb)) with ordinality as i(value, ord)
  where nullif(c.value->>'id', '') is not null;

  -- цели, этапы и траты
  insert into goals (user_id, id, name, priority, target, deadline, starting_balance, completed)
  select v_uid, x.value->>'id', coalesce(x.value->>'name', ''),
         coalesce(nullif(x.value->>'priority', '')::integer, x.ord::integer),
         coalesce(nullif(x.value->>'target', '')::numeric, 0),
         nullif(x.value->>'deadline', '')::date,
         coalesce(nullif(x.value->>'startingBalance', '')::numeric, 0),
         coalesce((x.value->>'completed')::boolean, false)
  from jsonb_array_elements(coalesce(p_state->'goals', '[]'::jsonb)) with ordinality as x(value, ord)
  where nullif(x.value->>'id', '') is not null;

  insert into goal_subgoals (user_id, id, goal_id, name, target, deadline)
  select v_uid, coalesce(nullif(sg.value->>'id', ''), gen_random_uuid()::text), g.value->>'id',
         coalesce(sg.value->>'name', ''), coalesce(nullif(sg.value->>'target', '')::numeric, 0),
         nullif(sg.value->>'deadline', '')::date
  from jsonb_array_elements(coalesce(p_state->'goals', '[]'::jsonb)) as g(value)
  cross join lateral jsonb_array_elements(coalesce(g.value->'subgoals', '[]'::jsonb)) as sg(value)
  where nullif(g.value->>'id', '') is not null;

  insert into goal_withdrawals (user_id, goal_id, date, amount, note)
  select v_uid, g.value->>'id', (w.value->>'date')::date,
         coalesce(nullif(w.value->>'amount', '')::numeric, 0),
         coalesce(nullif(w.value->>'note', ''), w.value->>'label', '')
  from jsonb_array_elements(coalesce(p_state->'goals', '[]'::jsonb)) as g(value)
  cross join lateral jsonb_array_elements(coalesce(g.value->'withdrawals', '[]'::jsonb)) as w(value)
  where nullif(g.value->>'id', '') is not null and nullif(w.value->>'date', '') is not null;

  -- выплаты
  insert into periods (user_id, id, date, label, type, half, month_ref_year, month_ref_month,
                       calc, income_actual, note, locked)
  select v_uid, x.value->>'id', (x.value->>'date')::date, coalesce(x.value->>'label', ''),
         case when x.value->>'type' = 'zp' then 'zp' else 'avans' end,
         case when x.value->>'half' = 'second' then 'second' else 'first' end,
         coalesce(nullif(x.value#>>'{monthRef,y}', '')::integer, extract(year from (x.value->>'date')::date)::integer),
         coalesce(nullif(x.value#>>'{monthRef,m}', '')::integer, extract(month from (x.value->>'date')::date)::integer),
         case when x.value->>'calc' = 'manual' then 'manual' else 'auto' end,
         coalesce(nullif(x.value->>'incomeActual', '')::numeric, 0),
         coalesce(x.value->>'note', ''),
         coalesce((x.value->>'locked')::boolean, false)
  from jsonb_array_elements(coalesce(p_state->'periods', '[]'::jsonb)) as x(value)
  where nullif(x.value->>'id', '') is not null and nullif(x.value->>'date', '') is not null;

  insert into period_assigned_vacations (user_id, period_id, vacation_id, share)
  select v_uid, p.value->>'id', av.value->>'id', coalesce(nullif(av.value->>'share', '')::numeric, 1)
  from jsonb_array_elements(coalesce(p_state->'periods', '[]'::jsonb)) as p(value)
  cross join lateral jsonb_array_elements(coalesce(p.value->'assignedVacations', '[]'::jsonb)) as av(value)
  where nullif(av.value->>'id', '') is not null
    and exists (select 1 from vacations v where v.user_id = v_uid and v.id = av.value->>'id')
    and exists (select 1 from periods pp where pp.user_id = v_uid and pp.id = p.value->>'id');

  -- ручные правки расходов и сумм в копилки
  insert into category_overrides (user_id, period_id, category_id, amount)
  select v_uid, po.key, co.key, coalesce(nullif(co.value #>> '{}', '')::numeric, 0)
  from jsonb_each(coalesce(p_state->'categoryOverrides', '{}'::jsonb)) as po
  cross join lateral jsonb_each(po.value) as co
  where exists (select 1 from periods p where p.user_id = v_uid and p.id = po.key)
    and exists (select 1 from categories c where c.user_id = v_uid and c.id = co.key);

  insert into savings_overrides (user_id, period_id, goal_id, amount)
  select v_uid, po.key, so.key, coalesce(nullif(so.value #>> '{}', '')::numeric, 0)
  from jsonb_each(coalesce(p_state->'savingsOverrides', '{}'::jsonb)) as po
  cross join lateral jsonb_each(po.value) as so
  where exists (select 1 from periods p where p.user_id = v_uid and p.id = po.key)
    and exists (select 1 from goals g where g.user_id = v_uid and g.id = so.key);

  -- производственный календарь: дополнительные нерабочие даты
  insert into holidays (user_id, date)
  select distinct v_uid, (x.value #>> '{}')::date
  from jsonb_array_elements(coalesce(p_state#>'{meta,holidays}', '[]'::jsonb)) as x(value)
  where nullif(x.value #>> '{}', '') is not null;
end;
$$;

grant execute on function public.get_full_state() to authenticated;
grant execute on function public.save_full_state(jsonb) to authenticated;
