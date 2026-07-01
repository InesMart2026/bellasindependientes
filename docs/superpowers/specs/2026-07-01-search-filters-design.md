# Search + Filters para Categorías

## Problema
Las páginas de categorías (mujeres, hombres, trans) muestran todas las escorts sin forma de buscar o filtrar. Con ~50+ perfiles el usuario tiene que scrollear manualmente.

## Solución
Barra de búsqueda + filtros client-side sobre los datos ya cargados. Sin llamadas extra a Supabase.

## Componentes

### FilterBar (HTML inyectado en cada category page)
```
[ 🔍 Buscar por nombre o ubicación... ]
[ Edad min: ___ ] [ Edad max: ___ ] [ Ordenar: Más nuevas ▼ ]
```

### Funciones en gallery.js
- `filterEscorts(escorts, { search, edadMin, edadMax, sort })` → filtra y ordena in-memory
- Los inputs tienen event listeners `input` y `change` para filtrar en vivo
- Re-renderiza el grid con fade transition (clase CSS `filtering`)

## Flujo
1. Page loads → `fetchEscorts(categoria)` → `renderFilteredCards(data)`
2. User escribe/selecciona filtro → `filterEscorts(data, filtros)` → re-render
3. Sin estado persistente (se resetea al recargar)

## Edge Cases
- Búsqueda empty = mostrar todos
- Edad min > max = no mostrar nada (o mostrar mensaje "Sin resultados")
- Sin resultados = mensaje "No encontramos perfiles con esos filtros"
- Escorts sin edad = excluidas del filtro de edad, incluidas en search
