# ESPIX

**ERP de Simplificación de Presupuestos.** Conectamos tus proveedores. Simplificamos presupuestos.

Herramienta web para empresas que fabrican bajo pedido (carpintería, mobiliario, estructuras metálicas). Permite armar presupuestos con un catálogo de materiales a precios acordados con los proveedores, calcula el precio final sin errores de fórmula y, al aprobarse el pedido, genera la lista de materiales separada por proveedor.

## Archivos

- `index.html`: la página web. Tiene 7 pantallas: Inicio, Proveedores, Materiales, Presupuestos, Cotizaciones anteriores, Lista de materiales y Tablero. Lee y escribe en Supabase.
- `base_de_datos.sql`: crea en Supabase las tablas, la regla de negocio, las vistas, los permisos y algunos datos de ejemplo.

## Modelo de datos

| Tabla o vista | Qué guarda |
| --- | --- |
| `proveedores` | A quién se le compra y cómo contactarlo (WhatsApp, correo) |
| `materiales` | Catálogo con el precio acordado con cada proveedor y su % de merma |
| `clientes` | Empresas a las que se les cotiza |
| `cotizaciones` | Cabecera de cada presupuesto: cliente, proyecto, margen y estado. También guarda las plantillas |
| `cotizacion_detalle` | Materiales y cantidades de cada presupuesto, con el precio copiado del catálogo al guardar |
| `cotizaciones_historicas` | Las cotizaciones hechas a mano antes de ESPIX (dataset_cotizaciones_manuales.xlsx) |
| `parametros` | Umbrales de los indicadores |
| `cotizaciones_totales` (vista) | Costo directo, ganancia y precio final de cada cotización |
| `lista_materiales` (vista) | Lista de materiales (BOM) de las cotizaciones aprobadas, por proveedor |
| `indicadores_mes` (vista) | Los 4 indicadores del negocio por mes |

## Regla de negocio

```
subtotal       = cantidad × precio acordado × (1 + merma %)
costo directo  = suma de subtotales
precio final   = costo directo × (1 + margen %)
```

La regla se calcula en la base de datos, así que da el mismo resultado sin importar desde dónde se registre la cotización. Además:

- **Precio firme:** cuando una cotización pasa a *Enviada* o *Aprobada*, la base ya no deja cambiar materiales, cantidades ni margen. Si el cliente pide un cambio, se crea una nueva versión con los precios actuales del catálogo.
- **Lista de materiales automática:** al pasar a *Aprobada*, la cotización aparece en la vista `lista_materiales` con la cantidad a comprar (con merma, redondeada hacia arriba), agrupada por proveedor y lista para enviar por WhatsApp o correo.

## Indicadores (vista `indicadores_mes`)

| Indicador | Cálculo | Umbral |
| --- | --- | --- |
| Tasa de cancelación por demora | Cotizaciones "Cancelada por demora" ÷ total del mes | 25 % |
| Tasa de error de cálculo | Cotizaciones con error detectado ÷ total del mes | 30 % |
| Lead time promedio | Suma de días de respuesta ÷ total del mes | 5 días |
| Fuga de margen media | Suma de (margen inicial − margen final) ÷ total del mes | 7 p.p. |

## Cómo ponerlo en marcha

**1. Supabase (10 min)**
1. supabase.com → **New project** → nombre `espix` → región South America (São Paulo).
2. **SQL Editor → New query** → pega todo `base_de_datos.sql` → **Run**.
3. **Table Editor → cotizaciones_historicas → Insert → Import data from CSV** → sube el dataset guardado como CSV (los nombres de las columnas deben ser iguales a los del Excel).
4. Copia la *Project URL* (Project Settings → Data API) y la llave pública *anon* (Project Settings → API Keys). Nunca uses la llave *secret* / *service_role*.

**2. Conectar la página (2 min)**
Abre `index.html` con el Bloc de notas y reemplaza `PEGA_AQUI_TU_PROJECT_URL` y `PEGA_AQUI_TU_LLAVE_PUBLICA` (deja las comillas). Sin estos datos, la página funciona en **modo demostración** con datos de ejemplo que no se guardan.

**3. GitHub Pages (5 min)**
1. github.com → **New repository** → `espix` → Public.
2. **Add file → Upload files** → sube `index.html`, `base_de_datos.sql` y `README.md` → Commit.
3. **Settings → Pages** → Deploy from a branch → `main` / `(root)` → Save. En 1 o 2 minutos aparece la dirección pública.

---
Curso Laboratorio Digital II · UPC · 2026-2
