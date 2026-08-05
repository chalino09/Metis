import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607200001_inventory_replenishment_canonical_builder.sql", "utf8");
const workQueueMigration = readFileSync("supabase/migrations/202608050001_inventory_replenishment_work_queue.sql", "utf8");
const procurementUi = readFileSync("app/components/ProcurementModule.tsx", "utf8");

test("reabastecimiento reutiliza el constructor visual con selección múltiple", () => {
  assert.match(ui, /Configurar mínimos y máximos/);
  assert.match(ui, /search_inventory_replenishment_products/);
  assert.match(ui, /selectedProductIds/);
  assert.match(ui, /Agregar seleccionados/);
  assert.match(ui, />Cerrar<\/Button>/);
  assert.match(ui, /useDismissiblePopover\(productPickerRef, productPickerOpen/);
  assert.match(ui, /Aplicar a todas/);
  assert.match(ui, /Importar políticas/);
  assert.match(ui, /Guardar políticas/);
});

test("la solicitud de compra solo se muestra a quien puede crearla", () => {
  assert.match(ui, /const canPrepareRequisition = permissions\.includes\("create_procurement_requisitions"\)/);
  assert.match(ui, /\{canPrepareRequisition && <Button variant="secondary"[\s\S]*>Crear solicitud<\/Button>/);
});

test("la solicitud explica su alcance antes de crearla", () => {
  assert.match(ui, /const \[requisitionConfirmationOpen, setRequisitionConfirmationOpen\] = useState\(false\)/);
  assert.match(ui, /onClick=\{\(\) => setRequisitionConfirmationOpen\(true\)\}>Crear solicitud/);
  assert.match(ui, /title="Crear solicitud de compra"/);
  assert.match(ui, /La búsqueda y los filtros de productos no limitan esta solicitud\./);
  assert.match(ui, />Crear solicitud<\/Button>/);
  assert.match(ui, /Podrás abrir la solicitud en Compras para cotizar y decidir la compra después/);
});

test("reabastecimiento muestra una bandeja de seguimiento derivada de documentos operativos", () => {
  assert.match(ui, /list_inventory_replenishment_work_queue/);
  assert.match(ui, /className="bi-segmented inventory-replenishment-status-tabs"/);
  assert.match(ui, /aria-label="Seguimiento de faltantes"/);
  assert.match(ui, /Sin atender/);
  assert.match(ui, /En proceso/);
  assert.match(ui, /En tránsito/);
  assert.match(ui, /aria-pressed=\{workStatus === option\.value\}/);
  assert.match(ui, /Solicitud \{createdRequisition\.folio\} creada/);
  assert.match(ui, /\/satrapy\/compras\/abastecimiento\?solicitud=\$\{id\}/);
  assert.match(procurementUi, /searchParams\.get\("solicitud"\)/);
  assert.match(workQueueMigration, /create or replace function public\.list_inventory_replenishment_work_queue/);
  assert.match(workQueueMigration, /public\.inventory_transfers/);
  assert.match(workQueueMigration, /public\.procurement_requisitions/);
  assert.match(workQueueMigration, /public\.purchase_orders/);
  assert.match(workQueueMigration, /when transfer_status = 'in_transit' then 'in_transit'/);
});

test("la creación bloquea duplicados de solicitudes en borrador desde el servidor", () => {
  assert.match(workQueueMigration, /pg_advisory_xact_lock/);
  assert.match(workQueueMigration, /r\.status in \('draft','quoting','recommended'\)/);
  assert.match(workQueueMigration, /No hay faltantes nuevos para convertir en necesidad/);
});

test("la configuración queda como acción secundaria y no desplaza las sugerencias", () => {
  assert.match(ui, /const \[policyEditorOpen, setPolicyEditorOpen\] = useState\(false\)/);
  assert.match(ui, /\{canManage && <Button variant="secondary" onClick=\{\(\) => setPolicyEditorOpen\(true\)\}>Configurar mínimos y máximos/);
  assert.match(ui, /<Drawer\s+open=\{policyEditorOpen\}[\s\S]*title="Configurar mínimos y máximos"/);
  assert.match(ui, /Define mínimos y máximos por ubicación\. Esta configuración no mueve inventario ni crea órdenes de compra\./);
  assert.ok(ui.lastIndexOf("DataToolbar search={search}") > ui.indexOf('className="inventory-replenishment-drawer"'));
});

test("el constructor guarda identidades canónicas en un lote server-side", () => {
  assert.match(ui, /configure_inventory_replenishment_policy_items/);
  assert.match(ui, /product_id: line\.product_id/);
  assert.match(migration, /jsonb_to_recordset\(p_lines\) input\([\s\S]*product_id uuid/);
  assert.match(migration, /v_received > 500/);
  assert.match(migration, /on conflict \(location_id, product_id\) do update/);
  assert.doesNotMatch(migration, /for\s+\w+\s+in/i);
});

test("la mejora permanece aislada de inventario, compras y costos", () => {
  assert.doesNotMatch(migration, /insert into public\.inventory_ledger/i);
  assert.doesNotMatch(migration, /update public\.inventory_balances/i);
  assert.doesNotMatch(migration, /insert into public\.inventory_transfers/i);
  assert.doesNotMatch(migration, /purchase_orders|purchase_receipts|product_costs/i);
});
