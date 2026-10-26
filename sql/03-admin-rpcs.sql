-- Owner/staff reads and mutations. Every write also records an audit entry.

create or replace function public.monarc_admin_overview()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_recent jsonb; v_low jsonb; v_today date:=timezone('Africa/Algiers',now())::date;
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse','finance']);
  select coalesce(jsonb_agg(x),'[]'::jsonb) into v_recent from (
    select jsonb_build_object('id',o.id,'order_no',o.order_no,'customer_name',c.full_name,'phone',c.phone,'wilaya_code',o.wilaya_code,'commune',o.commune,'payment_method',o.payment_method,'payment_status',o.payment_status,'total_dzd',o.total_dzd,'status',o.status,'created_at',o.created_at) as x
    from public.monarc_orders o join public.monarc_customers c on c.id=o.customer_id order by o.created_at desc limit 8
  ) recent;
  select coalesce(jsonb_agg(x),'[]'::jsonb) into v_low from (
    select jsonb_build_object('product_name',p.name_fr,'sku',v.sku,'on_hand',i.on_hand,'reserved',i.reserved,'available',i.on_hand-i.reserved) as x
    from public.monarc_inventory i join public.monarc_variants v on v.id=i.variant_id join public.monarc_products p on p.id=v.product_id
    where v.active and p.status='published' and i.on_hand-i.reserved<=i.low_stock_threshold order by i.on_hand-i.reserved asc limit 12
  ) low;
  return jsonb_build_object(
    'orders_today',(select count(*) from public.monarc_orders where (created_at at time zone 'Africa/Algiers')::date=v_today),
    'pending_confirmation',(select count(*) from public.monarc_orders where status='pending_confirmation'),
    'sales_today_dzd',coalesce((select sum(total_dzd) from public.monarc_orders where status='delivered' and (updated_at at time zone 'Africa/Algiers')::date=v_today),0),
    'collected_today_dzd',coalesce((select sum(amount_dzd) from public.monarc_payments where status='recorded' and (created_at at time zone 'Africa/Algiers')::date=v_today),0),
    'low_stock_count',(select count(*) from public.monarc_inventory i join public.monarc_variants v on v.id=i.variant_id join public.monarc_products p on p.id=v.product_id where v.active and p.status='published' and i.on_hand-i.reserved<=i.low_stock_threshold),
    'recent_orders',v_recent,'low_stock',v_low
  );
end;
$$;

