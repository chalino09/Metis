import assert from "node:assert/strict";
import test from "node:test";
import { groupConsecutiveCartChanges, isPosCartDecreaseAlreadySatisfied, isPosCartRevisionConflict, percentile95, rebasePosCartQuantityDelta, type PosQueuedCartChange } from "../app/lib/pos-resilience.ts";

function change(id: string, productId: string, quantityDelta: number, requestId = id): PosQueuedCartChange<{ name: string }> {
  return {
    id,
    requestId,
    companyId: "company-1",
    cartId: "cart-1",
    productId,
    quantityDelta,
    product: { name: productId },
    expectedUnitTotal: 116,
    createdAt: "2026-08-07T12:00:00.000Z",
  };
}

test("agrupa lecturas consecutivas del mismo producto sin reordenarlas", () => {
  const groups = groupConsecutiveCartChanges([
    change("change-1", "product-a", 1, "request-1"),
    change("change-2", "product-a", 1, "request-1"),
    change("request-3", "product-b", 1),
    change("request-4", "product-a", -1),
  ]);
  assert.deepEqual(groups.map((group) => ({ ids: group.ids, product: group.productId, delta: group.quantityDelta })), [
    { ids: ["change-1", "change-2"], product: "product-a", delta: 2 },
    { ids: ["request-3"], product: "product-b", delta: 1 },
    { ids: ["request-4"], product: "product-a", delta: -1 },
  ]);
  assert.equal(groups[0].requestId, "request-1");
});

test("conserva un lote neto en cero para retirarlo de la cola sin enviarlo", () => {
  const [group] = groupConsecutiveCartChanges([change("change-1", "product-a", 1, "request-1"), change("change-2", "product-a", -1, "request-1")]);
  assert.equal(group.quantityDelta, 0);
  assert.deepEqual(group.ids, ["change-1", "change-2"]);
});

test("no amplía un lote ya enviado con lecturas posteriores", () => {
  const groups = groupConsecutiveCartChanges([
    change("change-1", "product-a", 2, "request-1"),
    change("change-2", "product-a", 1, "request-2"),
  ]);
  assert.deepEqual(groups.map((group) => ({ requestId: group.requestId, delta: group.quantityDelta })), [
    { requestId: "request-1", delta: 2 },
    { requestId: "request-2", delta: 1 },
  ]);
});

test("calcula p95 con rango nearest-rank", () => {
  assert.equal(percentile95([]), null);
  assert.equal(percentile95([100]), 100);
  assert.equal(percentile95(Array.from({ length: 20 }, (_, index) => index + 1)), 19);
});

test("reconoce el conflicto de revisión del carrito", () => {
  assert.equal(isPosCartRevisionConflict("El carrito cambió en otra operación; actualiza la vista."), true);
  assert.equal(isPosCartRevisionConflict("No hay existencia disponible para esa cantidad."), false);
});

test("reaplica la intención absoluta después de un conflicto", () => {
  assert.equal(rebasePosCartQuantityDelta(1, -1, 2), -2, "mantiene la intención de eliminar aunque el servidor tenga dos");
  assert.equal(rebasePosCartQuantityDelta(1, -1, 0), 0, "no repite una eliminación ya aplicada");
  assert.equal(rebasePosCartQuantityDelta(2, 1, 1), 2, "lleva la cantidad autoritativa al valor que vio el cajero");
});

test("retira decrementos pendientes cuando el producto ya está eliminado", () => {
  assert.equal(isPosCartDecreaseAlreadySatisfied(-1, 0), true);
  assert.equal(isPosCartDecreaseAlreadySatisfied(-3, 0), true);
  assert.equal(isPosCartDecreaseAlreadySatisfied(-1, 2), false);
  assert.equal(isPosCartDecreaseAlreadySatisfied(1, 0), false);
});
