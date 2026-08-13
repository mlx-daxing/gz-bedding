-- 广职床品：首次初始化脚本
-- 在 Supabase → SQL Editor → New query 中完整粘贴并运行一次。

create extension if not exists pgcrypto;

create type public.profile_role as enum ('admin', 'agent');
create type public.agent_role as enum ('shareholder', 'secondary_agent');
create type public.agent_status as enum ('pending', 'active', 'disabled', 'rejected');
create type public.product_kind as enum ('package', 'single');
create type public.order_status as enum ('awaiting_receipt', 'deposit_verified', 'awaiting_balance', 'paid', 'refunded', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  role public.profile_role not null default 'agent',
  created_at timestamptz not null default now()
);

create table public.settlement_periods (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  starts_on date not null,
  ends_on date not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);

create table public.agents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references public.profiles(id) on delete set null,
  name text not null,
  phone text,
  wechat text,
  role public.agent_role not null,
  status public.agent_status not null default 'pending',
  shareholder_id uuid references public.agents(id) on delete restrict,
  promotion_code text unique,
  notes text,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  check ((role = 'shareholder' and shareholder_id is null) or (role = 'secondary_agent' and shareholder_id is not null))
);

create table public.products (
  id text primary key,
  kind public.product_kind not null,
  name text not null,
  student_price numeric(10,2) not null check (student_price >= 0),
  deposit numeric(10,2) not null check (deposit >= 0),
  factory_cost numeric(10,2) not null check (factory_cost >= 0),
  tier_5_9 numeric(10,2) not null,
  tier_10_19 numeric(10,2) not null,
  tier_20_29 numeric(10,2) not null,
  tier_30_plus numeric(10,2) not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text unique not null default ('GZ' || to_char(now(), 'YYYYMMDD') || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))),
  customer_token uuid not null default gen_random_uuid(),
  customer_name text not null,
  phone text not null,
  building text not null,
  room text not null,
  note text,
  promotion_code text,
  promotion_agent_id uuid references public.agents(id) on delete set null,
  shareholder_id uuid references public.agents(id) on delete set null,
  settlement_period_id uuid references public.settlement_periods(id) on delete set null,
  status public.order_status not null default 'awaiting_receipt',
  receipt_path text,
  deposit_total numeric(10,2) not null default 0,
  retail_total numeric(10,2) not null default 0,
  balance_due numeric(10,2) not null default 0,
  paid_at timestamptz,
  refund_amount numeric(10,2),
  refund_reason text,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id text not null references public.products(id),
  quantity integer not null check (quantity > 0),
  style text,
  student_price numeric(10,2) not null,
  factory_cost numeric(10,2) not null,
  final_tier_price numeric(10,2),
  tier_label text,
  secondary_profit numeric(10,2) not null default 0,
  shareholder_profit numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);

create index orders_status_idx on public.orders(status);
create index orders_agent_idx on public.orders(promotion_agent_id);
create index items_order_idx on public.order_items(order_id);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') $$;

create or replace function public.make_promotion_code()
returns text language plpgsql volatile as $$
declare code text;
begin
  loop
    code := 'gz' || lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from public.agents where promotion_code = code);
  end loop;
  return code;
end; $$;

-- 你的邮箱首次注册后会自动成为管理员；其他注册者只能成为待审核代理。

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, email, display_name, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    case when lower(coalesce(new.email, '')) = '309175115@qq.com' then 'admin'::public.profile_role else 'agent'::public.profile_role end
  ) on conflict (id) do nothing;
  return new;
end; $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.set_order_attribution()
returns trigger language plpgsql security definer set search_path = public as $$
declare a public.agents%rowtype;
begin
  if new.promotion_code is not null then
    select * into a from public.agents where promotion_code = new.promotion_code and status = 'active';
    if found then
      new.promotion_agent_id := a.id;
      new.shareholder_id := case when a.role = 'shareholder' then a.id else a.shareholder_id end;
    end if;
  end if;
  new.updated_at := now();
  return new;
end; $$;

create trigger set_order_attribution_before before insert or update of promotion_code on public.orders
for each row execute procedure public.set_order_attribution();

create or replace function public.snapshot_order_item()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.products%rowtype;
begin
  select * into p from public.products where id = new.product_id and active = true;
  if not found then raise exception '商品不存在或已下架'; end if;
  new.student_price := p.student_price;
  new.factory_cost := p.factory_cost;
  return new;