create or replace function public.monarc_admin_orders(p_status text default null,p_query text default null)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse','finance']);
  return coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'order_no',o.order_no,'created_at',o.created_at,'status',o.status,'customer_name',c.full_name,'phone',c.phone,'email',c.email,'wilaya_code',o.wilaya_code,'commune',o.commune,'address',o.address,'payment_method',o.payment_method,'payment_status',o.payment_status,'subtotal_dzd',o.subtotal_dzd,'shipping_fee_dzd',o.shipping_fee_dzd,'shipping_quote_pending',o.shipping_quote_pending,'total_dzd',o.total_dzd,'provider_id',o.provider_id,'tracking_number',o.tracking_number)
    order by o.created_at desc) from public.monarc_orders o join public.monarc_customers c on c.id=o.customer_id
    where (p_status is null or p_status='all' or o.status=p_status)
      and (p_query is null or p_query='' or o.order_no ilike '%'||p_query||'%' or c.full_name ilike '%'||p_query||'%' or c.phone ilike '%'||p_query||'%')
    limit 500),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_admin_order_detail(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_order jsonb; v_items jsonb; v_history jsonb;
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse','finance']);
  select jsonb_build_object('id',o.id,'order_no',o.order_no,'status',o.status,'created_at',o.created_at,'updated_at',o.updated_at,'customer_id',c.id,'customer_name',c.full_name,'phone',c.phone,'email',c.email,'wilaya_code',o.wilaya_code,'commune',o.commune,'address',o.address,'customer_note',o.customer_note,'internal_note',o.internal_note,'payment_method',o.payment_method,'payment_status',o.payment_status,'subtotal_dzd',o.subtotal_dzd,'shipping_fee_dzd',o.shipping_fee_dzd,'shipping_quote_pending',o.shipping_quote_pending,'total_dzd',o.total_dzd,'provider_id',o.provider_id,'provider_name',d.name,'delivery_type',o.delivery_type,'tracking_number',o.tracking_number)
  into v_order from public.monarc_orders o join public.monarc_customers c on c.id=o.customer_id left join public.monarc_delivery_providers d on d.id=o.provider_id where o.id=p_order_id;
  if v_order is null then raise exception 'Order not found.' using errcode='P0002'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_name_fr',i.product_name_fr,'product_name_en',i.product_name_en,'product_name_ar',i.product_name_ar,'sku',i.sku_snapshot,'size',i.size_snapshot,'color_fr',i.color_fr_snapshot,'color_en',i.color_en_snapshot,'quantity',i.quantity,'unit_price_dzd',i.unit_price_dzd,'line_total_dzd',i.line_total_dzd) order by i.id),'[]'::jsonb) into v_items from public.monarc_order_items i where i.order_id=p_order_id;
  select coalesce(jsonb_agg(jsonb_build_object('status',h.to_status,'from_status',h.from_status,'actor',h.actor_label,'reason',h.reason,'created_at',h.created_at) order by h.created_at),'[]'::jsonb) into v_history from public.monarc_order_history h where h.order_id=p_order_id;
  return jsonb_build_object('order',v_order,'items',v_items,'history',v_history);
end;
$$;

create or replace function public.monarc_admin_products()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','warehouse']);
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'category_slug',p.category_slug,'name_fr',p.name_fr,'name_en',p.name_en,'name_ar',p.name_ar,'description_fr',p.description_fr,'description_en',p.description_en,'description_ar',p.description_ar,'price_dzd',p.price_dzd,'compare_at_dzd',p.compare_at_dzd,'purchase_cost_dzd',p.purchase_cost_dzd,'sku',p.sku,'images',to_jsonb(p.images),'tag_fr',p.tag_fr,'status',p.status,'featured',p.featured,'created_at',p.created_at,
    'variant_count',(select count(*) from public.monarc_variants v where v.product_id=p.id),
    'variants',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'sku',v.sku,'size',v.size,'color_fr',v.color_fr,'color_en',v.color_en,'color_ar',v.color_ar,'price_override_dzd',v.price_override_dzd,'active',v.active,'on_hand',coalesce(i.on_hand,0),'reserved',coalesce(i.reserved,0),'low_stock_threshold',coalesce(i.low_stock_threshold,3)) order by v.size,v.color_fr) from public.monarc_variants v left join public.monarc_inventory i on i.variant_id=v.id where v.product_id=p.id),'[]'::jsonb)
  ) order by p.created_at desc) from public.monarc_products p),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_admin_inventory()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','warehouse']);
  return coalesce((select jsonb_agg(jsonb_build_object('variant_id',v.id,'product_id',p.id,'product_name',p.name_fr,'sku',v.sku,'size',v.size,'color',v.color_fr,'on_hand',i.on_hand,'reserved',i.reserved,'available',i.on_hand-i.reserved,'low_stock_threshold',i.low_stock_threshold) order by p.name_fr,v.size,v.color_fr)
    from public.monarc_inventory i join public.monarc_variants v on v.id=i.variant_id join public.monarc_products p on p.id=v.product_id where v.active and p.status<>'archived'),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_admin_delivery()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse']);
  return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'active',d.active,'supports_home',d.supports_home,'supports_office',d.supports_office,'tracking_url_template',d.tracking_url_template,'notes',d.notes,'rates',coalesce((select jsonb_agg(jsonb_build_object('wilaya_code',r.wilaya_code,'wilaya_name',r.wilaya_code,'delivery_type',r.delivery_type,'fee_dzd',r.fee_dzd,'estimated_days',r.estimated_days) order by r.wilaya_code,r.delivery_type) from public.monarc_delivery_rates r where r.provider_id=d.id),'[]'::jsonb)) order by d.name) from public.monarc_delivery_providers d),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_save_delivery_provider(p_provider jsonb,p_rates jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_rate record;
begin
  perform public.monarc_require_roles(array['owner','manager']);
  v_id:=coalesce(nullif(p_provider->>'id','')::uuid,gen_random_uuid());
  if length(trim(coalesce(p_provider->>'name','')))<2 then raise exception 'Carrier name is required.' using errcode='22023'; end if;
  insert into public.monarc_delivery_providers(id,name,active,supports_home,supports_office,tracking_url_template,notes,updated_at)
  values(v_id,trim(p_provider->>'name'),coalesce((p_provider->>'active')::boolean,false),coalesce((p_provider->>'supports_home')::boolean,true),coalesce((p_provider->>'supports_office')::boolean,false),coalesce(p_provider->>'tracking_url_template',''),coalesce(p_provider->>'notes',''),now())
  on conflict(id) do update set name=excluded.name,active=excluded.active,supports_home=excluded.supports_home,supports_office=excluded.supports_office,tracking_url_template=excluded.tracking_url_template,notes=excluded.notes,updated_at=now();
  delete from public.monarc_delivery_rates where provider_id=v_id;
  if jsonb_typeof(coalesce(p_rates,'[]'::jsonb))='array' then
    for v_rate in select value from jsonb_array_elements(coalesce(p_rates,'[]'::jsonb)) loop
      if (v_rate.value->>'wilaya_code') !~ '^(0[1-9]|[1-5][0-9])$' or v_rate.value->>'delivery_type' not in ('home','office') or (v_rate.value->>'fee_dzd')::integer<0 then raise exception 'Invalid delivery rate.' using errcode='22023'; end if;
      insert into public.monarc_delivery_rates(provider_id,wilaya_code,delivery_type,fee_dzd) values(v_id,v_rate.value->>'wilaya_code',v_rate.value->>'delivery_type',(v_rate.value->>'fee_dzd')::integer);
    end loop;
  end if;
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason) values((select auth.uid()),'Staff','delivery_provider_saved','delivery_provider',v_id,'Provider and delivery rates updated');
  return jsonb_build_object('id',v_id,'message','Carrier saved');
