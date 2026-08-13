-- GZ Bedding database recovery. Run this file once after schema.sql stopped at submit_order.
-- This file deliberately uses small, independently valid statements.

create or replace function public.submit_order(
  in_customer_name text,
  in_phone text,
  in_building text,
  in_room text,
  in_note text,
  in_promotion_code text,
  in_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_order_id uuid;
  item jsonb;
begin
  if in_customer_name is null or length(trim(in_customer_name)) = 0 then
    raise exception 'Customer name is required';
  end if;
  if in_phone is null or length(trim(in_phone)) = 0 then
    raise exception 'Phone is required';
  end if;
  if in_building is null or length(trim(in_building)) = 0 then
    raise exception 'Building is required';
  end if;
  if in_room is null or length(trim(in_room)) = 0 then
    raise exception 'Room is required';
  end if;
  if in_items is null or jsonb_typeof(in_items) <> 'array' or jsonb_array_length(in_items) = 0 then
    raise exception 'At least one product is required';
  end if;

  insert into public.orders(customer_name, phone, building, room, note, promotion_code)
  values (
    trim(in_customer_name), trim(in_phone), trim(in_building), trim(in_room),
    nullif(trim(coalesce(in_note, '')), ''),
    nullif(trim(coalesce(in_promotion_code, '')), '')
  )
  returning id into new_order_id;

  for item in select value from jsonb_array_elements(in_items) as t(value) loop
    insert into public.order_items(order_id, product_id, quantity, style)
    values (
      new_order_id,
      item ->> 'product_id',
      greatest(1, coalesce((item ->> 'quantity')::integer, 1)),
      nullif(item ->> 'style', '')
    );
  end loop;

  return (
    select jsonb_build_object(
      'order_id', o.id,
      'customer_token', o.customer_token,
      'order_no', o.order_no,
      'deposit_total', o.deposit_total,
      'balance_due', o.balance_due
    )
    from public.orders as o
    where o.id = new_order_id
  );
end;
$fn$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  chosen_shareholder uuid;
begin
  insert into public.profiles(id, email, display_name, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    case when lower(coalesce(new.email, '')) = '309175115@qq.com'
      then 'admin'::public.profile_role
      else 'agent'::public.profile_role
    end
  ) on conflict (id) do nothing;

  if lower(coalesce(new.email, '')) <> '309175115@qq.com'
     and coalesce(new.raw_user_meta_data ->> 'application_type', '') = 'secondary_agent' then
    begin
      chosen_shareholder := (new.raw_user_meta_data ->> 'shareholder_id')::uuid;
    exception when invalid_text_representation then
      chosen_shareholder := null;
    end;
    if exists (select 1 from public.agents where id = chosen_shareholder and role = 'shareholder' and status = 'active') then
      insert into public.agents(user_id, name, phone, wechat, role, shareholder_id, status)
      values (
        new.id,
        coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), split_part(coalesce(new.email, ''), '@', 1)),
        nullif(trim(new.raw_user_meta_data ->> 'phone'), ''),
        nullif(trim(new.raw_user_meta_data ->> 'wechat'), ''),
        'secondary_agent', chosen_shareholder, 'pending'
      ) on conflict (user_id) do nothing;
    end if;
  end if;
  return new;
end;
$fn$;

