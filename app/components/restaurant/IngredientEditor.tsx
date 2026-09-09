"use client";

import { useEffect, useRef, useState } from "react";
import { Package, ArrowRight, Check, AlertCircle } from "lucide-react";
import { Field, Modal } from "@/app/components/ui/primitives";
import { OperationalButton as Button, OperationalInput as Input } from "@/app/components/reui/operational-controls";
import { getSupabaseClient } from "@/app/lib/supabase";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import {
  categories,
  canonicalUnit,
  money,
  numberValue,
  purchaseFactor,
  restaurantError,
  unitLabel,
  type ComponentOption,
  type StudioContext,
} from "@/app/lib/restaurant/studio";
import { Select } from "./controls";
import styles from "./restaurant.module.css";

type Props = {
  companyId: string;
  permissions: string[];
  productId?: string;
  initialName?: string;
  onClose: () => void;
  onSaved: (item: ComponentOption) => void;
};
export function IngredientEditor({
  companyId,
  permissions,
  productId,
  initialName = "",
  onClose,
  onSaved,
}: Props) {
  const [context, setContext] = useState<StudioContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [form, setForm] = useState({
    name: initialName,
    unit: "g",
    purchase: "KG",
    factor: "1000",
    cost: "",
    category: "",
    barcode: "",
    active: true,
    lots: false,
  });
  const keys = useRef(new OperationIdempotencyKeys()).current;
  const formRef = useRef<HTMLFormElement>(null);
  const canCost = permissions.includes("import_costs");
  useEffect(() => {
    let active = true;
    void Promise.resolve().then(async () => {
      if (!active) return;
      setLoading(true);
      setLoadError("");
      setContext(null);
      try {
        const { data, error: failure } = await getSupabaseClient().rpc(
          "get_restaurant_studio_context",
          { p_company_id: companyId, p_product_id: productId ?? null },
        );
        if (!active) return;
        if (failure) throw failure;
        if (!data) throw new Error("No se recibieron los datos del insumo. Vuelve a intentar.");
        const next = data as StudioContext;
        setContext(next);
        if (next.product)
          setForm({
            name: next.product.name,
            unit: canonicalUnit(next.product.unit),
            purchase: next.purchase?.purchase_unit ?? "KG",
            factor: String(next.purchase?.base_units_per_purchase_unit ?? 1000),
            cost: "",
            category: next.product.product_group ?? "",
            barcode: next.product.barcode ?? "",
            active: next.product.is_active,
            lots: next.product.lot_controlled,
          });
      } catch (failure) {
        if (active) {
          setContext(null);
          setLoadError(restaurantError(failure));
        }
      } finally {
        if (active) setLoading(false);
      }
    });
    return () => { active = false; };
  }, [companyId, productId, loadAttempt]);
  const automatic = purchaseFactor(form.purchase, form.unit);
  const factor = automatic ?? numberValue(form.factor);
  const cost = numberValue(form.cost);
  const currency = context?.cost?.currency_code ?? context?.currency_code ?? "MXN";
  const savedCost = context?.cost?.current_cost;
  const preciseCost = (value: number) => new Intl.NumberFormat("es-MX", {
    style: "currency", currency, maximumFractionDigits: 6,
  }).format(value);
  const purchaseOptions = [
    ...({
      g: [
        { value: "KG", label: "Kilo" },
        { value: "G", label: "Gramo" },
      ],
      kg: [
        { value: "KG", label: "Kilo" },
        { value: "G", label: "Gramo" },
      ],
      mg: [
        { value: "KG", label: "Kilo" },
        { value: "G", label: "Gramo" },
      ],
      ml: [
        { value: "L", label: "Litro" },
        { value: "ML", label: "Mililitro" },
      ],
      l: [
        { value: "L", label: "Litro" },
        { value: "ML", label: "Mililitro" },
      ],
      piece: [{ value: "PZA", label: "Pieza" }],
    }[form.unit] ?? []),
    { value: "BOLSA", label: "Bolsa" },
    { value: "BOTELLA", label: "Botella" },
    { value: "PAQUETE", label: "Paquete" },
    { value: "CAJA", label: "Caja" },
  ];
  if (!purchaseOptions.some((option) => option.value === form.purchase))
    purchaseOptions.push({ value: form.purchase, label: form.purchase });
  async function save() {
    if (busy || loading || !context || loadError) return;
    if (!formRef.current?.reportValidity()) return;
    if (!form.name.trim() || !(factor > 0)) {
      setError("Escribe el nombre y el contenido de la presentación.");
      return;
    }
    if (form.cost && !(cost > 0)) {
      setError("Escribe un costo mayor que cero o deja el costo pendiente.");
      return;
    }
    setBusy(true);
    setError("");
    const payload = {
      id: productId ?? null,
      name: form.name.trim(),
      unit: form.unit,
      purchase_unit: form.purchase,
      purchase_factor: factor,
      package_cost: form.cost ? cost : null,
      category: form.category,
      barcode: form.barcode,
      is_active: form.active,
      lot_controlled: form.lots,
      internal_sku: context?.product?.internal_sku ?? "",
      updated_at: context?.product?.updated_at ?? null,
    };
    try {
      const { data, error: failure } = await getSupabaseClient().rpc(
        "save_restaurant_ingredient_studio",
        {
          p_company_id: companyId,
          p_payload: payload,
          p_client_request_id: keys.get(
            "ingredient-studio",
            JSON.stringify(payload),
          ),
        },
      );
      if (failure) throw failure;
      keys.clear("ingredient-studio");
      onSaved(data as ComponentOption);
    } catch (failure) {
      setError(restaurantError(failure));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
      labelledBy="restaurant-ingredient-title"
      title={productId ? "Editar insumo" : "Agregar insumo"}
      description="Lo que compras y utilizas para cocinar."
      className={styles.ingredientModal}
      closeDisabled={busy}
      footer={
        <>
          <Button disabled={busy} onClick={onClose}>
            Cancelar
          </Button>
          <Button
            variant="primary"
            loading={busy}
            disabled={loading || !context || Boolean(loadError)}
            onClick={() => void save()}
          >
            <Check size={16} />
            {productId ? "Guardar insumo" : "Crear insumo"}
          </Button>
        </>
      }
    >
      {loading ? (
        <p role="status">Cargando insumo…</p>
      ) : loadError ? (
        <div className={styles.loadError}>
          <AlertCircle size={26} aria-hidden="true" />
          <p role="alert">{loadError}</p>
          <Button onClick={() => {
            setLoading(true);
            setLoadError("");
            setLoadAttempt(attempt => attempt + 1);
          }}>Reintentar carga</Button>
        </div>
      ) : (
        <form
          ref={formRef}
          className={styles.formStack}
          onSubmit={(event) => {
            event.preventDefault();
            void save();
          }}
        >
          <Field label="Nombre del insumo">
            <Input
              autoFocus
              required
              maxLength={160}
              value={form.name}
              onChange={(event) =>
                setForm({ ...form, name: event.target.value })
              }
              placeholder="Ej. Arrachera"
              autoComplete="off"
            />
          </Field>
          <div className={styles.fieldPair}>
            <Field label="En la receta lo mido en">
              <Select
                ariaLabel="Unidad para las recetas"
                value={form.unit}
                onValueChange={(unit) =>
                  setForm({
                    ...form,
                    unit,
                    purchase: ["g", "kg", "mg"].includes(unit)
                      ? "KG"
                      : ["ml", "l"].includes(unit)
                        ? "L"
                        : "PZA",
                    factor: "",
                  })
                }
                options={[
                  { value: "g", label: "Gramos (g)" },
                  { value: "ml", label: "Mililitros (ml)" },
                  { value: "piece", label: "Piezas" },
                  { value: "kg", label: "Kilogramos (kg)" },
                  { value: "l", label: "Litros (l)" },
                  { value: "mg", label: "Miligramos (mg)" },
                ]}
              />
            </Field>
            <Field label="Lo compro por">
              <Select
                ariaLabel="Presentación de compra"
                value={form.purchase}
                onValueChange={(purchase) =>
                  setForm({ ...form, purchase, factor: "" })
                }
                options={purchaseOptions}
              />
            </Field>
          </div>
          {automatic == null && (
            <Field
              label={`Contenido de cada ${purchaseOptions.find((item) => item.value === form.purchase)?.label.toLowerCase()} en ${unitLabel(form.unit)}`}
            >
              <Input
                required
                type="number"
                min="0.000001"
                step="any"
                value={form.factor}
                onChange={(event) =>
                  setForm({ ...form, factor: event.target.value })
                }
                placeholder="Ej. 1000"
              />
            </Field>
          )}
          {factor > 0 && (
            <div className={styles.conversion}>
              <Package size={21} aria-hidden="true" />
              <span>
                1{" "}
                {purchaseOptions
                  .find((item) => item.value === form.purchase)
                  ?.label.toLowerCase()}
              </span>
              <ArrowRight size={17} aria-hidden="true" />
              <strong>
                {factor.toLocaleString("es-MX")} {unitLabel(form.unit)}
              </strong>
            </div>
          )}
          {canCost && (
            <Field
              label={
                productId
                  ? "Actualizar costo para recetas (por presentación)"
                  : "¿Cuánto cuesta esa presentación? (opcional)"
              }
              hint={
                productId
                  ? "Escribe el importe de una presentación completa. Déjalo vacío para conservar el costo para recetas. Registra las compras en Entradas de insumos."
                  : "Puedes completarlo después. Este costo inicial no registra existencias."
              }
            >
              <Input
                type="number"
                min="0.000001"
                step="any"
                inputMode="decimal"
                value={form.cost}
                onChange={(event) =>
                  setForm({ ...form, cost: event.target.value })
                }
                placeholder="Ej. 240.00"
              />
            </Field>
          )}
          {cost > 0 && factor > 0 && (
            <p className={styles.hint}>
              Al guardar, costo para recetas: {preciseCost(cost / factor)} por {canonicalUnit(form.unit) === "piece" ? "pieza" : unitLabel(form.unit)}.
            </p>
          )}
          {savedCost && context?.product && (
            <p className={styles.hint}>
              Costo para recetas: {preciseCost(savedCost.amount)} por {canonicalUnit(context.product.unit) === "piece" ? "pieza" : unitLabel(context.product.unit)}.
              {context.purchase && <> Equivale a {money(savedCost.amount * context.purchase.base_units_per_purchase_unit, currency)} por {context.purchase.purchase_unit.toLowerCase()}.</>}
              {context.cost?.cost_method === "average_cost" && " Método: costo promedio."}
              {context.cost?.cost_method === "replacement_cost" && " Método: costo de reposición."}
              {context.cost?.cost_method === "standard_cost" && " Método: costo estándar."}
            </p>
          )}
          <details className={styles.disclosure}>
            <summary>Categoría y otras opciones</summary>
            <div className={styles.formStack}>
              <Field label="Categoría">
                <Input
                  list="restaurant-ingredient-categories"
                  value={form.category}
                  onChange={(event) =>
                    setForm({ ...form, category: event.target.value })
                  }
                  placeholder="Ej. Proteínas"
                />
              </Field>
              <datalist id="restaurant-ingredient-categories">
                {categories.ingredient.map((item) => (
                  <option key={item} value={item} />
                ))}
              </datalist>
              <Field label="Código de barras (opcional)">
                <Input
                  value={form.barcode}
                  onChange={(event) =>
                    setForm({ ...form, barcode: event.target.value })
                  }
                />
              </Field>
              <label className={styles.check}>
                <input
                  type="checkbox"
                  checked={form.lots}
                  onChange={(event) =>
                    setForm({ ...form, lots: event.target.checked })
                  }
                />
                Controlar lotes y caducidad al recibir
              </label>
              {productId && (
                <label className={styles.check}>
                  <input
                    type="checkbox"
                    checked={form.active}
                    onChange={(event) =>
                      setForm({ ...form, active: event.target.checked })
                    }
                  />
                  Insumo activo
                </label>
              )}
            </div>
          </details>
        </form>
      )}
      {error && (
        <p role="alert" className={styles.error}>
          <AlertCircle size={18} aria-hidden="true" />
          {error}
        </p>
      )}
    </Modal>
  );
}