end;
$$;

create or replace function public.monarc_admin_customers(p_query text default null)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','finance']);
  return coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'full_name',c.full_name,'phone',c.phone,'email',c.email,'order_count',coalesce(x.order_count,0),'lifetime_total_dzd',coalesce(x.lifetime_total_dzd,0),'last_order_at',x.last_order_at,'internal_note',c.internal_note) order by x.last_order_at desc nulls last)
    from public.monarc_customers c left join lateral (select count(*) as order_count,sum(o.total_dzd) as lifetime_total_dzd,max(o.created_at) as last_order_at from public.monarc_orders o where o.customer_id=c.id and o.status<>'cancelled' and o.status<>'rejected') x on true
    where p_query is null or p_query='' or c.full_name ilike '%'||p_query||'%' or c.phone ilike '%'||p_query||'%'),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_admin_payments(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager','finance']);
  return coalesce((select jsonb_agg(jsonb_build_object('order_id',o.id,'order_no',o.order_no,'customer_name',c.full_name,'phone',c.phone,'payment_method',o.payment_method,'payment_status',o.payment_status,'total_dzd',o.total_dzd,'paid_dzd',coalesce(x.paid_dzd,0),'created_at',o.created_at) order by o.created_at desc)
    from public.monarc_orders o join public.monarc_customers c on c.id=o.customer_id left join lateral (select sum(amount_dzd) as paid_dzd from public.monarc_payments p where p.order_id=o.id and p.status='recorded') x on true
    where (p_status is null or p_status='all' or o.payment_status=p_status)),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_mark_ccp_contacted(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_order public.monarc_orders%rowtype;
begin
  perform public.monarc_require_roles(array['owner','manager','finance','order_agent']);
  select * into v_order from public.monarc_orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.' using errcode='P0002'; end if;
  if v_order.payment_method<>'ccp' or v_order.payment_status<>'ccp_pending_contact' then raise exception 'This order is not awaiting CCP instructions.' using errcode='22023'; end if;
  update public.monarc_orders set payment_status='awaiting_transfer',updated_at=now() where id=p_order_id;
  insert into public.monarc_order_history(order_id,from_status,to_status,actor_id,actor_label,reason) values(p_order_id,v_order.status,v_order.status,(select auth.uid()),'Staff','CCP transfer instructions sent');
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason) values((select auth.uid()),'Staff','ccp_instructions_sent','order',p_order_id,'Owner contacted customer with CCP payment instructions');
  return jsonb_build_object('order_id',p_order_id,'payment_status','awaiting_transfer');
end;
$$;

create or replace function public.monarc_record_payment(p_order_id uuid,p_amount_dzd integer,p_reference text default '',p_note text default '')
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_order public.monarc_orders%rowtype; v_paid integer;
begin
  perform public.monarc_require_roles(array['owner','manager','finance']);
  if p_amount_dzd is null or p_amount_dzd<=0 then raise exception 'Payment amount must be positive.' using errcode='22023'; end if;
  select * into v_order from public.monarc_orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.' using errcode='P0002'; end if;
  select coalesce(sum(amount_dzd),0) into v_paid from public.monarc_payments where order_id=p_order_id and status='recorded';
  if v_paid+p_amount_dzd>v_order.total_dzd then raise exception 'Recorded collection exceeds the order total.' using errcode='23514'; end if;
  insert into public.monarc_payments(order_id,method,amount_dzd,reference,note,recorded_by) values(p_order_id,v_order.payment_method,p_amount_dzd,left(coalesce(p_reference,''),120),left(coalesce(p_note,''),500),(select auth.uid()));
  v_paid:=v_paid+p_amount_dzd;
  update public.monarc_orders set payment_status=case when v_paid>=v_order.total_dzd then 'paid' else 'partially_paid' end,updated_at=now() where id=p_order_id;
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Staff','payment_recorded','order',p_order_id,left(coalesce(p_note,''),300),jsonb_build_object('amount_dzd',p_amount_dzd,'paid_total_dzd',v_paid));
  return jsonb_build_object('order_id',p_order_id,'paid_dzd',v_paid,'payment_status',case when v_paid>=v_order.total_dzd then 'paid' else 'partially_paid' end);
end;
$$;

create or replace function public.monarc_admin_analytics(p_period text default '30d')
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_days integer; v_since date; v_daily jsonb; v_best jsonb; v_sales integer; v_collected integer; v_outstanding integer; v_profit integer; v_orders integer;
begin
  perform public.monarc_require_roles(array['owner','manager','finance']);
  v_days:=case when p_period='7d' then 7 when p_period='90d' then 90 else 30 end; v_since:=timezone('Africa/Algiers',now())::date-v_days+1;
  select coalesce(sum(total_dzd),0),count(*) into v_sales,v_orders from public.monarc_orders where status='delivered' and (updated_at at time zone 'Africa/Algiers')::date>=v_since;
  select coalesce(sum(amount_dzd),0) into v_collected from public.monarc_payments where status='recorded' and created_at>=now()-(v_days*interval '1 day');
  select coalesce(sum(greatest(o.total_dzd-coalesce(x.paid_dzd,0),0)),0) into v_outstanding from public.monarc_orders o left join lateral (select sum(amount_dzd) as paid_dzd from public.monarc_payments p where p.order_id=o.id and p.status='recorded') x on true where o.status not in ('cancelled','rejected','returned') and o.created_at>=now()-(v_days*interval '1 day');
  select coalesce(sum((i.unit_price_dzd-i.cost_snapshot_dzd)*i.quantity),0) into v_profit from public.monarc_order_items i join public.monarc_orders o on o.id=i.order_id where o.status='delivered' and (o.updated_at at time zone 'Africa/Algiers')::date>=v_since;
  select coalesce(jsonb_agg(jsonb_build_object('day',d.day,'total_dzd',coalesce(s.total_dzd,0)) order by d.day),'[]'::jsonb) into v_daily from generate_series(v_since,timezone('Africa/Algiers',now())::date,interval '1 day') d(day) left join (select (updated_at at time zone 'Africa/Algiers')::date as day,sum(total_dzd) as total_dzd from public.monarc_orders where status='delivered' group by 1) s on s.day=d.day;
  select coalesce(jsonb_agg(jsonb_build_object('product_name',q.product_name,'units_sold',q.units_sold,'gross_sales_dzd',q.gross_sales_dzd) order by q.units_sold desc),'[]'::jsonb) into v_best from (select i.product_name_fr as product_name,sum(i.quantity)::integer as units_sold,sum(i.line_total_dzd)::integer as gross_sales_dzd from public.monarc_order_items i join public.monarc_orders o on o.id=i.order_id where o.status='delivered' and o.created_at>=now()-(v_days*interval '1 day') group by i.product_name_fr order by sum(i.quantity) desc limit 10) q;
  return jsonb_build_object('gross_sales_dzd',v_sales,'collected_dzd',v_collected,'outstanding_dzd',v_outstanding,'gross_profit_estimate_dzd',v_profit,'orders_delivered',v_orders,'average_order_dzd',case when v_orders=0 then 0 else round(v_sales::numeric/v_orders)::integer end,'sales_by_day',v_daily,'best_sellers',v_best);
end;
$$;

create or replace function public.monarc_admin_staff()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner']);
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',s.user_id,'email',s.email,'display_name',s.display_name,'role',s.role,'active',s.active,'created_at',s.created_at) order by s.created_at) from public.monarc_staff s),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_set_staff_role(p_user_id uuid,p_role text,p_active boolean,p_display_name text,p_email text)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner']);
  if p_role not in ('owner','manager','order_agent','warehouse','finance') then raise exception 'Invalid staff role.' using errcode='22023'; end if;
  if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'Create the user in Supabase Auth first.' using errcode='P0002'; end if;
  if p_user_id=(select auth.uid()) and not coalesce(p_active,true) then raise exception 'You cannot deactivate your own active owner account.' using errcode='42501'; end if;
  insert into public.monarc_staff(user_id,email,display_name,role,active) values(p_user_id,lower(trim(p_email)),trim(p_display_name),p_role,coalesce(p_active,true))
  on conflict(user_id) do update set email=excluded.email,display_name=excluded.display_name,role=excluded.role,active=excluded.active,updated_at=now();
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Owner','staff_role_changed','staff',p_user_id,'Staff access updated',jsonb_build_object('role',p_role,'active',p_active));
  return jsonb_build_object('user_id',p_user_id,'role',p_role,'active',p_active);
