-- =====================================================================
-- ESPIX · Script que crea la base de datos en Supabase
-- Cómo usarlo: Supabase → SQL Editor → New query → pegar todo → Run
-- Se puede volver a correr sin perder datos (usa "if not exists").
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Proveedores: a quién se le compra cada material
-- ---------------------------------------------------------------------
create table if not exists public.proveedores (
  id          bigint generated always as identity primary key,
  nombre      text not null unique,
  contacto    text,                       -- persona con la que se coordina
  whatsapp    text,                       -- número con código de país, solo dígitos (ej. 51987654321)
  correo      text,
  creado_en   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Catálogo de materiales con el precio acordado con cada proveedor (HU1)
-- ---------------------------------------------------------------------
create table if not exists public.materiales (
  id               bigint generated always as identity primary key,
  codigo           text not null unique,               -- ej. AC-001
  nombre           text not null,
  especificacion   text,                               -- medidas, espesor, acabado
  unidad           text not null default 'pieza',      -- pieza, m, m2, kg, litro, plancha
  proveedor_id     bigint not null references public.proveedores(id),
  precio_unitario  numeric(12,2) not null check (precio_unitario > 0),   -- precio acordado (USD)
  merma_pct        numeric(5,2)  not null default 5 check (merma_pct >= 0 and merma_pct < 100),
  activo           boolean not null default true,
  actualizado_en   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Clientes
-- ---------------------------------------------------------------------
create table if not exists public.clientes (
  id         bigint generated always as identity primary key,
  nombre     text not null unique,
  ruc        text,
  contacto   text,
  correo     text,
  creado_en  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. Cotizaciones (cabecera). También guarda las plantillas (HU4).
-- ---------------------------------------------------------------------
create table if not exists public.cotizaciones (
  id                bigint generated always as identity primary key,
  codigo            text unique,                       -- PRE-0001, lo pone la base
  cliente_id        bigint references public.clientes(id),
  proyecto          text not null,
  descripcion       text,
  fecha             date not null default current_date,  -- día en que se pidió la cotización
  margen_pct        numeric(5,2) not null default 25 check (margen_pct >= 0 and margen_pct < 500),
  estado            text not null default 'Borrador'
                    check (estado in ('Borrador','Enviada','Aprobada','Perdida','Cancelada por demora')),
  es_plantilla      boolean not null default false,
  copia_de          bigint references public.cotizaciones(id),   -- versión anterior, si es una copia
  fecha_envio       date,                              -- la pone la base al pasar a "Enviada"
  fecha_aprobacion  date,                              -- la pone la base al pasar a "Aprobada"
  creado_en         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. Detalle: materiales y cantidades de cada cotización
-- precio_unitario y merma_pct se copian del catálogo al guardar (precio firme)
-- ---------------------------------------------------------------------
create table if not exists public.cotizacion_detalle (
  id               bigint generated always as identity primary key,
  cotizacion_id    bigint not null references public.cotizaciones(id) on delete cascade,
  material_id      bigint not null references public.materiales(id),
  cantidad         numeric(12,2) not null check (cantidad > 0),
  precio_unitario  numeric(12,2),
  merma_pct        numeric(5,2),
  subtotal         numeric(14,2) generated always as
                   (round(cantidad * precio_unitario * (1 + merma_pct / 100), 2)) stored
);

-- ---------------------------------------------------------------------
-- 6. Cotizaciones históricas hechas a mano (dataset_cotizaciones_manuales.xlsx)
-- Los nombres de columna son iguales a los del Excel para poder importar el CSV.
-- Se guardan como texto y la vista de indicadores los convierte (acepta $ y comas).
-- ---------------------------------------------------------------------
create table if not exists public.cotizaciones_historicas (
  "ID_Cotizacion"                text primary key,
  "Fecha_Solicitud"              text,
  "Tipo_Servicio"                text,
  "Nivel_Complejidad"            text,
  "Valor_Cotizado_USD"           text,
  "Horas_Hombre_Cotizacion"      text,
  "Lead_Time_Dias"               text,
  "Numero_Iteraciones_Internas"  text,
  "Error_Calculo_Detectado"      text,
  "Descuento_Manual_Aplicado_%"  text,
  "Margen_Estimado_Inicial_%"    text,
  "Margen_Real_Final_%"          text,
  "Fuga_Margen_%"                text,
  "Estado_Cotizacion"            text,
  "Motivo_Perdida"               text
);

-- ---------------------------------------------------------------------
-- 7. Umbrales de los indicadores (sección 4.1 del informe)
-- ---------------------------------------------------------------------
create table if not exists public.parametros (
  id                    integer primary key default 1 check (id = 1),
  umbral_cancelacion    numeric(5,4) not null default 0.25,   -- 25 %
  umbral_error          numeric(5,4) not null default 0.30,   -- 30 %
  umbral_lead_time      numeric(6,2) not null default 5,      -- días
  umbral_fuga_margen    numeric(6,2) not null default 7       -- puntos porcentuales
);
insert into public.parametros (id) values (1) on conflict (id) do nothing;

-- =====================================================================
-- REGLA DE NEGOCIO
--   subtotal      = cantidad × precio acordado × (1 + merma %)
--   costo directo = suma de subtotales
--   precio final  = costo directo × (1 + margen %)
-- Una cotización Enviada o Aprobada tiene precio firme: ya no se le
-- pueden cambiar materiales, cantidades ni margen. Para cambiar algo
-- se crea una nueva versión (función duplicar_cotizacion).
-- =====================================================================

-- 8. Código PRE-0001 automático
create or replace function public.espix_codigo() returns trigger
language plpgsql as $$
begin
  if new.codigo is null then
    new.codigo := case when new.es_plantilla then 'PLA-' else 'PRE-' end || lpad(new.id::text, 4, '0');
  end if;
  return new;
end $$;
drop trigger if exists t_codigo on public.cotizaciones;
create trigger t_codigo before insert on public.cotizaciones
  for each row execute function public.espix_codigo();

-- 9. Copia el precio y la merma del catálogo al detalle y bloquea cambios con precio firme
create or replace function public.espix_detalle() returns trigger
language plpgsql as $$
declare v_estado text;
begin
  select estado into v_estado from public.cotizaciones
   where id = coalesce(new.cotizacion_id, old.cotizacion_id);
  if v_estado in ('Enviada','Aprobada') then
    raise exception 'La cotización ya fue % y tiene precio firme. Crea una nueva versión para cambiarla.', lower(v_estado);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.precio_unitario is null or new.merma_pct is null then
    select coalesce(new.precio_unitario, m.precio_unitario), coalesce(new.merma_pct, m.merma_pct)
      into new.precio_unitario, new.merma_pct
      from public.materiales m where m.id = new.material_id;
  end if;
  return new;
end $$;
drop trigger if exists t_detalle on public.cotizacion_detalle;
create trigger t_detalle before insert or update or delete on public.cotizacion_detalle
  for each row execute function public.espix_detalle();

-- 10. Fechas de envío y aprobación; bloquea el margen con precio firme
create or replace function public.espix_estado() returns trigger
language plpgsql as $$
begin
  if old.estado in ('Enviada','Aprobada') and new.margen_pct <> old.margen_pct then
    raise exception 'La cotización tiene precio firme: el margen ya no se puede cambiar.';
  end if;
  if new.estado = 'Enviada' and old.estado <> 'Enviada' and new.fecha_envio is null then
    new.fecha_envio := current_date;
  end if;
  if new.estado = 'Aprobada' and old.estado <> 'Aprobada' then
    new.fecha_aprobacion := current_date;
    if new.fecha_envio is null then new.fecha_envio := current_date; end if;
  end if;
  return new;
end $$;
drop trigger if exists t_estado on public.cotizaciones;
create trigger t_estado before update on public.cotizaciones
  for each row execute function public.espix_estado();

-- 11. Actualiza la fecha de cambio de precio del catálogo
create or replace function public.espix_material_fecha() returns trigger
language plpgsql as $$
begin new.actualizado_en := now(); return new; end $$;
drop trigger if exists t_material_fecha on public.materiales;
create trigger t_material_fecha before update on public.materiales
  for each row execute function public.espix_material_fecha();

-- 12. Nueva versión de una cotización o presupuesto desde una plantilla (HU4 y HU10)
-- Copia materiales y cantidades con los precios ACTUALES del catálogo.
create or replace function public.duplicar_cotizacion(p_id bigint, p_proyecto text default null)
returns bigint language plpgsql as $$
declare v_nuevo bigint;
begin
  insert into public.cotizaciones (cliente_id, proyecto, descripcion, margen_pct, copia_de)
  select cliente_id, coalesce(p_proyecto, proyecto), descripcion, margen_pct, id
    from public.cotizaciones where id = p_id
  returning id into v_nuevo;
  if v_nuevo is null then raise exception 'No existe la cotización %', p_id; end if;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
  select v_nuevo, material_id, cantidad from public.cotizacion_detalle where cotizacion_id = p_id;
  return v_nuevo;
end $$;

-- =====================================================================
-- VISTAS (las lee la página web y el tablero)
-- =====================================================================

-- 13. Totales de cada cotización según la regla de negocio
create or replace view public.cotizaciones_totales with (security_invoker = true) as
select
  c.id, c.codigo, c.fecha, c.proyecto, c.descripcion, c.estado, c.es_plantilla, c.copia_de,
  c.cliente_id, cl.nombre as cliente,
  c.margen_pct, c.fecha_envio, c.fecha_aprobacion,
  (c.fecha_envio - c.fecha)                                                as lead_time_dias,
  count(d.id)                                                              as materiales,
  coalesce(sum(round(d.cantidad * d.precio_unitario, 2)), 0)               as costo_materiales,
  coalesce(sum(d.subtotal), 0) - coalesce(sum(round(d.cantidad * d.precio_unitario, 2)), 0) as costo_merma,
  coalesce(sum(d.subtotal), 0)                                             as costo_directo,
  round(coalesce(sum(d.subtotal), 0) * c.margen_pct / 100, 2)              as ganancia,
  round(coalesce(sum(d.subtotal), 0) * (1 + c.margen_pct / 100), 2)        as precio_final
from public.cotizaciones c
left join public.clientes cl on cl.id = c.cliente_id
left join public.cotizacion_detalle d on d.cotizacion_id = c.id
group by c.id, cl.nombre;

-- 14. Lista de materiales (BOM) de las cotizaciones aprobadas, por proveedor (HU3 y HU5)
create or replace view public.lista_materiales with (security_invoker = true) as
select
  c.id as cotizacion_id, c.codigo, c.proyecto,
  p.id as proveedor_id, p.nombre as proveedor, p.contacto, p.whatsapp, p.correo,
  m.codigo as material_codigo, m.nombre as material, m.especificacion, m.unidad,
  sum(d.cantidad)                                             as cantidad_proyecto,
  ceil(sum(d.cantidad * (1 + d.merma_pct / 100)))             as cantidad_a_comprar,
  max(d.precio_unitario)                                      as precio_unitario,
  round(ceil(sum(d.cantidad * (1 + d.merma_pct / 100))) * max(d.precio_unitario), 2) as costo_compra
from public.cotizaciones c
join public.cotizacion_detalle d on d.cotizacion_id = c.id
join public.materiales m on m.id = d.material_id
join public.proveedores p on p.id = m.proveedor_id
where c.estado = 'Aprobada'
group by c.id, p.id, m.id
order by c.id, p.nombre, m.codigo;

-- 15. Conversión de texto a número y a fecha para el histórico
create or replace function public.espix_num(t text) returns numeric
language plpgsql immutable as $$
declare s text := regexp_replace(coalesce(t, ''), '[^0-9,.\-]', '', 'g');
begin
  if s = '' then return null; end if;
  if s like '%,%' and s like '%.%' then s := replace(s, ',', '');      -- 68,497.82
  elsif s like '%,%' then s := replace(s, ',', '.');                   -- 15,0
  end if;
  return s::numeric;
exception when others then return null;
end $$;

create or replace function public.espix_fecha(t text) returns date
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  if t ~ '^\d{4}-\d{2}-\d{2}' then return left(t, 10)::date; end if;  -- 2024-01-15
  return to_date(t, 'DD/MM/YYYY');                                     -- 15/01/2024
exception when others then return null;
end $$;

-- 16. Indicadores por mes (sección 4.1). Los porcentajes de un período se
-- calculan sumando numeradores y denominadores, no promediando meses.
create or replace view public.indicadores_mes with (security_invoker = true) as
with h as (
  select
    to_char(public.espix_fecha("Fecha_Solicitud"), 'YYYY-MM')                    as mes,
    lower(btrim("Estado_Cotizacion")) = 'cancelada por demora'                  as cancelada_demora,
    lower(translate(btrim("Error_Calculo_Detectado"), 'íÍ', 'iI')) in ('si','1','true') as con_error,
    public.espix_num("Lead_Time_Dias")                                          as lead_time,
    coalesce(public.espix_num("Fuga_Margen_%"),
             public.espix_num("Margen_Estimado_Inicial_%") - public.espix_num("Margen_Real_Final_%")) as fuga
  from public.cotizaciones_historicas
  where public.espix_fecha("Fecha_Solicitud") is not null
)
select
  h.mes,
  count(*)                                                             as total_cotizaciones,
  count(*) filter (where h.cancelada_demora)                           as canceladas_demora,
  round(count(*) filter (where h.cancelada_demora)::numeric / count(*), 4) as tasa_cancelacion_demora,
  count(*) filter (where h.con_error)                                  as con_error_calculo,
  round(count(*) filter (where h.con_error)::numeric / count(*), 4)    as tasa_error_calculo,
  count(h.lead_time)                                                   as con_lead_time,
  round(sum(h.lead_time), 2)                                           as suma_lead_time,
  round(avg(h.lead_time), 2)                                           as lead_time_promedio,
  count(h.fuga)                                                        as con_fuga,
  round(sum(h.fuga), 2)                                                as suma_fuga_margen,
  round(avg(h.fuga), 2)                                                as fuga_margen_media,
  max(p.umbral_cancelacion) as umbral_cancelacion, max(p.umbral_error) as umbral_error,
  max(p.umbral_lead_time)   as umbral_lead_time,   max(p.umbral_fuga_margen) as umbral_fuga_margen
from h cross join public.parametros p
group by h.mes
order by h.mes;

-- =====================================================================
-- PERMISOS (Row Level Security)
-- La página usa la llave pública (anon). Puede leer, registrar y editar,
-- pero no borrar proveedores, materiales ni cotizaciones enviadas.
-- =====================================================================
alter table public.proveedores             enable row level security;
alter table public.materiales              enable row level security;
alter table public.clientes                enable row level security;
alter table public.cotizaciones            enable row level security;
alter table public.cotizacion_detalle      enable row level security;
alter table public.cotizaciones_historicas enable row level security;
alter table public.parametros              enable row level security;

do $$
declare t text;
begin
  foreach t in array array['proveedores','materiales','clientes','cotizaciones','cotizacion_detalle'] loop
    execute format('drop policy if exists "leer" on public.%I', t);
    execute format('drop policy if exists "registrar" on public.%I', t);
    execute format('drop policy if exists "editar" on public.%I', t);
    execute format('create policy "leer" on public.%I for select to anon, authenticated using (true)', t);
    execute format('create policy "registrar" on public.%I for insert to anon, authenticated with check (true)', t);
    execute format('create policy "editar" on public.%I for update to anon, authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop policy if exists "quitar lineas" on public.cotizacion_detalle;
create policy "quitar lineas" on public.cotizacion_detalle for delete to anon, authenticated using (true);
drop policy if exists "borrar borradores" on public.cotizaciones;
create policy "borrar borradores" on public.cotizaciones for delete to anon, authenticated
  using (estado = 'Borrador' or es_plantilla);

drop policy if exists "leer" on public.cotizaciones_historicas;
create policy "leer" on public.cotizaciones_historicas for select to anon, authenticated using (true);
drop policy if exists "leer" on public.parametros;
create policy "leer" on public.parametros for select to anon, authenticated using (true);

grant select on public.cotizaciones_totales, public.lista_materiales, public.indicadores_mes to anon, authenticated;
grant execute on function public.duplicar_cotizacion(bigint, text) to anon, authenticated;

-- =====================================================================
-- DATOS DE EJEMPLO (solo se cargan si la base está vacía)
-- Puedes cambiarlos o borrarlos desde Table Editor.
-- =====================================================================
do $$
declare
  p1 bigint; p2 bigint; p3 bigint; p4 bigint;
  c1 bigint; c2 bigint; c3 bigint;
  q bigint;
begin
  if exists (select 1 from public.proveedores) then return; end if;

  insert into public.proveedores (nombre, contacto, whatsapp, correo) values
    ('Acero Norte',            'Jorge Salas',  '51987654321', 'ventas@aceronorte.example')    returning id into p1;
  insert into public.proveedores (nombre, contacto, whatsapp, correo) values
    ('Fijaciones del Centro',  'Rosa Medina',  '51987654322', 'pedidos@fijaciones.example')   returning id into p2;
  insert into public.proveedores (nombre, contacto, whatsapp, correo) values
    ('Recubrimientos Lima',    'Carlos Vega',  '51987654323', 'ventas@recubrimientos.example') returning id into p3;
  insert into public.proveedores (nombre, contacto, whatsapp, correo) values
    ('Maderas y Tableros Sur', 'Ana Paredes',  '51987654324', 'cotiza@tablerossur.example')   returning id into p4;

  insert into public.materiales (codigo, nombre, especificacion, unidad, proveedor_id, precio_unitario, merma_pct) values
    ('AC-001', 'Lámina de acero A36',       'Espesor 3 mm · 1,22 × 2,44 m', 'plancha', p1, 48.00,  8),
    ('AC-014', 'Perfil tubular cuadrado',   '40 × 40 mm · largo 6 m',       'pieza',   p1, 12.00,  5),
    ('AC-020', 'Soldadura E6013',           'Electrodo 1/8"',               'kg',      p1,  4.20, 10),
    ('FI-008', 'Tornillo hexagonal M10',    'Acero galvanizado · 30 mm',    'pieza',   p2,  0.35,  3),
    ('FI-015', 'Bisagra cazoleta 35 mm',    'Cierre suave',                 'pieza',   p2,  1.20,  2),
    ('FI-022', 'Riel telescópico',          '45 cm · par',                  'par',     p2,  6.80,  0),
    ('RC-003', 'Pintura epóxica industrial','Acabado gris · uso industrial','litro',   p3,  9.50, 10),
    ('RC-007', 'Thinner acrílico',          'Para dilución',                'litro',   p3,  5.50, 10),
    ('MT-001', 'Tablero melamina blanca',   '18 mm · 2,14 × 2,44 m',        'plancha', p4, 52.00, 12),
    ('MT-004', 'Tablero MDF crudo',         '18 mm · 2,44 × 1,83 m',        'plancha', p4, 38.00, 12),
    ('MT-010', 'Canto PVC blanco',          '22 × 0,45 mm',                 'm',       p4,  0.60, 10),
    ('MT-015', 'Vidrio templado',           '6 mm · incoloro',              'm2',      p4, 45.00,  5);

  insert into public.clientes (nombre, ruc, contacto, correo) values
    ('Industrias del Norte', '20111111111', 'Lucía Ramos',  'compras@industriasnorte.example') returning id into c1;
  insert into public.clientes (nombre, ruc, contacto, correo) values
    ('Constructora Andina',  '20222222222', 'Pedro Huamán', 'logistica@andina.example')        returning id into c2;
  insert into public.clientes (nombre, ruc, contacto, correo) values
    ('Oficinas Prisma',      '20333333333', 'Sofía León',   'admin@prisma.example')            returning id into c3;

  -- Plantilla: escritorio operativo
  insert into public.cotizaciones (proyecto, descripcion, margen_pct, es_plantilla)
    values ('Escritorio operativo 1,20 m', 'Escritorio en melamina blanca con estructura metálica', 30, true) returning id into q;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
    select q, id, x.cant from public.materiales m
    join (values ('MT-001', 1), ('AC-014', 2), ('MT-010', 6), ('FI-008', 12), ('RC-003', 0.5)) x(cod, cant) on x.cod = m.codigo;

  -- Plantilla: mesa de ensamble
  insert into public.cotizaciones (proyecto, descripcion, margen_pct, es_plantilla)
    values ('Mesa de ensamble industrial', 'Mesa de 2,40 × 1,20 m con estructura tubular y acabado epóxico', 25, true) returning id into q;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
    select q, id, x.cant from public.materiales m
    join (values ('AC-001', 2), ('AC-014', 6), ('FI-008', 40), ('RC-003', 4), ('AC-020', 2)) x(cod, cant) on x.cod = m.codigo;

  -- Cotización aprobada (genera lista de materiales)
  insert into public.cotizaciones (cliente_id, proyecto, descripcion, margen_pct, fecha)
    values (c1, 'Mesa de ensamble industrial ×4', 'Cuatro mesas de 2,40 × 1,20 m, acabado epóxico gris', 25, current_date - 6) returning id into q;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
    select q, id, x.cant from public.materiales m
    join (values ('AC-001', 8), ('AC-014', 24), ('FI-008', 160), ('RC-003', 16), ('AC-020', 8)) x(cod, cant) on x.cod = m.codigo;
  update public.cotizaciones set estado = 'Enviada' where id = q;
  update public.cotizaciones set fecha_envio = current_date - 5 where id = q;
  update public.cotizaciones set estado = 'Aprobada' where id = q;

  -- Cotización enviada
  insert into public.cotizaciones (cliente_id, proyecto, descripcion, margen_pct, fecha)
    values (c3, 'Estaciones de trabajo ×6', 'Seis escritorios operativos con cajonera', 30, current_date - 2) returning id into q;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
    select q, id, x.cant from public.materiales m
    join (values ('MT-001', 6), ('AC-014', 12), ('MT-010', 36), ('FI-008', 72), ('FI-022', 6), ('RC-003', 3)) x(cod, cant) on x.cod = m.codigo;
  update public.cotizaciones set estado = 'Enviada' where id = q;

  -- Borrador
  insert into public.cotizaciones (cliente_id, proyecto, descripcion, margen_pct)
    values (c2, 'Mostrador de recepción', 'Mostrador en MDF con tapa de vidrio templado', 28) returning id into q;
  insert into public.cotizacion_detalle (cotizacion_id, material_id, cantidad)
    select q, id, x.cant from public.materiales m
    join (values ('MT-004', 3), ('MT-015', 1.5), ('MT-010', 12), ('FI-015', 4)) x(cod, cant) on x.cod = m.codigo;
end $$;
