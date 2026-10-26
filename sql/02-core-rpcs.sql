-- Core RPCs: staff authorization, storefront, order entry/tracking, status+stock transactions, product writes.

create or replace function public.monarc_has_role(p_roles text[])
returns boolean
language sql stable security definer set search_path=''
as $$
  select exists(
    select 1 from public.monarc_staff s
    where s.user_id=(select auth.uid()) and s.active and s.role=any(p_roles)
  );
$$;

create or replace function public.monarc_require_roles(p_roles text[])
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if not public.monarc_has_role(p_roles) then
    raise exception 'Access denied for this operation.' using errcode='42501';
  end if;
end;
$$;

create or replace function public.monarc_staff_profile()
returns jsonb
language sql stable security definer set search_path=''
as $$
  select jsonb_build_object('user_id',s.user_id,'email',s.email,'display_name',s.display_name,'role',s.role,'active',s.active)
  from public.monarc_staff s where s.user_id=(select auth.uid()) and s.active;
$$;

create or replace function public.monarc_storefront()
returns jsonb
language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object(
      'shop_name_fr',s.shop_name_fr,'shop_name_en',s.shop_name_en,'shop_name_ar',s.shop_name_ar,
      'whatsapp',s.whatsapp,'announcement_fr',s.announcement_fr,'announcement_en',s.announcement_en,'announcement_ar',s.announcement_ar,
      'cod_enabled',s.cod_enabled,'ccp_enabled',s.ccp_enabled,'ccp_account_name',s.ccp_account_name,
      'ccp_account_number',s.ccp_account_number,'ccp_instructions_fr',s.ccp_instructions_fr,
      'ccp_instructions_en',s.ccp_instructions_en,'ccp_instructions_ar',s.ccp_instructions_ar,
      'returns_policy_fr',s.returns_policy_fr,'returns_policy_en',s.returns_policy_en,'returns_policy_ar',s.returns_policy_ar,
      'meta_pixel_id',s.meta_pixel_id,'store_active',s.store_active,'contact_email',s.contact_email
    ) from public.monarc_settings s where s.id=true),
    'categories',coalesce((select jsonb_agg(jsonb_build_object('slug',c.slug,'name_fr',c.name_fr,'name_en',c.name_en,'name_ar',c.name_ar) order by c.sort_order) from public.monarc_categories c where c.active),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'category_slug',p.category_slug,'category_fr',c.name_fr,'category_en',c.name_en,'category_ar',c.name_ar,
      'name_fr',p.name_fr,'name_en',p.name_en,'name_ar',p.name_ar,
      'description_fr',p.description_fr,'description_en',p.description_en,'description_ar',p.description_ar,
      'price_dzd',p.price_dzd,'compare_at_dzd',p.compare_at_dzd,'images',to_jsonb(p.images),'featured',p.featured,'tag_fr',p.tag_fr,
      'variants',coalesce((select jsonb_agg(jsonb_build_object(
        'id',v.id,'sku',v.sku,'size',v.size,'color_fr',v.color_fr,'color_en',v.color_en,'color_ar',v.color_ar,
        'price_dzd',coalesce(v.price_override_dzd,p.price_dzd),'available',coalesce(i.on_hand-i.reserved>0,false)
      ) order by v.size,v.color_fr) from public.monarc_variants v left join public.monarc_inventory i on i.variant_id=v.id where v.product_id=p.id and v.active),'[]'::jsonb)
    ) order by p.featured desc,p.created_at desc) from public.monarc_products p join public.monarc_categories c on c.slug=p.category_slug and c.active where p.status='published'),'[]'::jsonb),
    'delivery',jsonb_build_object('providers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',d.id,'name',d.name,'active',d.active,'supports_home',d.supports_home,'supports_office',d.supports_office,
      'rates',coalesce((select jsonb_agg(jsonb_build_object('wilaya_code',r.wilaya_code,'delivery_type',r.delivery_type,'fee_dzd',r.fee_dzd,'estimated_days',r.estimated_days)) from public.monarc_delivery_rates r where r.provider_id=d.id),'[]'::jsonb)
    )) from public.monarc_delivery_providers d where d.active),'[]'::jsonb))
  );