end;
$$;

create or replace function public.monarc_admin_get_settings()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager']);
  return (select to_jsonb(s)-'id' from public.monarc_settings s where id=true);
end;
$$;

create or replace function public.monarc_save_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager']);
  update public.monarc_settings set
    shop_name_fr=coalesce(nullif(p_settings->>'shop_name_fr',''),shop_name_fr),shop_name_en=coalesce(nullif(p_settings->>'shop_name_en',''),shop_name_en),shop_name_ar=coalesce(nullif(p_settings->>'shop_name_ar',''),shop_name_ar),
    whatsapp=coalesce(p_settings->>'whatsapp',whatsapp),contact_email=coalesce(p_settings->>'contact_email',contact_email),announcement_fr=coalesce(p_settings->>'announcement_fr',announcement_fr),announcement_en=coalesce(p_settings->>'announcement_en',announcement_en),announcement_ar=coalesce(p_settings->>'announcement_ar',announcement_ar),
    cod_enabled=coalesce((p_settings->>'cod_enabled')::boolean,cod_enabled),ccp_enabled=coalesce((p_settings->>'ccp_enabled')::boolean,ccp_enabled),
    ccp_account_name=coalesce(p_settings->>'ccp_account_name',ccp_account_name),ccp_account_number=coalesce(p_settings->>'ccp_account_number',ccp_account_number),
    ccp_instructions_fr=coalesce(p_settings->>'ccp_instructions_fr',ccp_instructions_fr),ccp_instructions_en=coalesce(p_settings->>'ccp_instructions_en',ccp_instructions_en),ccp_instructions_ar=coalesce(p_settings->>'ccp_instructions_ar',ccp_instructions_ar),
    returns_policy_fr=coalesce(p_settings->>'returns_policy_fr',returns_policy_fr),returns_policy_en=coalesce(p_settings->>'returns_policy_en',returns_policy_en),returns_policy_ar=coalesce(p_settings->>'returns_policy_ar',returns_policy_ar),meta_pixel_id=coalesce(p_settings->>'meta_pixel_id',meta_pixel_id),store_active=coalesce((p_settings->>'store_active')::boolean,store_active),updated_at=now()
  where id=true;
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,reason) values((select auth.uid()),'Staff','settings_saved','store_settings','Store/payment settings changed');
  return jsonb_build_object('saved',true);