end; $$;

create trigger snapshot_order_item_before before insert on public.order_items
for each row execute procedure public.snapshot_order_item();

create or replace function public.refresh_order_totals(target_order uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders o set
    retail_total = coalesce((select sum(oi.student_price * oi.quantity) from public.order_items oi where oi.order_id = target_order), 0),
    deposit_total = coalesce((select sum(p.deposit * oi.quantity) from public.order_items oi join public.products p on p.id = oi.product_id where oi.order_id = target_order), 0),
    updated_at = now()
  where o.id = target_order;
  update public.orders set balance_due = greatest(retail_total - deposit_total, 0) where id = target_order;
end; $$;

create or replace function public.after_item_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.refresh_order_totals(coalesce(new.order_id, old.order_id));
  return coalesce(new, old);
end; $$;

create trigger refresh_totals_after_item after insert or update or delete on public.order_items
for each row execute procedure public.after_item_change();

-- 学生端调用：价格由数据库按商品表写入，前端不能伪造售价或成本。
create or replace function public.submit_order(
  p_name text, p_phone text, p_building text, p_room text, p_note text,
  p_promotion_code text, p_items jsonb
) returns table(order_id uuid, customer_token uuid, order_no text, deposit_total numeric, balance_due numeric)
language plpgsql security definer set search_path = public as $$
declare oid uuid; item jsonb;
begin
  if jsonb_array_length(p_items) = 0 then raise exception '请选择至少一件商品'; end if;
  insert into public.orders(customer_name, phone, building, room, note, promotion_code)
  values (trim(p_name), trim(p_phone), trim(p_building), trim(p_room), p_note, nullif(trim(p_promotion_code), '')) returning id into oid;
  for item in select * from jsonb_array_elements(p_items) loop
    insert into public.order_items(order_id, product_id, quantity, style)
    values (oid, item ->> 'product_id', greatest(1, (item ->> 'quantity')::integer), nullif(item ->> 'style', ''));
  end loop;
  return query select o.id, o.customer_token, o.order_no, o.deposit_total, o.balance_due from public.orders o where o.id = oid;
end; $$;

create or replace function public.attach_receipt(p_order_id uuid, p_token uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set receipt_path = p_path, status = 'awaiting_receipt', updated_at = now()
  where id = p_order_id and customer_token = p_token;
  if not found then raise exception '订单验证失败'; end if;
end; $$;

-- 只统计“已确认尾款”的套餐；每一套套餐 = 1 个阶梯销量单位，单卖不增加阶梯销量。
create or replace function public.recalculate_period(p_period uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a record; units integer; label text; tier_price numeric;
begin
  for a in select id, role, shareholder_id from public.agents where status = 'active' loop
    select coalesce(sum(oi.quantity), 0)::integer into units
    from public.orders o join public.order_items oi on oi.order_id = o.id join public.products p on p.id = oi.product_id
    where o.promotion_agent_id = a.id and o.status = 'paid' and o.settlement_period_id = p_period and p.kind = 'package';
    label := case when units >= 30 then '30+' when units >= 20 then '20–29' when units >= 10 then '10–19' else '5–9' end;
    update public.order_items oi set
      tier_label = label,
      final_tier_price = case label when '30+' then p.tier_30_plus when '20–29' then p.tier_20_29 when '10–19' then p.tier_10_19 else p.tier_5_9 end,
      secondary_profit = case when a.role = 'secondary_agent' then oi.student_price - (case label when '30+' then p.tier_30_plus when '20–29' then p.tier_20_29 when '10–19' then p.tier_10_19 else p.tier_5_9 end) else 0 end,
      shareholder_profit = case when a.role = 'shareholder' then oi.student_price - oi.factory_cost else (case label when '30+' then p.tier_30_plus when '20–29' then p.tier_20_29 when '10–19' then p.tier_10_19 else p.tier_5_9 end) - oi.factory_cost end
    from public.orders o, public.products p
    where oi.order_id = o.id and oi.product_id = p.id and o.promotion_agent_id = a.id and o.status = 'paid' and o.settlement_period_id = p_period;
  end loop;
end; $$;

create or replace function public.admin_update_order(
  p_order uuid, p_status public.order_status, p_refund_amount numeric default null, p_refund_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
declare period_id uuid;
begin
  if not public.is_admin() then raise exception '无管理权限'; end if;
  if p_status = 'paid' then
    select id into period_id from public.settlement_periods where status = 'open' and current_date between starts_on and ends_on order by starts_on desc limit 1;
    update public.orders set status='paid', paid_at=coalesce(paid_at, now()), settlement_period_id=coalesce(settlement_period_id, period_id), updated_at=now() where id=p_order;
  elsif p_status = 'refunded' then
    update public.orders set status='refunded', refund_amount=p_refund_amount, refund_reason=p_refund_reason, refunded_at=now(), updated_at=now() where id=p_order;
  else
    update public.orders set status=p_status, updated_at=now() where id=p_order;
  end if;
  select settlement_period_id into period_id from public.orders where id=p_order;
  if period_id is not null then perform public.recalculate_period(period_id); end if;
end; $$;

create or replace function public.admin_approve_agent(p_agent uuid, p_approve boolean, p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '无管理权限'; end if;
  update public.agents set status=case when p_approve then 'active'::public.agent_status else 'rejected'::public.agent_status end,
    promotion_code=case when p_approve then coalesce(promotion_code, public.make_promotion_code()) else promotion_code end,
    approved_at=case when p_approve then now() else null end, notes=p_notes where id=p_agent;
end; $$;

create or replace function public.admin_create_shareholder(p_name text, p_phone text default null, p_wechat text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if not public.is_admin() then raise exception '无管理权限'; end if;
  insert into public.agents(name, phone, wechat, role, status, promotion_code, approved_at)
  values (p_name, p_phone, p_wechat, 'shareholder', 'active', public.make_promotion_code(), now()) returning agents.id into id;
  return id;
end; $$;

create or replace function public.active_shareholders()
returns table(id uuid, name text) language sql stable security definer set search_path = public
as $$ select id, name from public.agents where role='shareholder' and status='active' order by name $$;

create or replace function public.admin_dashboard()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'shareholders', coalesce((select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('id', s.id, 'name', s.name,
        'package_units', coalesce((select sum(oi.quantity) from public.orders o join public.order_items oi on oi.order_id=o.id join public.products p on p.id=oi.product_id where o.shareholder_id=s.id and o.status='paid' and p.kind='package'),0),
        'sales', coalesce((select sum(oi.student_price*oi.quantity) from public.orders o join public.order_items oi on oi.order_id=o.id where o.shareholder_id=s.id and o.status='paid'),0),
        'profit', coalesce((select sum(oi.shareholder_profit*oi.quantity) from public.orders o join public.order_items oi on oi.order_id=o.id where o.shareholder_id=s.id and o.status='paid'),0),
        'promotion_code', s.promotion_code
      ) x from public.agents s where s.role='shareholder'
    ) q), '[]'::jsonb),
    'pending_agents', (select count(*) from public.agents where status='pending'),
    'pending_orders', (select count(*) from public.orders where status in ('awaiting_receipt','deposit_verified','awaiting_balance'))
  )
$$;

alter table public.profiles enable row level security;
alter table public.agents enable row level security;
alter table public.products enable row level security;
alter table public.settlement_periods enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create policy "admin profiles" on public.profiles for select using (public.is_admin() or id=auth.uid());
create policy "admin agents" on public.agents for all using (public.is_admin()) with check (public.is_admin());
create policy "agent self read" on public.agents for select using (user_id=auth.uid());
create policy "agent registration" on public.agents for insert to authenticated with check (user_id=auth.uid() and role='secondary_agent' and status='pending');
create policy "products public read" on public.products for select using (active=true or public.is_admin());
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
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "student receipt upload" on storage.objects for insert to anon, authenticated with check (bucket_id='receipts');
create policy "admin receipt view" on storage.objects for select to authenticated using (bucket_id='receipts' and public.is_admin());

-- 商品和你提供的完整价格表；股东底价=厂家成本，二级代理按套餐最终阶梯价结算。
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
on conflict (id) do update set student_price=excluded.student_price,deposit=excluded.deposit,factory_cost=excluded.factory_cost,tier_5_9=excluded.tier_5_9,tier_10_19=excluded.tier_10_19,tier_20_29=excluded.tier_20_29,tier_30_plus=excluded.tier_30_plus;

insert into public.settlement_periods(name,starts_on,ends_on,status)
values ('2026 招新结算周期', current_date, current_date + 90, 'open');