$$;

create or replace function public.monarc_place_order(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_customer_name text; v_phone_input text; v_phone text; v_email text;
  v_wilaya text; v_commune text; v_address text; v_note text; v_method text; v_delivery_type text;
  v_provider_id uuid; v_provider_name text; v_fee integer:=0; v_shipping_pending boolean:=true;
  v_customer_id uuid; v_order_id uuid; v_order_no text; v_token uuid:=gen_random_uuid(); v_recent_attempts integer:=0;
  v_subtotal integer:=0; v_qty integer; v_variant_id uuid; v_available integer; v_items jsonb:='[]'::jsonb;
  v_input record; v_item record; v_order_status text:='pending_confirmation'; v_payment_status text;
  v_cod_enabled boolean; v_ccp_enabled boolean; v_store_active boolean;
begin
  select cod_enabled,ccp_enabled,store_active into v_cod_enabled,v_ccp_enabled,v_store_active from public.monarc_settings where id=true;
  if not coalesce(v_store_active,false) then raise exception 'Store is temporarily closed.' using errcode='55000'; end if;
  v_customer_name:=trim(coalesce(p_payload#>>'{customer,name}',''));
  if nullif(trim(coalesce(p_payload->>'website','')),'') is not null then raise exception 'Invalid order request.' using errcode='22023'; end if;
  v_phone_input:=coalesce(p_payload#>>'{customer,phone}','');
  v_phone:=regexp_replace(v_phone_input,'[^0-9]','','g');
  if v_phone like '00213%' then v_phone:=substring(v_phone from 3); end if;
  if v_phone like '0%' and length(v_phone)=10 then v_phone:='213'||substring(v_phone from 2); end if;
  if length(v_customer_name)<2 or length(v_customer_name)>120 then raise exception 'Enter a valid customer name.' using errcode='22023'; end if;
  if v_phone !~ '^213[567][0-9]{8}$' then raise exception 'Enter a valid Algerian mobile number.' using errcode='22023'; end if;
  select count(*) into v_recent_attempts from public.monarc_orders o join public.monarc_customers c on c.id=o.customer_id where c.phone=v_phone and o.status='pending_confirmation' and o.created_at>now()-interval '10 minutes';
  if v_recent_attempts>=5 then raise exception 'Too many recent pending requests for this phone.' using errcode='22023'; end if;
  v_email:=nullif(trim(coalesce(p_payload#>>'{customer,email}','')),'');
  if coalesce((p_payload->>'privacy_consent')::boolean,false) is not true then raise exception 'Consent is required to process the order.' using errcode='22023'; end if;
  v_wilaya:=coalesce(p_payload->>'wilaya_code',''); v_commune:=trim(coalesce(p_payload->>'commune','')); v_address:=trim(coalesce(p_payload->>'address',''));
  v_note:=left(coalesce(p_payload->>'customer_note',''),500); v_method:=coalesce(p_payload->>'payment_method',''); v_delivery_type:=coalesce(p_payload->>'delivery_type','home');
  if v_wilaya !~ '^(0[1-9]|[1-5][0-9])$' then raise exception 'Choose a valid wilaya.' using errcode='22023'; end if;
  if length(v_commune)<2 or length(v_address)<4 then raise exception 'Enter the commune and delivery address.' using errcode='22023'; end if;
  if v_delivery_type not in ('home','office') then raise exception 'Invalid delivery type.' using errcode='22023'; end if;
  if v_method not in ('cod','ccp') then raise exception 'Choose a supported payment method.' using errcode='22023'; end if;
  if (v_method='cod' and not v_cod_enabled) or (v_method='ccp' and not v_ccp_enabled) then raise exception 'This payment method is disabled.' using errcode='22023'; end if;
  if coalesce(jsonb_typeof(p_payload->'items'),'')<>'array' then raise exception 'Cart must contain product variants.' using errcode='22023'; end if;
  if jsonb_array_length(p_payload->'items')<1 or jsonb_array_length(p_payload->'items')>30 then raise exception 'Cart is empty or too large.' using errcode='22023'; end if;
  if nullif(p_payload->>'delivery_provider_id','') is not null then
    v_provider_id:=(p_payload->>'delivery_provider_id')::uuid;
    select name into v_provider_name from public.monarc_delivery_providers where id=v_provider_id and active;
    if not found then raise exception 'Selected delivery company is unavailable.' using errcode='22023'; end if;
    select fee_dzd into v_fee from public.monarc_delivery_rates where provider_id=v_provider_id and wilaya_code=v_wilaya and delivery_type=v_delivery_type;
    if found then v_shipping_pending:=false; else v_fee:=0; v_shipping_pending:=true; end if;
  end if;
  -- Prices and stock availability are read from the database, never accepted from the browser.
  for v_input in
    select (x.value->>'variant_id')::uuid as variant_id,sum((x.value->>'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_payload->'items') as x(value)
    group by (x.value->>'variant_id')::uuid order by (x.value->>'variant_id')::uuid
  loop
    v_variant_id:=v_input.variant_id; v_qty:=v_input.quantity;
    if v_qty<1 or v_qty>50 then raise exception 'Invalid item quantity.' using errcode='22023'; end if;
    select v.id as variant_id,v.product_id,v.sku,v.size,v.color_fr,v.color_en,v.color_ar,
      coalesce(v.price_override_dzd,p.price_dzd) as unit_price,coalesce(p.purchase_cost_dzd,0) as unit_cost,
      p.name_fr,p.name_en,p.name_ar,coalesce(i.on_hand-i.reserved,0) as available
    into v_item
    from public.monarc_variants v join public.monarc_products p on p.id=v.product_id
    left join public.monarc_inventory i on i.variant_id=v.id
    where v.id=v_variant_id and v.active and p.status='published';
    if not found then raise exception 'One of the selected items is no longer available.' using errcode='22023'; end if;
    v_available:=v_item.available;
    if v_available<v_qty then raise exception 'Not enough available stock for SKU %.',v_item.sku using errcode='23514'; end if;
    v_subtotal:=v_subtotal+(v_item.unit_price*v_qty);
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'variant_id',v_item.variant_id,'product_id',v_item.product_id,'sku',v_item.sku,'size',v_item.size,
      'color_fr',v_item.color_fr,'color_en',v_item.color_en,'color_ar',v_item.color_ar,
      'unit_price_dzd',v_item.unit_price,'unit_cost_dzd',v_item.unit_cost,'quantity',v_qty,
      'product_name_fr',v_item.name_fr,'product_name_en',v_item.name_en,'product_name_ar',v_item.name_ar
    ));
  end loop;
  insert into public.monarc_customers as existing(full_name,phone,email,preferred_language)
    values(v_customer_name,v_phone,v_email,coalesce(p_payload->>'language','fr'))
    on conflict(phone) do update set full_name=excluded.full_name,email=coalesce(excluded.email,existing.email),preferred_language=excluded.preferred_language,updated_at=now()
  returning id into v_customer_id;
  v_order_no:='MN-'||to_char(timezone('Africa/Algiers',now()),'YYMMDD')||'-'||lpad(nextval('public.monarc_order_sequence')::text,6,'0');
  v_payment_status:=case when v_method='cod' then 'cod_due' else 'ccp_pending_contact' end;
  insert into public.monarc_orders(order_no,tracking_token,customer_id,status,payment_method,payment_status,provider_id,delivery_type,wilaya_code,commune,address,shipping_fee_dzd,shipping_quote_pending,subtotal_dzd,total_dzd,customer_note,privacy_consent)
  values(v_order_no,v_token,v_customer_id,v_order_status,v_method,v_payment_status,v_provider_id,v_delivery_type,v_wilaya,v_commune,v_address,v_fee,v_shipping_pending,v_subtotal,v_subtotal+v_fee,v_note,true)
  returning id into v_order_id;
  for v_input in select value from jsonb_array_elements(v_items)
  loop
    insert into public.monarc_order_items(order_id,product_id,variant_id,sku_snapshot,product_name_fr,product_name_en,product_name_ar,size_snapshot,color_fr_snapshot,color_en_snapshot,color_ar_snapshot,unit_price_dzd,cost_snapshot_dzd,quantity,line_total_dzd)
    values(v_order_id,(v_input.value->>'product_id')::uuid,(v_input.value->>'variant_id')::uuid,v_input.value->>'sku',v_input.value->>'product_name_fr',v_input.value->>'product_name_en',v_input.value->>'product_name_ar',v_input.value->>'size',coalesce(v_input.value->>'color_fr',''),coalesce(v_input.value->>'color_en',''),coalesce(v_input.value->>'color_ar',''),(v_input.value->>'unit_price_dzd')::integer,(v_input.value->>'unit_cost_dzd')::integer,(v_input.value->>'quantity')::integer,(v_input.value->>'unit_price_dzd')::integer*(v_input.value->>'quantity')::integer);
  end loop;
  insert into public.monarc_order_history(order_id,from_status,to_status,actor_id,actor_label,reason) values(v_order_id,null,v_order_status,null,'Customer','Order submitted online');
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values(null,'Customer','order_created','order',v_order_id,'Customer submitted online order',jsonb_build_object('order_no',v_order_no,'payment_method',v_method,'total_dzd',v_subtotal+v_fee));
  return jsonb_build_object('order_no',v_order_no,'tracking_token',v_token,'status',v_order_status,'payment_status',v_payment_status,'subtotal_dzd',v_subtotal,'shipping_fee_dzd',v_fee,'shipping_quote_pending',v_shipping_pending,'total_dzd',v_subtotal+v_fee);
end;
$$;

create or replace function public.monarc_track_order(p_order_no text,p_tracking_token uuid)
returns jsonb
language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'order_no',o.order_no,'status',o.status,'payment_status',o.payment_status,'created_at',o.created_at,'updated_at',o.updated_at,
    'provider_name',d.name,'tracking_number',o.tracking_number,'shipping_quote_pending',o.shipping_quote_pending,
    'history',coalesce((select jsonb_agg(jsonb_build_object('status',h.to_status,'date',h.created_at) order by h.created_at) from public.monarc_order_history h where h.order_id=o.id),'[]'::jsonb)
  )
  from public.monarc_orders o left join public.monarc_delivery_providers d on d.id=o.provider_id
  where o.order_no=p_order_no and o.tracking_token=p_tracking_token;
$$;

create or replace function public.monarc_change_order_status(p_order_id uuid,p_new_status text,p_reason text default '')
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_order public.monarc_orders%rowtype; v_item record; v_on_hand integer; v_reserved integer; v_role text;
begin
  perform public.monarc_require_roles(array['owner','manager','order_agent','warehouse']);
  select * into v_order from public.monarc_orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.' using errcode='P0002'; end if;
  if not (
    (v_order.status='pending_confirmation' and p_new_status in ('confirmed','rejected','cancelled')) or
    (v_order.status='confirmed' and p_new_status in ('preparing','cancelled')) or
    (v_order.status='preparing' and p_new_status in ('shipped','cancelled')) or
    (v_order.status='shipped' and p_new_status in ('delivered','delivery_failed')) or
    (v_order.status='delivery_failed' and p_new_status in ('returned','preparing')) or
    (v_order.status='delivered' and p_new_status='returned')
  ) then raise exception 'Invalid order status transition: % -> %.',v_order.status,p_new_status using errcode='22023'; end if;
  if p_new_status='confirmed' then
    -- Lock variants in stable order; reservation and status/audit writes commit atomically.
    for v_item in select variant_id,quantity from public.monarc_order_items where order_id=p_order_id order by variant_id loop
      select on_hand,reserved into v_on_hand,v_reserved from public.monarc_inventory where variant_id=v_item.variant_id for update;
      if not found or v_on_hand-v_reserved<v_item.quantity then raise exception 'Insufficient stock to confirm order %.',v_order.order_no using errcode='23514'; end if;
      update public.monarc_inventory set reserved=reserved+v_item.quantity,updated_at=now() where variant_id=v_item.variant_id;
      insert into public.monarc_inventory_movements(variant_id,order_id,delta_on_hand,delta_reserved,reason,actor_id) values(v_item.variant_id,p_order_id,0,v_item.quantity,'Order confirmed; stock reserved',(select auth.uid()));
    end loop;
  elsif p_new_status='cancelled' and v_order.status in ('confirmed','preparing') then
    for v_item in select variant_id,quantity from public.monarc_order_items where order_id=p_order_id order by variant_id loop
      select on_hand,reserved into v_on_hand,v_reserved from public.monarc_inventory where variant_id=v_item.variant_id for update;
      if not found or v_reserved<v_item.quantity then raise exception 'Reservation data mismatch for order %.',v_order.order_no using errcode='23514'; end if;
      update public.monarc_inventory set reserved=reserved-v_item.quantity,updated_at=now() where variant_id=v_item.variant_id;
      insert into public.monarc_inventory_movements(variant_id,order_id,delta_on_hand,delta_reserved,reason,actor_id) values(v_item.variant_id,p_order_id,0,-v_item.quantity,'Order cancelled; reservation released',(select auth.uid()));
    end loop;
  elsif p_new_status='delivered' and v_order.status='shipped' then
    for v_item in select variant_id,quantity from public.monarc_order_items where order_id=p_order_id order by variant_id loop
      select on_hand,reserved into v_on_hand,v_reserved from public.monarc_inventory where variant_id=v_item.variant_id for update;
      if not found or v_reserved<v_item.quantity or v_on_hand<v_item.quantity then raise exception 'Reserved stock mismatch for delivery of order %.',v_order.order_no using errcode='23514'; end if;
      update public.monarc_inventory set on_hand=on_hand-v_item.quantity,reserved=reserved-v_item.quantity,updated_at=now() where variant_id=v_item.variant_id;
      insert into public.monarc_inventory_movements(variant_id,order_id,delta_on_hand,delta_reserved,reason,actor_id) values(v_item.variant_id,p_order_id,-v_item.quantity,-v_item.quantity,'Delivered; inventory consumed. Payment remains separately tracked.',(select auth.uid()));
    end loop;
  elsif p_new_status='returned' and v_order.status='delivery_failed' then
    -- Failed parcel returned to warehouse: release reservation; inspection/restock is a separate stock adjustment.
    for v_item in select variant_id,quantity from public.monarc_order_items where order_id=p_order_id order by variant_id loop
      select on_hand,reserved into v_on_hand,v_reserved from public.monarc_inventory where variant_id=v_item.variant_id for update;
      if not found or v_reserved<v_item.quantity then raise exception 'Reservation data mismatch for returned order %.',v_order.order_no using errcode='23514'; end if;
      update public.monarc_inventory set reserved=reserved-v_item.quantity,updated_at=now() where variant_id=v_item.variant_id;
      insert into public.monarc_inventory_movements(variant_id,order_id,delta_on_hand,delta_reserved,reason,actor_id) values(v_item.variant_id,p_order_id,0,-v_item.quantity,'Failed delivery returned to warehouse; release reservation pending inspection.',(select auth.uid()));
    end loop;
  end if;
  update public.monarc_orders set status=p_new_status,updated_at=now(),confirmed_by=case when p_new_status='confirmed' then (select auth.uid()) else confirmed_by end where id=p_order_id;
  insert into public.monarc_order_history(order_id,from_status,to_status,actor_id,actor_label,reason) values(p_order_id,v_order.status,p_new_status,(select auth.uid()),'Staff',left(coalesce(p_reason,''),300));
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Staff','order_status_changed','order',p_order_id,left(coalesce(p_reason,''),300),jsonb_build_object('from',v_order.status,'to',p_new_status));
  return jsonb_build_object('order_id',p_order_id,'status',p_new_status);
end;
$$;

create or replace function public.monarc_adjust_inventory(p_variant_id uuid,p_delta integer,p_reason text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_on_hand integer; v_reserved integer;
begin
  perform public.monarc_require_roles(array['owner','manager','warehouse']);
  if p_delta=0 or length(trim(coalesce(p_reason,'')))<3 then raise exception 'Enter a non-zero change and a reason.' using errcode='22023'; end if;
  select on_hand,reserved into v_on_hand,v_reserved from public.monarc_inventory where variant_id=p_variant_id for update;
  if not found then raise exception 'Inventory variant not found.' using errcode='P0002'; end if;
  if v_on_hand+p_delta<v_reserved then raise exception 'Adjustment would reduce stock below the reserved quantity.' using errcode='23514'; end if;
  update public.monarc_inventory set on_hand=on_hand+p_delta,updated_at=now() where variant_id=p_variant_id;
  insert into public.monarc_inventory_movements(variant_id,delta_on_hand,delta_reserved,reason,actor_id) values(p_variant_id,p_delta,0,left(p_reason,300),(select auth.uid()));
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Staff','inventory_adjusted','variant',p_variant_id,left(p_reason,300),jsonb_build_object('delta',p_delta,'old_on_hand',v_on_hand,'new_on_hand',v_on_hand+p_delta));
  return jsonb_build_object('variant_id',p_variant_id,'on_hand',v_on_hand+p_delta,'reserved',v_reserved,'available',v_on_hand+p_delta-v_reserved);
end;
$$;

create or replace function public.monarc_save_product(p_product jsonb,p_variants jsonb)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_product_id uuid; v_variant_id uuid; v_existing boolean; v_has_variant_id boolean; v_line record; v_keep uuid[]:='{}'; v_images text[]; v_price integer;
begin
  perform public.monarc_require_roles(array['owner','manager']);
  if jsonb_typeof(p_variants)<>'array' or jsonb_array_length(p_variants)<1 then raise exception 'At least one product variant is required.' using errcode='22023'; end if;
  v_product_id:=coalesce(nullif(p_product->>'id','')::uuid,gen_random_uuid());
  v_images:=array(select jsonb_array_elements_text(coalesce(p_product->'images','[]'::jsonb)));
  v_price:=coalesce(nullif(p_product->>'price_dzd','')::integer,0);
  if v_price<0 or length(trim(coalesce(p_product->>'name_fr','')))<1 or length(trim(coalesce(p_product->>'name_en','')))<1 or length(trim(coalesce(p_product->>'name_ar','')))<1 then raise exception 'Product names and a valid price are required.' using errcode='22023'; end if;
  insert into public.monarc_products(id,category_slug,name_fr,name_en,name_ar,description_fr,description_en,description_ar,price_dzd,compare_at_dzd,purchase_cost_dzd,sku,images,tag_fr,status,featured,updated_at)
  values(v_product_id,p_product->>'category_slug',p_product->>'name_fr',p_product->>'name_en',p_product->>'name_ar',coalesce(p_product->>'description_fr',''),coalesce(p_product->>'description_en',''),coalesce(p_product->>'description_ar',''),v_price,nullif(p_product->>'compare_at_dzd','')::integer,nullif(p_product->>'purchase_cost_dzd','')::integer,nullif(p_product->>'sku',''),coalesce(v_images,'{}'),coalesce(p_product->>'tag_fr',''),coalesce(p_product->>'status','draft'),coalesce((p_product->>'featured')::boolean,false),now())
  on conflict(id) do update set category_slug=excluded.category_slug,name_fr=excluded.name_fr,name_en=excluded.name_en,name_ar=excluded.name_ar,description_fr=excluded.description_fr,description_en=excluded.description_en,description_ar=excluded.description_ar,price_dzd=excluded.price_dzd,compare_at_dzd=excluded.compare_at_dzd,purchase_cost_dzd=excluded.purchase_cost_dzd,sku=excluded.sku,images=excluded.images,tag_fr=excluded.tag_fr,status=excluded.status,featured=excluded.featured,updated_at=now();
  for v_line in select value from jsonb_array_elements(p_variants) loop
    v_has_variant_id:=nullif(v_line.value->>'id','') is not null;
    v_variant_id:=case when v_has_variant_id then (v_line.value->>'id')::uuid else gen_random_uuid() end;
    if length(trim(coalesce(v_line.value->>'sku','')))<1 or length(trim(coalesce(v_line.value->>'size','')))<1 then raise exception 'Each variant needs an SKU and size.' using errcode='22023'; end if;
    select exists(select 1 from public.monarc_variants where id=v_variant_id and product_id=v_product_id) into v_existing;
    if v_has_variant_id and not v_existing then raise exception 'Variant does not belong to this product.' using errcode='42501'; end if;
    insert into public.monarc_variants(id,product_id,sku,size,color_fr,color_en,color_ar,price_override_dzd,active,updated_at)
    values(v_variant_id,v_product_id,v_line.value->>'sku',v_line.value->>'size',coalesce(v_line.value->>'color_fr',''),coalesce(v_line.value->>'color_en',''),coalesce(v_line.value->>'color_ar',''),nullif(v_line.value->>'price_override_dzd','')::integer,coalesce((v_line.value->>'active')::boolean,true),now())
    on conflict(id) do update set sku=excluded.sku,size=excluded.size,color_fr=excluded.color_fr,color_en=excluded.color_en,color_ar=excluded.color_ar,price_override_dzd=excluded.price_override_dzd,active=excluded.active,updated_at=now();
    if not v_existing then
      insert into public.monarc_inventory(variant_id,on_hand,reserved,low_stock_threshold) values(v_variant_id,greatest(coalesce(nullif(v_line.value->>'initial_stock','')::integer,0),0),0,greatest(coalesce(nullif(v_line.value->>'low_stock_threshold','')::integer,3),0));
      if coalesce(nullif(v_line.value->>'initial_stock','')::integer,0)>0 then insert into public.monarc_inventory_movements(variant_id,delta_on_hand,reason,actor_id) values(v_variant_id,(v_line.value->>'initial_stock')::integer,'Initial stock when product/variant created',(select auth.uid())); end if;
    else
      update public.monarc_inventory set low_stock_threshold=greatest(coalesce(nullif(v_line.value->>'low_stock_threshold','')::integer,low_stock_threshold),0),updated_at=now() where variant_id=v_variant_id;
    end if;
    v_keep:=array_append(v_keep,v_variant_id);
  end loop;
  update public.monarc_variants set active=false,updated_at=now() where product_id=v_product_id and not(id=any(v_keep));
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason,details) values((select auth.uid()),'Staff','product_saved','product',v_product_id,'Product details updated',jsonb_build_object('status',p_product->>'status','variant_count',array_length(v_keep,1)));
  return jsonb_build_object('id',v_product_id,'message','Product saved');
end;
$$;

create or replace function public.monarc_archive_product(p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
begin
  perform public.monarc_require_roles(array['owner','manager']);
  update public.monarc_products set status='archived',updated_at=now() where id=p_product_id;
  if not found then raise exception 'Product not found.' using errcode='P0002'; end if;
  update public.monarc_variants set active=false,updated_at=now() where product_id=p_product_id;
  insert into public.monarc_audit_log(actor_id,actor_label,action,entity_type,entity_id,reason) values((select auth.uid()),'Staff','product_archived','product',p_product_id,'Product archived');
  return jsonb_build_object('id',p_product_id,'status','archived');
end;
$$;