end;
$$;

create or replace function public.monarc_admin_audit()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager']);
  return coalesce((select jsonb_agg(jsonb_build_object('created_at',a.created_at,'actor_name',coalesce(s.display_name,a.actor_label),'actor_email',s.email,'action',a.action,'entity_type',a.entity_type,'entity_id',a.entity_id,'reason',a.reason,'details',a.details) order by a.created_at desc) from (select * from public.monarc_audit_log order by created_at desc limit 300) a left join public.monarc_staff s on s.user_id=a.actor_id),'[]'::jsonb);
end;
$$;

create or replace function public.monarc_update_delivery(p_order_id uuid,p_tracking_number text,p_provider_id uuid,p_shipping_fee_dzd integer,p_note text default '')
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_order public.monarc_orders%rowtype;
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse']);
  select * into v_order from public.monarc_orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.' using errcode='P0002'; end if;
  if p_shipping_fee_dzd<0 then raise exception 'Delivery fee cannot be negative.' using errcode='22023'; end if;
  update public.monarc_orders set tracking_number=nullif(trim(coalesce(p_tracking_number,'')),''),provider_id=p_provider_id,shipping_fee_dzd=p_shipping_fee_dzd,shipping_quote_pending=false,total_dzd=subtotal_dzd+p_shipping_fee_dzd,internal_note=case when p_note='' then internal_note else left(coalesce(internal_note||E'\n','')||p_note,1000) end,updated_at=now() where id=p_order_id;
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Staff','delivery_updated','order',p_order_id,left(coalesce(p_note,''),300),jsonb_build_object('tracking_number',p_tracking_number,'shipping_fee_dzd',p_shipping_fee_dzd));
  return jsonb_build_object('order_id',p_order_id,'shipping_fee_dzd',p_shipping_fee_dzd);