create or replace function public.attach_receipt(in_order_id uuid, in_token uuid, in_path text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.orders
  set receipt_path = in_path, status = 'awaiting_receipt', updated_at = now()
  where id = in_order_id and customer_token = in_token;
  if not found then
    raise exception 'Order verification failed';
  end if;
end;
$fn$;

create or replace function public.recalculate_period(in_period_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  agent_row record;
  package_units integer;
  tier_name text;
begin
  for agent_row in
    select id, role from public.agents where status = 'active'
  loop
    select coalesce(sum(oi.quantity), 0)::integer into package_units
    from public.orders as o
    join public.order_items as oi on oi.order_id = o.id
    join public.products as p on p.id = oi.product_id
    where o.promotion_agent_id = agent_row.id
      and o.status = 'paid'
      and o.settlement_period_id = in_period_id
      and p.kind = 'package';

    tier_name := case
      when package_units >= 30 then '30+'
      when package_units >= 20 then '20-29'
      when package_units >= 10 then '10-19'
      else '1-9'
    end;

    update public.order_items as oi
    set
      tier_label = tier_name,
      final_tier_price = case tier_name
        when '30+' then p.tier_30_plus
        when '20-29' then p.tier_20_29
        when '10-19' then p.tier_10_19
        else p.tier_5_9
      end,
      secondary_profit = case when agent_row.role = 'secondary_agent' then
        oi.student_price - case tier_name
          when '30+' then p.tier_30_plus
          when '20-29' then p.tier_20_29
          when '10-19' then p.tier_10_19
          else p.tier_5_9
        end
      else 0 end,
      shareholder_profit = case when agent_row.role = 'shareholder' then
        oi.student_price - oi.factory_cost
      else
        case tier_name
          when '30+' then p.tier_30_plus
          when '20-29' then p.tier_20_29
          when '10-19' then p.tier_10_19
          else p.tier_5_9
        end - oi.factory_cost
      end
    from public.orders as o, public.products as p
    where oi.order_id = o.id
      and oi.product_id = p.id
      and o.promotion_agent_id = agent_row.id
      and o.status = 'paid'
      and o.settlement_period_id = in_period_id;
  end loop;
end;
$fn$;

create or replace function public.admin_update_order(
  in_order_id uuid,
  in_status public.order_status,
  in_refund_amount numeric default null,
  in_refund_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  target_period uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if in_status = 'paid' then
    select id into target_period
    from public.settlement_periods
    where status = 'open' and current_date between starts_on and ends_on
    order by starts_on desc
    limit 1;
    if target_period is null then
      raise exception 'No open settlement period exists';
    end if;
    update public.orders
    set status = 'paid', paid_at = coalesce(paid_at, now()),
        settlement_period_id = coalesce(settlement_period_id, target_period), updated_at = now()
    where id = in_order_id;
  elsif in_status = 'refunded' then
    update public.orders
    set status = 'refunded', refund_amount = in_refund_amount,
        refund_reason = in_refund_reason, refunded_at = now(), updated_at = now()
    where id = in_order_id;
  else
    update public.orders set status = in_status, updated_at = now() where id = in_order_id;
  end if;

  select settlement_period_id into target_period from public.orders where id = in_order_id;
  if target_period is not null then
    perform public.recalculate_period(target_period);
  end if;
end;
$fn$;

create or replace function public.admin_approve_agent(in_agent_id uuid, in_approve boolean, in_notes text default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  update public.agents
  set status = case when in_approve then 'active'::public.agent_status else 'rejected'::public.agent_status end,
      promotion_code = case when in_approve then coalesce(promotion_code, public.make_promotion_code()) else promotion_code end,
      approved_at = case when in_approve then now() else null end,
      notes = in_notes
  where id = in_agent_id;
end;
$fn$;

create or replace function public.admin_create_shareholder(in_name text, in_phone text default null, in_wechat text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare new_id uuid;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  insert into public.agents(name, phone, wechat, role, status, promotion_code, approved_at)
  values (trim(in_name), in_phone, in_wechat, 'shareholder', 'active', public.make_promotion_code(), now())
  returning id into new_id;
  return new_id;
end;
$fn$;

create or replace function public.active_shareholders()
returns table(id uuid, name text)
language sql
stable
security definer
set search_path = public
as $fn$
  select id, name
  from public.agents
  where role = 'shareholder' and status = 'active'
  order by name;
$fn$;

create or replace function public.admin_dashboard()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'shareholders', coalesce((
      select jsonb_agg(summary_row order by summary_row ->> 'name')
      from (
        select jsonb_build_object(
          'id', s.id,
          'name', s.name,
          'package_units', coalesce((
            select sum(oi.quantity)
            from public.orders as o
            join public.order_items as oi on oi.order_id = o.id
            join public.products as p on p.id = oi.product_id
            where o.shareholder_id = s.id and o.status = 'paid' and p.kind = 'package'
          ), 0),
          'sales', coalesce((
            select sum(oi.student_price * oi.quantity)
            from public.orders as o join public.order_items as oi on oi.order_id = o.id
            where o.shareholder_id = s.id and o.status = 'paid'
          ), 0),
          'profit', coalesce((
            select sum(oi.shareholder_profit * oi.quantity)
            from public.orders as o join public.order_items as oi on oi.order_id = o.id
            where o.shareholder_id = s.id and o.status = 'paid'
          ), 0),
          'promotion_code', s.promotion_code
        ) as summary_row
        from public.agents as s
        where s.role = 'shareholder' and s.status = 'active'
      ) as shareholder_rows
    ), '[]'::jsonb),
    'pending_agents', (select count(*) from public.agents where status = 'pending'),
    'pending_orders', (select count(*) from public.orders where status in ('awaiting_receipt', 'deposit_verified', 'awaiting_balance'))
  );
$fn$;

alter table public.profiles enable row level security;
alter table public.agents enable row level security;
alter table public.products enable row level security;
alter table public.settlement_periods enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "admin profiles" on public.profiles;
drop policy if exists "admin agents" on public.agents;
drop policy if exists "agent self read" on public.agents;
drop policy if exists "agent registration" on public.agents;
drop policy if exists "products public read" on public.products;
drop policy if exists "admin products" on public.products;
drop policy if exists "admin periods" on public.settlement_periods;
drop policy if exists "admin orders" on public.orders;
drop policy if exists "admin items" on public.order_items;
create policy "admin profiles" on public.profiles for select using (public.is_admin() or id = auth.uid());
create policy "admin agents" on public.agents for all using (public.is_admin()) with check (public.is_admin());
create policy "agent self read" on public.agents for select using (user_id = auth.uid());
create policy "agent registration" on public.agents for insert to authenticated with check (user_id = auth.uid() and role = 'secondary_agent' and status = 'pending');
create policy "products public read" on public.products for select using (active = true or public.is_admin());
create policy "admin products" on public.products for all using (public.is_admin()) with check (public.is_admin());
create policy "admin periods" on public.settlement_periods for all using (public.is_admin()) with check (public.is_admin());
create policy "admin orders" on public.orders for all using (public.is_admin()) with check (public.is_admin());
create policy "admin items" on public.order_items for all using (public.is_admin()) with check (public.is_admin());

grant execute on function public.submit_order(text,text,text,text,text,text,jsonb) to anon, authenticated;
grant execute on function public.attach_receipt(uuid,uuid,text) to anon, authenticated;
grant execute on function public.active_shareholders() to anon, authenticated;
grant execute on function public.admin_dashboard() to authenticated;
grant execute on function public.admin_update_order(uuid,public.order_status,numeric,text) to authenticated;
grant execute on function public.admin_approve_agent(uuid,boolean,text) to authenticated;
grant execute on function public.admin_create_shareholder(text,text,text) to authenticated;
grant execute on function public.recalculate_period(uuid) to authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
drop policy if exists "student receipt upload" on storage.objects;
drop policy if exists "admin receipt view" on storage.objects;
create policy "student receipt upload" on storage.objects for insert to anon, authenticated with check (bucket_id = 'receipts');
create policy "admin receipt view" on storage.objects for select to authenticated using (bucket_id = 'receipts' and public.is_admin());

insert into public.products(id,kind,name,student_price,deposit,factory_cost,tier_5_9,tier_10_19,tier_20_29,tier_30_plus) values
('P01','single','枕芯｜奶酪枕',29,10,9,24,20,20,18),('P02','single','枕芯｜记忆棉枕',59,10,25,42,38,38,35),
('Q01','single','被芯｜奶酪被（2斤）',79,20,30,59,55,55,52),('Q02','single','被芯｜奶酪被（4斤）',99,20,40,75,69,69,65),
('T01','single','三件套｜水洗棉',99,20,33,65,59,59,55),('T02','single','三件套｜纯棉',149,30,65,105,99,99,92),
('M01','single','床垫｜小竹垫 6CM',139,30,65,109,99,99,92),('M02','single','床垫｜小竹垫 8CM',179,30,85,139,129,129,120),
('M03','single','床垫｜小蓝垫 4CM',179,30,85,139,129,129,120),('M04','single','床垫｜小蓝垫 6CM',219,30,110,169,159,159,148),
('S06','package','水洗棉六件套｜小竹垫',428,50,169,318,298,298,288),('S07','package','水洗棉七件套｜小竹垫',488,50,202,358,338,338,328),
('S09','package','水洗棉九件套｜小竹垫',528,50,205,378,358,358,348),('S10','package','水洗棉十件套｜小竹垫',578,50,237,418,398,398,388),
('L06','package','水洗棉六件套｜小蓝垫',458,50,189,338,318,318,308),('L07','package','水洗棉七件套｜小蓝垫',518,50,222,398,378,378,368),
('L09','package','水洗棉九件套｜小蓝垫',558,50,225,418,398,398,388),('L10','package','水洗棉十件套｜小蓝垫',608,50,257,448,428,428,418)
on conflict (id) do update set
  student_price = excluded.student_price, deposit = excluded.deposit, factory_cost = excluded.factory_cost,
  tier_5_9 = excluded.tier_5_9, tier_10_19 = excluded.tier_10_19,
  tier_20_29 = excluded.tier_20_29, tier_30_plus = excluded.tier_30_plus;

insert into public.settlement_periods(name, starts_on, ends_on, status)
select '2026 招新结算周期', current_date, current_date + 90, 'open'
where not exists (select 1 from public.settlement_periods where status = 'open');

insert into public.agents(name, role, status, promotion_code, approved_at)
select '啊瀚', 'shareholder', 'active', 'ahan', now()
where not exists (select 1 from public.agents where name = '啊瀚' and role = 'shareholder');
insert into public.agents(name, role, status, promotion_code, approved_at)
select 'yy', 'shareholder', 'active', 'yy', now()
where not exists (select 1 from public.agents where name = 'yy' and role = 'shareholder');
insert into public.agents(name, role, status, promotion_code, approved_at)
select '赖狗狗', 'shareholder', 'active', 'laigougou', now()
where not exists (select 1 from public.agents where name = '赖狗狗' and role = 'shareholder');