end;
$$;

-- All SECURITY DEFINER functions have fixed search_path. Only the storefront, order request,
-- and token-based order tracking functions are callable by anonymous visitors.
revoke all on function public.monarc_has_role(text[]) from public,anon;
revoke all on function public.monarc_require_roles(text[]) from public,anon,authenticated;
revoke all on function public.monarc_staff_profile() from public,anon;
revoke all on function public.monarc_storefront() from public;
revoke all on function public.monarc_place_order(jsonb) from public;
revoke all on function public.monarc_track_order(text,uuid) from public;
revoke all on function public.monarc_change_order_status(uuid,text,text) from public,anon;
revoke all on function public.monarc_adjust_inventory(uuid,integer,text) from public,anon;
revoke all on function public.monarc_save_product(jsonb,jsonb) from public,anon;
revoke all on function public.monarc_archive_product(uuid) from public,anon;
revoke all on function public.monarc_admin_overview() from public,anon;
revoke all on function public.monarc_admin_orders(text,text) from public,anon;
revoke all on function public.monarc_admin_order_detail(uuid) from public,anon;
revoke all on function public.monarc_admin_products() from public,anon;
revoke all on function public.monarc_admin_inventory() from public,anon;
revoke all on function public.monarc_admin_delivery() from public,anon;
revoke all on function public.monarc_save_delivery_provider(jsonb,jsonb) from public,anon;
revoke all on function public.monarc_admin_customers(text) from public,anon;
revoke all on function public.monarc_admin_payments(text) from public,anon;
revoke all on function public.monarc_record_payment(uuid,integer,text,text) from public,anon;
revoke all on function public.monarc_admin_analytics(text) from public,anon;
revoke all on function public.monarc_admin_staff() from public,anon;
revoke all on function public.monarc_set_staff_role(uuid,text,boolean,text,text) from public,anon;
revoke all on function public.monarc_admin_get_settings() from public,anon;
revoke all on function public.monarc_save_settings(jsonb) from public,anon;
revoke all on function public.monarc_admin_audit() from public,anon;
revoke all on function public.monarc_update_delivery(uuid,text,uuid,integer,text) from public,anon;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'monarc_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated',f.signature);
  end loop;
end;
$$;

grant execute on function public.monarc_has_role(text[]) to authenticated;
grant execute on function public.monarc_staff_profile() to authenticated;
grant execute on function public.monarc_storefront() to anon,authenticated;
grant execute on function public.monarc_place_order(jsonb) to anon,authenticated;
grant execute on function public.monarc_track_order(text,uuid) to anon,authenticated;
grant execute on function public.monarc_change_order_status(uuid,text,text) to authenticated;
grant execute on function public.monarc_adjust_inventory(uuid,integer,text) to authenticated;
grant execute on function public.monarc_save_product(jsonb,jsonb) to authenticated;
grant execute on function public.monarc_archive_product(uuid) to authenticated;
grant execute on function public.monarc_admin_overview() to authenticated;
grant execute on function public.monarc_admin_orders(text,text) to authenticated;
grant execute on function public.monarc_admin_order_detail(uuid) to authenticated;
grant execute on function public.monarc_admin_products() to authenticated;
grant execute on function public.monarc_admin_inventory() to authenticated;
grant execute on function public.monarc_admin_delivery() to authenticated;
grant execute on function public.monarc_save_delivery_provider(jsonb,jsonb) to authenticated;
grant execute on function public.monarc_admin_customers(text) to authenticated;
grant execute on function public.monarc_admin_payments(text) to authenticated;
grant execute on function public.monarc_record_payment(uuid,integer,text,text) to authenticated;
grant execute on function public.monarc_mark_ccp_contacted(uuid) to authenticated;
grant execute on function public.monarc_admin_analytics(text) to authenticated;
grant execute on function public.monarc_admin_staff() to authenticated;
grant execute on function public.monarc_set_staff_role(uuid,text,boolean,text,text) to authenticated;
grant execute on function public.monarc_admin_get_settings() to authenticated;
grant execute on function public.monarc_save_settings(jsonb) to authenticated;
grant execute on function public.monarc_admin_audit() to authenticated;
grant execute on function public.monarc_update_delivery(uuid,text,uuid,integer,text) to authenticated;

-- Only public-read product photos. Writes require an authenticated MONARC owner/manager.
drop policy if exists "monarc public product photo read" on storage.objects;
create policy "monarc public product photo read" on storage.objects for select to anon,authenticated using(bucket_id='monarc-product-images');
drop policy if exists "monarc owner uploads product photos" on storage.objects;
create policy "monarc owner uploads product photos" on storage.objects for insert to authenticated with check(bucket_id='monarc-product-images' and public.monarc_has_role(array['owner','manager']));
drop policy if exists "monarc owner updates product photos" on storage.objects;
create policy "monarc owner updates product photos" on storage.objects for update to authenticated using(bucket_id='monarc-product-images' and public.monarc_has_role(array['owner','manager'])) with check(bucket_id='monarc-product-images' and public.monarc_has_role(array['owner','manager']));
drop policy if exists "monarc owner deletes product photos" on storage.objects;
create policy "monarc owner deletes product photos" on storage.objects for delete to authenticated using(bucket_id='monarc-product-images' and public.monarc_has_role(array['owner','manager']));

-- Lock the upload bucket to web-safe image types and a 4 MiB maximum.
update storage.buckets set public=true,file_size_limit=4194304,allowed_mime_types=array['image/jpeg','image/png','image/webp'] where id='monarc-product-images';
