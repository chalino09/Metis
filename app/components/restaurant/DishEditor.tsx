/* eslint-disable @next/next/no-img-element -- Bounded local data images; no remote optimization required. */
"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
} from "react";
import {
  AlertCircle,
  ArrowLeft,
  ArrowRight,
  Check,
  ChefHat,
  CookingPot,
  ImagePlus,
  Leaf,
  Store,
  Trash2,
  UtensilsCrossed,
} from "lucide-react";
import { Field, Modal } from "@/app/components/ui/primitives";
import { OperationalButton as Button, OperationalInput as Input } from "@/app/components/reui/operational-controls";
import { getSupabaseClient } from "@/app/lib/supabase";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import {
  bundleIssues,
  categories,
  canonicalUnit,
  compatibleUnits,
  money,
  netMargin,
  numberValue,
  recipeComponents,
  restaurantError,
  unitLabel,
  type BundleDraft,
  type ComponentOption,
  type CostPreview,
  type RecipeLine,
  type StudioContext,
  type LocationStatus,
} from "@/app/lib/restaurant/studio";
import { IngredientEditor } from "./IngredientEditor";
import { ComponentPicker } from "./ComponentPicker";
import { BundleEditor } from "./BundleEditor";
import {
  Stepper,
  StepperItem,
  StepperTrigger,
  StepperIndicator,
  StepperTitle,
} from "./stepper";
import { Select } from "./controls";
import styles from "./restaurant.module.css";

type Saved = {
  product_id: string;
  name: string;
  available: boolean;
  recipe_active: boolean;
  is_active: boolean;
};
type Props = {
  companyId: string;
  permissions: string[];
  productId?: string;
  kind: "dish" | "preparation";
  duplicate?: boolean;
  initialStep?: number;
  onClose: () => void;
  onSaved: (result: Saved) => void;
};
export function DishEditor({
  companyId,
  permissions,
  productId,
  kind,
  duplicate = false,
  initialStep = 1,
  onClose,
  onSaved,
}: Props) {
  const [step, setStep] = useState(initialStep);
  const [context, setContext] = useState<StudioContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [discard, setDiscard] = useState(false);
  const [saved, setSaved] = useState<Saved | null>(null);
  const [savedLocations, setSavedLocations] = useState<LocationStatus[] | null>(
    null,
  );
  const [form, setForm] = useState({
    name: "",
    category: "",
    description: "",
    image: "",
    portions: "1",
    yieldQuantity: "1000",
    yieldUnit: "ml",
    waste: "0",
    price: "",
    priceList: "",
    tax: "",
    available: true,
    active: true,
  });
  const [lines, setLines] = useState<RecipeLine[]>([]);
  const [assortments, setAssortments] = useState<string[]>([]);
  const [locations, setLocations] = useState<string[]>([]);
  const [ingredient, setIngredient] = useState<{
    initialName?: string;
    productId?: string;
  } | null>(null);
  const [bundle, setBundle] = useState<BundleDraft | null>(null);
  const [preview, setPreview] = useState<{
    key: string;
    value: CostPreview;
  } | null>(null);
  const [costError, setCostError] = useState("");
  const keys = useRef(new OperationIdempotencyKeys()).current;
  const bodyRef = useRef<HTMLDivElement>(null);
  const photoRef = useRef<HTMLInputElement>(null);
  const canPrice = permissions.includes("manage_prices");
  const canAssortment = permissions.includes("manage_assortments");
  const canCost = permissions.includes("view_costs");
  const isDish = kind === "dish";
  const isNew = !productId || duplicate;
  const lastStep = isDish ? 3 : 2;
  const baseCostScale = ["g", "ml", "mg"].includes(form.yieldUnit) ? 1000 : 1;
  const baseCostUnit =
    ({ g: "kg", ml: "litro", mg: "g", piece: "pieza" } as Record<string, string>)[form.yieldUnit] ?? form.yieldUnit;
  const load = useCallback(async () => {
    setLoading(true);
    setLoadError("");
    try {
      const { data, error: failure } = await getSupabaseClient().rpc(
        "get_restaurant_studio_context",
        { p_company_id: companyId, p_product_id: productId ?? null },
      );
      if (failure) throw failure;
      const next = data as StudioContext;
      setContext(next);
      const product = next.product,
        version = next.recipe?.draft ?? next.recipe?.active;
      // Existing canonical dishes store one portion. Restore the cook's last batch size.
      const portions = isDish
        ? Number(next.presentation?.batch_portions ?? 1)
        : Number(version?.portion_count ?? 1);
      const multiplier = isDish
        ? portions / Number(version?.portion_count ?? 1)
        : 1;
      const list =
        next.price_lists.find((item) => item.is_default) ?? next.price_lists[0];
      const price = next.prices.find((item) => item.price_list_id === list?.id);
      setForm({
        name: product
          ? `${product.name}${duplicate ? " · nueva variante" : ""}`
          : "",
        category: product?.product_group ?? "",
        description: next.presentation?.description ?? "",
        image: next.presentation?.image_data ?? "",
        portions: String(portions),
        yieldQuantity: String(version?.yield_quantity ?? 1000),
        yieldUnit: version?.yield_unit_code ?? "ml",
        waste: String(version?.waste_percent ?? 0),
        price: price?.final_price != null ? String(price.final_price) : "",
        priceList: list?.id ?? "",
        tax:
          product?.tax_category_id ??
          (next.tax_categories.filter((item) => item.rate != null).length === 1
            ? next.tax_categories.find((item) => item.rate != null)!.id
            : ""),
        available: duplicate ? canPrice : (product?.is_sellable ?? canPrice),
        active: duplicate ? true : (product?.is_active ?? true),
      });
      setLines(
        (version?.components ?? []).map((item) => ({
          id: item.product_id,
          name: item.product_name,
          notes: item.notes,
          internal_sku: item.product_code,
          unit: canonicalUnit(item.base_unit_code),
          quantity: String(
            Number(
              (Number(item.entered_quantity) * multiplier).toPrecision(12),
            ),
          ),
          unit_code: item.entered_unit_code,
          catalog_role:
            item.catalog_role === "preparation" ? "preparation" : "ingredient",
          recipe_kind:
            item.catalog_role === "preparation" ? "preparation" : null,
        })),
      );
      setAssortments(
        next.assortments
          .filter(
            (item) =>
              item.included ||
              (!product &&
                next.assortments.length === 1 &&
                item.locations.length > 0),
          )
          .map((item) => item.id),
      );
      setLocations(next.locations.length === 1 ? [next.locations[0].id] : []);
      setBundle(duplicate ? null : (next.bundle ?? null));
      setDirty(duplicate);
    } catch (failure) {
      setLoadError(restaurantError(failure));
    } finally {
      setLoading(false);
    }
  }, [companyId, productId, duplicate, isDish, canPrice]);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    if (!dirty || saved) return;
    const prevent = (event: BeforeUnloadEvent) => event.preventDefault();
    window.addEventListener("beforeunload", prevent);
    return () => window.removeEventListener("beforeunload", prevent);
  }, [dirty, saved]);
  function patch(patch: Partial<typeof form>) {
    setForm((current) => ({ ...current, ...patch }));
    setDirty(true);
  }
  function updateLine(id: string, patch: Partial<RecipeLine>) {
    setLines((current) =>
      current.map((line) => (line.id === id ? { ...line, ...patch } : line)),
    );
    setDirty(true);
  }
  const portions = numberValue(form.portions),
    waste = numberValue(form.waste);
  const components = useMemo(() => recipeComponents(lines), [lines]);
  const validLines =
    lines.length > 0 &&
    lines.every(
      (line) =>
        numberValue(line.quantity) > 0 &&
        compatibleUnits(line.unit).some(
          (unit) => unit.value === line.unit_code,
        ),
    );
  const validYield =
    Number.isInteger(portions) &&
    portions > 0 &&
    portions <= 100000 &&
    waste >= 0 &&
    waste < 100 &&
    (isDish || numberValue(form.yieldQuantity) > 0);
  const currency =
    context?.price_lists.find((item) => item.id === form.priceList)
      ?.currency_code ??
    context?.currency_code ??
    "MXN";
  const costKey = JSON.stringify({ components, portions, waste, currency });
  useEffect(() => {
    if (loading || !validLines || !validYield || !canCost) return;
    let active = true;
    const timer = setTimeout(async () => {
      try {
        const { data, error: failure } = await getSupabaseClient().rpc(
          "preview_restaurant_recipe_cost",
          {
            p_company_id: companyId,
            p_components: components,
            p_portions: portions,
            p_waste_percent: waste,
            p_currency_code: currency,
          },
        );
        if (!active) return;
        if (failure) throw failure;
        setPreview({ key: costKey, value: data as CostPreview });
        setCostError("");
      } catch (failure) {
        if (active) {
          setCostError(restaurantError(failure));
          setPreview(null);
        }
      }
    }, 250);
    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [
    companyId,
    loading,
    validLines,
    validYield,
    canCost,
    components,
    portions,
    waste,
    currency,
    costKey,
  ]);
  const currentCost = preview?.key === costKey ? preview.value : null;
  const taxRate =
    context?.tax_categories.find((item) => item.id === form.tax)?.rate ?? null;
  const margin = netMargin(
    numberValue(form.price),
    taxRate,
    currentCost?.cost_per_portion ?? null,
  );
  const costWaiting =
    canCost && validLines && validYield && !currentCost && !costError;
  const selectedPlaces = new Set(
    context?.assortments
      .filter((item) => assortments.includes(item.id))
      .flatMap((item) => item.locations.map((location) => location.id)) ?? [],
  );
  const places = context?.assortments.length
    ? selectedPlaces.size
    : canAssortment
      ? locations.length
      : (context?.location_status.length ?? 0);
  function close() {
    if (busy) return;
    if (saved) {
      onSaved(saved);
      return;
    }
    if (dirty) setDiscard(true);
    else onClose();
  }
  function focusInvalid() {
    requestAnimationFrame(() => {
      const body = bodyRef.current;
      body?.querySelectorAll<HTMLDetailsElement>("details").forEach(details => {
        if (details.querySelector('[aria-invalid="true"]')) details.open = true;
      });
      const target = body?.querySelector<HTMLElement>('[aria-invalid="true"]') ?? body?.querySelector<HTMLElement>('[role="alert"]');
      target?.focus({ preventScroll: true });
      target?.scrollIntoView({ block: "center" });
    });
  }
  useEffect(() => {
    if (error) focusInvalid();
  }, [error]);
  function validate(target: number) {
    setShowErrors(true);
    setError("");
    if (!form.name.trim()) {
      setStep(1);
      setError("Escribe el nombre de la receta para continuar.");
      focusInvalid();
      return false;
    }
    if (target >= 2 && !validLines) {
      setStep(1);
      setError("Agrega ingredientes y revisa las cantidades marcadas.");
      focusInvalid();
      return false;
    }
    if (target >= 3 && !validYield) {
      setStep(2);
      setError("Indica cuántas porciones rinde la receta y revisa la merma.");
      focusInvalid();
      return false;
    }
    return true;
  }
  function navigate(target: number) {
    if (target <= step || validate(target)) {
      setStep(target);
      setError("");
      bodyRef.current?.scrollTo({ top: 0 });
    }
  }
  function addIngredient(item: ComponentOption) {
    if (lines.some((line) => line.id === item.id)) return;
    setLines((current) => [
      ...current,
      {
        ...item,
        unit: canonicalUnit(item.unit),
        unit_code: canonicalUnit(item.unit),
        quantity: "",
      },
    ]);
    setDirty(true);
    requestAnimationFrame(() =>
      bodyRef.current
        ?.querySelector<HTMLInputElement>(`[data-quantity-id="${item.id}"]`)
        ?.focus(),
    );
  }
  async function choosePhoto(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    if (
      !["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
      file.size > 1000000
    ) {
      setError("Elige una imagen JPG, PNG o WebP de hasta 1 MB.");
      return;
    }
    try {
      const image = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result));
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      patch({ image });
      setError("");
    } catch {
      setError("No se pudo leer la imagen. Elige el archivo nuevamente.");
    }
  }
  async function save(finish: boolean) {
    if (busy || !context) return;
    if (!validate(finish ? 3 : 1)) return;
    if (
      !finish &&
      !lines.length &&
      (context.recipe?.active || context.recipe?.draft)
    ) {
      setStep(1);
      setError(
        "Conserva al menos un ingrediente en la receta. Puedes deshabilitar su venta en Precio y venta.",
      );
      return;
    }
    if (!finish && lines.length && !validLines) {
      setStep(1);
      setError("Completa las cantidades antes de guardar el borrador.");
      return;
    }
    if (!validYield) {
      setStep(2);
      setError("Indica un rendimiento válido antes de guardar.");
      return;
    }
    if (finish && isDish) {
      if (form.price && (!(numberValue(form.price) > 0) || taxRate == null)) {
        setStep(3);
        setError("Escribe un precio mayor que cero y selecciona el impuesto.");
        return;
      }
      if (form.available && ((canPrice && !form.price) || taxRate == null)) {
        setStep(3);
        setError("Para ofrecer el platillo, completa su precio e impuesto.");
        return;
      }
      if (form.available && canAssortment && places === 0) {
        setStep(3);
        setError("Elige al menos una sucursal para ofrecer el platillo.");
        return;
      }
    }
    // Both save actions send the bundle, so validate it before either RPC.
    const issues = canPrice ? bundleIssues(bundle) : [];
    if (issues.length) {
      setStep(3);
      setError(issues[0].message);
      focusInvalid();
      return;
    }

    const payload = {
      id: isNew ? null : productId,
      kind,
      name: form.name.trim(),
      category: form.category.trim(),
      description: form.description.trim(),
      image_data: form.image || null,
      portions,
      yield_quantity: isDish ? 1 : numberValue(form.yieldQuantity),
      yield_unit: isDish ? "piece" : form.yieldUnit,
      waste_percent: waste,
      components,
      tax_category_id: form.tax || null,
      final_price:
        isDish && canPrice && form.price && (finish || !isNew)
          ? numberValue(form.price)
          : null,
      price_list_id: form.priceList || null,
      available: form.available,
      is_active: form.active,
      finish,
      updated_at: isNew ? null : context.product?.updated_at,
      recipe_revision: isNew ? null : context.recipe_revision,
      ...(canAssortment
        ? { assortment_ids: assortments, location_ids: locations }
        : {}),
      ...(bundle && canPrice ? { bundle } : {}),
    };
    setBusy(true);
    setError("");
    try {
      const { data, error: failure } = await getSupabaseClient().rpc(
        "save_restaurant_studio",
        {
          p_company_id: companyId,
          p_payload: payload,
          p_client_request_id: keys.get(
            "restaurant-studio",
            JSON.stringify(payload),
          ),
        },
      );
      if (failure) throw failure;
      keys.clear("restaurant-studio");
      setSaved(data as Saved);
      setDirty(false);
      // A second read sees committed prices and reports actual operating readiness.
      const status = await getSupabaseClient().rpc(
        "get_restaurant_studio_context",
        { p_company_id: companyId, p_product_id: (data as Saved).product_id },
      );
      if (!status.error)
        setSavedLocations((status.data as StudioContext).location_status);
    } catch (failure) {
      setError(restaurantError(failure));
    } finally {
      setBusy(false);
    }
  }
  const steps = [
    { title: "Ingredientes", description: "Qué lleva" },
    {
      title: isDish ? "Porciones y costo" : "Rendimiento y costo",
      description: "Cuánto rinde",
    },
    ...(isDish
      ? [{ title: "Precio y venta", description: "Listo para tu menú" }]
      : []),
  ];
  return (
    <>
      <Modal
        open
        onOpenChange={(open) => {
          if (!open) close();
        }}
        labelledBy="restaurant-dish-title"
        title={
          saved
            ? saved.name
            : isNew
              ? isDish
                ? duplicate
                  ? "Crear variante del platillo"
                  : "Crear un platillo"
                : "Crear una base"
              : form.name || "Editar receta"
        }
        eyebrow="Cocina · Restaurante"
        description={
          saved
            ? "La información quedó guardada."
            : isDish
              ? "De tu receta al menú, en un solo lugar."
              : "Prepara una vez. Úsala en todas tus recetas."
        }
        className={styles.editorModal}
        closeDisabled={busy}
        footer={
          saved ? (
            <Button variant="primary" onClick={() => onSaved(saved)}>
              {isDish ? "Volver al menú" : "Volver a las bases"}
              <ArrowRight size={16} />
            </Button>
          ) : (
            <div className={styles.editorFooterWrap}>
              {error && (
                <div className={styles.saveError}>
                  <AlertCircle size={18} aria-hidden="true" />
                  <span>Hay cambios sin guardar. Revisa el pendiente.</span>
                  <Button size="sm" variant="ghost" onClick={focusInvalid}>Ver pendiente</Button>
                </div>
              )}
              <div className={styles.editorFooter}>
                <span>
                  {step === 1
                    ? "Empieza con lo que sabes cocinar."
                    : step === 2
                      ? "Los costos se calculan automáticamente."
                      : "Precio, receta y sucursales se guardan juntos."}
                </span>
                <div>
                  {step > 1 && (
                    <Button disabled={busy} onClick={() => navigate(step - 1)}>
                      <ArrowLeft size={16} />
                      Volver
                    </Button>
                  )}
                  <Button
                    variant="ghost"
                    disabled={loading || busy || Boolean(loadError)}
                    onClick={() => void save(false)}
                  >
                    {isNew ? "Guardar borrador" : "Guardar sin activar receta"}
                  </Button>
                  {step < lastStep ? (
                    <Button
                      variant="primary"
                      disabled={loading || Boolean(loadError)}
                      onClick={() => navigate(step + 1)}
                    >
                      Continuar
                      <ArrowRight size={16} />
                    </Button>
                  ) : (
                    <Button
                      variant="primary"
                      loading={busy}
                      disabled={loading || Boolean(loadError)}
                      onClick={() => void save(true)}
                    >
                      <Check size={17} />
                      {!form.active
                        ? isDish ? "Guardar platillo inactivo" : "Guardar base inactiva"
                        : isDish
                        ? form.available
                          ? "Guardar y ofrecer en POS"
                          : "Guardar platillo"
                        : "Guardar base y usar en recetas"}
                    </Button>
                  )}
                </div>
              </div>
            </div>
          )
        }
      >
        {saved ? (
          <div className={styles.success}>
            <header className={styles.successHeader}>
              <div className={styles.successIcon}>
                <Check size={30} />
              </div>
              <h2>
                {!saved.is_active
                  ? isDish ? "Platillo guardado como inactivo" : "Base guardada como inactiva"
                  : saved.recipe_active
                  ? saved.available
                    ? savedLocations?.some((location) => !location.available)
                      ? "Platillo guardado"
                      : "Tu platillo ya forma parte del menú"
                    : isDish
                      ? "Platillo guardado"
                      : "La base está lista para tus recetas"
                  : "Borrador guardado"}
              </h2>
              <p>
                {saved.available
                  ? "Tu receta y los cambios de venta quedaron guardados. El platillo permanece en el menú; POS revisa las existencias y el precio antes de vender."
                  : saved.recipe_active
                    ? "Puedes regresar a editarlo cuando lo necesites."
                    : "Puedes retomar los ingredientes, el precio y la disponibilidad desde el menú."}
              </p>
            </header>
            {saved.available && currentCost && !currentCost.allowed && (
              <section className={styles.successNotice}>
                <h3>Costo pendiente</h3>
                <p>Hay insumos sin costo vigente. Completa sus costos para calcular el margen.</p>
              </section>
            )}
            {saved.available && savedLocations && (
              <div
                className={styles.successLocations}
                aria-label="Disponibilidad después de guardar"
              >
                <h3>Disponibilidad por sucursal</h3>
                {savedLocations.map((location) => (
                  <div key={location.id} data-available={location.available}>
                    <div>
                      <strong>{location.name}</strong>
                      <span>{location.available ? "Disponible" : "Pendiente para vender"}</span>
                    </div>
                    <p>{location.message}</p>
                  </div>
                ))}
              </div>
            )}
            <div className={styles.successFacts}>
              <span>
                <ChefHat size={18} />
                {lines.length} {lines.length === 1 ? "ingrediente" : "ingredientes"}
              </span>
              <span>
                <CookingPot size={18} />
                {isDish
                  ? `${form.portions} ${portions === 1 ? "porción" : "porciones"} por tanda`
                  : `${form.yieldQuantity} ${unitLabel(form.yieldUnit)} por tanda`}
              </span>
              {saved.available && (
                <span>
                  <Store size={18} />
                  {places} {places === 1 ? "sucursal elegida" : "sucursales elegidas"}
                </span>
              )}
            </div>
          </div>
        ) : loading ? (
          <div className={styles.loading} role="status">
            Preparando tu espacio de cocina…
          </div>
        ) : loadError ? (
          <div className={styles.loadError}>
            <AlertCircle size={26} />
            <p role="alert">{loadError}</p>
            <Button onClick={() => void load()}>Reintentar</Button>
          </div>
        ) : (
          <>
            <Stepper
              value={step}
              onValueChange={navigate}
              className={styles.stepper}
              aria-label={isDish ? "Editar platillo" : "Editar base"}
              indicators={{ completed: <Check size={16} /> }}
            >
              {steps.map((item, index) => (
                <StepperItem
                  key={item.title}
                  step={index + 1}
                  completed={step > index + 1}
                >
                  <StepperTrigger disabled={busy}>
                    <StepperIndicator>{index + 1}</StepperIndicator>
                    <span>
                      <StepperTitle>{item.title}</StepperTitle>
                      <small>{item.description}</small>
                    </span>
                  </StepperTrigger>
                </StepperItem>
              ))}
            </Stepper>
            <div ref={bodyRef} className={styles.editorGrid}>
              <div className={styles.editorMain}>
                {error && (
                  <p role="alert" tabIndex={-1} className={styles.error}>
                    <AlertCircle size={18} />
                    {error}
                  </p>
                )}
                {step === 1 && (
                  <section
                    id="stepper-panel-1"
                    role="tabpanel"
                    aria-labelledby="stepper-tab-1"
                    className={styles.formStack}
                  >
                    <div className={styles.sectionIntro}>
                      <span className={styles.sectionNumber}>01</span>
                      <div>
                        <h2>
                          {isDish
                            ? "¿Qué vamos a cocinar?"
                            : "¿Qué base vas a preparar?"}
                        </h2>
                        <p>
                          Agrega todo lo que lleva tu receta. El rendimiento lo
                          definimos después.
                        </p>
                      </div>
                    </div>
                    <Field
                      label={
                        isDish ? "Nombre del platillo" : "Nombre de la base"
                      }
                    >
                      <Input
                        autoFocus
                        value={form.name}
                        onChange={(event) =>
                          patch({ name: event.target.value })
                        }
                        placeholder={
                          isDish ? "Ej. Tacos de arrachera" : "Ej. Salsa verde"
                        }
                        maxLength={160}
                        aria-invalid={showErrors && !form.name.trim()}
                        aria-describedby={
                          showErrors && !form.name.trim()
                            ? "restaurant-name-error"
                            : undefined
                        }
                      />
                      {showErrors && !form.name.trim() && (
                        <small id="restaurant-name-error">
                          Escribe el nombre para continuar.
                        </small>
                      )}
                    </Field>
                    <ComponentPicker
                      companyId={companyId}
                      selectedIds={lines.map((line) => line.id)}
                      excludeId={productId}
                      onSelect={addIngredient}
                      onCreate={
                        permissions.includes("manage_products")
                          ? (initialName) => setIngredient({ initialName })
                          : undefined
                      }
                    />
                    {lines.length ? (
                      <div className={styles.ingredients}>
                        <div className={styles.ingredientsHead}>
                          <span>Ingredientes de la receta</span>
                          <span>Cantidad</span>
                          <span>{canCost ? "Costo" : ""}</span>
                          <span />
                        </div>
                        {lines.map((line) => {
                          const lineCost = currentCost?.lines.find(
                            (item) => item.product_id === line.id,
                          );
                          const invalid =
                            showErrors && !(numberValue(line.quantity) > 0);
                          return (
                            <div key={line.id} className={styles.ingredientRow}>
                              <div className={styles.ingredientName}>
                                <span className={styles.ingredientIcon}>
                                  {line.catalog_role === "preparation" ? (
                                    <CookingPot size={18} />
                                  ) : (
                                    <Leaf size={18} />
                                  )}
                                </span>
                                <div>
                                  <strong>{line.name}</strong>
                                  <small>
                                    {line.catalog_role === "preparation"
                                      ? "Base reutilizable"
                                      : "Insumo"}
                                    {line.notes ? ` · ${line.notes}` : ""}
                                  </small>
                                  {invalid && (
                                    <small
                                      id={`quantity-error-${line.id}`}
                                      className={styles.inlineError}
                                    >
                                      Indica cuánto lleva.
                                    </small>
                                  )}
                                </div>
                              </div>
                              <div className={styles.quantity}>
                                <Input
                                  type="number"
                                  inputMode="decimal"
                                  min="0.000001"
                                  step="any"
                                  data-quantity-id={line.id}
                                  aria-label={`Cantidad de ${line.name}`}
                                  aria-invalid={invalid}
                                  aria-describedby={
                                    invalid
                                      ? `quantity-error-${line.id}`
                                      : undefined
                                  }
                                  value={line.quantity}
                                  placeholder="0"
                                  onChange={(event) =>
                                    updateLine(line.id, {
                                      quantity: event.target.value,
                                    })
                                  }
                                />
                                <Select
                                  ariaLabel={`Unidad de ${line.name}`}
                                  value={line.unit_code}
                                  options={compatibleUnits(line.unit)}
                                  onValueChange={(unit_code) =>
                                    updateLine(line.id, { unit_code })
                                  }
                                />
                              </div>
                              <span className={styles.lineCost}>
                                {canCost ? (
                                  lineCost?.cost != null ? (
                                    money(lineCost.cost, currency)
                                  ) : lineCost ? (
                                    <button
                                      className={styles.textButton}
                                      onClick={() => {
                                        if (line.catalog_role === "ingredient")
                                          setIngredient({ productId: line.id });
                                      }}
                                      disabled={
                                        !permissions.includes("import_costs") ||
                                        line.catalog_role !== "ingredient"
                                      }
                                    >
                                      Sin costo
                                    </button>
                                  ) : (
                                    "—"
                                  )
                                ) : (
                                  ""
                                )}
                              </span>
                              <Button
                                variant="ghost"
                                size="icon"
                                aria-label={`Quitar ${line.name} de la receta`}
                                onClick={() => {
                                  setLines((current) =>
                                    current.filter(
                                      (item) => item.id !== line.id,
                                    ),
                                  );
                                  setDirty(true);
                                }}
                              >
                                <Trash2 size={16} />
                              </Button>
                            </div>
                          );
                        })}
                        <div className={styles.ingredientCount}>
                          {lines.length}{" "}
                          {lines.length === 1 ? "ingrediente" : "ingredientes"}{" "}
                          · Cantidades de la receta completa
                        </div>
                      </div>
                    ) : (
                      <div className={styles.emptyIngredients}>
                        <CookingPot
                          size={34}
                          strokeWidth={1.5}
                          aria-hidden="true"
                        />
                        <h3>Una buena receta empieza aquí</h3>
                        <p>
                          Busca el primer ingrediente y escribe cuánto
                          necesitas. Puedes usar los insumos que ya tienes
                          registrados.
                        </p>
                      </div>
                    )}
                  </section>
                )}
                {step === 2 && (
                  <section
                    id="stepper-panel-2"
                    role="tabpanel"
                    aria-labelledby="stepper-tab-2"
                    className={styles.formStack}
                  >
                    <div className={styles.sectionIntro}>
                      <span className={styles.sectionNumber}>02</span>
                      <div>
                        <h2>
                          {isDish
                            ? "¿Para cuántos alcanza?"
                            : "¿Cuánto produce esta base?"}
                        </h2>
                        <p>
                          {isDish
                            ? "Usa las cantidades de una porción o de una tanda completa."
                            : "Indica lo que obtienes al terminar de cocinar. Así calculamos el costo de la cantidad que uses en cada platillo."}
                        </p>
                      </div>
                    </div>
                    {isDish && (
                      <div className={styles.yieldCard}>
                        <ChefHat size={30} strokeWidth={1.5} />
                        <Field
                          label="Esta receta rinde"
                          hint="Porciones que puedes servir con todos los ingredientes que agregaste."
                        >
                          <div className={styles.portionInput}>
                            <Input
                              autoFocus
                              type="number"
                              min="1"
                              max="100000"
                              step="1"
                              value={form.portions}
                              onChange={(event) =>
                                patch({ portions: event.target.value })
                              }
                              aria-label="Porciones de la receta"
                              aria-invalid={
                                showErrors &&
                                !(Number.isInteger(portions) && portions > 0)
                              }
                            />
                            <span>porciones</span>
                          </div>
                        </Field>
                      </div>
                    )}
                    {!isDish && (
                      <div className={styles.fieldPair}>
                        <Field label="Cantidad total que produce la tanda">
                          <Input
                            type="number"
                            autoFocus
                            min="0.000001"
                            step="any"
                            value={form.yieldQuantity}
                            onChange={(event) =>
                              patch({ yieldQuantity: event.target.value })
                            }
                          />
                        </Field>
                        <Field label="Unidad del rendimiento">
                          <Select
                            ariaLabel="Unidad del rendimiento"
                            value={form.yieldUnit}
                            onValueChange={(yieldUnit) => patch({ yieldUnit })}
                            options={[
                              { value: "ml", label: "Mililitros" },
                              { value: "l", label: "Litros" },
                              { value: "g", label: "Gramos" },
                              { value: "kg", label: "Kilogramos" },
                              { value: "piece", label: "Piezas" },
                            ]}
                          />
                        </Field>
                      </div>
                    )}
                    {!isDish && (
                      <>
                        <Field label="Categoría de la base">
                          <Input
                            list="restaurant-base-categories"
                            value={form.category}
                            onChange={(event) =>
                              patch({ category: event.target.value })
                            }
                            placeholder="Ej. Salsas"
                          />
                        </Field>
                        <datalist id="restaurant-base-categories">
                          {categories.preparation.map((item) => (
                            <option key={item} value={item} />
                          ))}
                        </datalist>
                        {!isNew && (
                          <label className={styles.check}>
                            <input
                              type="checkbox"
                              checked={form.active}
                              onChange={(event) =>
                                patch({ active: event.target.checked })
                              }
                            />
                            Base activa
                          </label>
                        )}
                      </>
                    )}
                    <div className={styles.portionPreview}>
                      <header>
                        <h3>
                          {isDish
                            ? "Así queda una porción"
                            : "Lo que produce tu base"}
                        </h3>
                        <span>
                          {isDish
                            ? "Calculado automáticamente"
                            : `${form.yieldQuantity} ${unitLabel(form.yieldUnit)} por tanda`}
                        </span>
                      </header>
                      {lines.map((line) => (
                        <div key={line.id}>
                          <span>{line.name}</span>
                          <strong>
                            {portions > 0
                              ? new Intl.NumberFormat("es-MX", {
                                  maximumFractionDigits: 4,
                                }).format(
                                  numberValue(line.quantity) /
                                    (isDish ? portions : 1),
                                )
                              : "—"}{" "}
                            {unitLabel(line.unit_code)}
                            <small>
                              {isDish ? " por porción" : " por tanda"}
                            </small>
                          </strong>
                        </div>
                      ))}
                    </div>
                    <details className={styles.disclosure}>
                      <summary>
                        Ajustar merma{" "}
                        <span>{waste > 0 ? `${waste}%` : "Opcional"}</span>
                      </summary>
                      <div className={styles.formStack}>
                        <p className={styles.hint}>
                          Úsala sólo si las cantidades no incluyen lo que se
                          pierde al limpiar o preparar. Satrapy aumentará el
                          consumo y el costo para cubrir esa pérdida.
                        </p>
                        <Field label="Merma estimada (%)">
                          <Input
                            type="number"
                            min="0"
                            max="99.99"
                            step="0.01"
                            value={form.waste}
                            onChange={(event) =>
                              patch({ waste: event.target.value })
                            }
                            aria-invalid={
                              showErrors && !(waste >= 0 && waste < 100)
                            }
                          />
                        </Field>
                      </div>
                    </details>
                    {isDish && (
                      <p className={styles.hint}>
                        Al vender un platillo se descontarán los ingredientes de
                        una porción
                        {waste > 0 ? ", incluyendo el ajuste de merma" : ""}.
                      </p>
                    )}
                  </section>
                )}
                {step === 3 && isDish && (
                  <section
                    id="stepper-panel-3"
                    role="tabpanel"
                    aria-labelledby="stepper-tab-3"
                    className={styles.formStack}
                  >
                    <div className={styles.sectionIntro}>
                      <span className={styles.sectionNumber}>03</span>
                      <div>
                        <h2>Dale su lugar en el menú</h2>
                        <p>
                          Elige el precio, cuida tu margen y define dónde
                          ofrecerlo.
                        </p>
                      </div>
                    </div>
                    <div className={styles.priceCard}>
                      <Field
                        label={`Precio al cliente (${currency})`}
                        hint="Por porción. Incluye el impuesto seleccionado."
                      >
                        <Input
                          autoFocus
                          type="number"
                          inputMode="decimal"
                          min="0.01"
                          step="0.01"
                          className={styles.priceInput}
                          value={form.price}
                          onChange={(event) =>
                            patch({ price: event.target.value })
                          }
                          placeholder="0.00"
                          disabled={!canPrice}
                        />
                      </Field>
                      {margin && (
                        <div className={styles.priceMargin}>
                          <span>Margen sobre venta neta</span>
                          <strong
                            className={
                              margin.amount < 0 ? styles.negative : undefined
                            }
                          >
                            {margin.percent.toLocaleString("es-MX", {
                              maximumFractionDigits: 1,
                            })}
                            %
                          </strong>
                          <small>
                            {money(margin.amount, currency)} por platillo, antes
                            de otros gastos
                          </small>
                        </div>
                      )}
                    </div>
                    <div className={styles.fieldPair}>
                      <Field label="Categoría del menú">
                        <Input
                          list="restaurant-menu-categories"
                          value={form.category}
                          onChange={(event) =>
                            patch({ category: event.target.value })
                          }
                          placeholder="Ej. Platos fuertes"
                        />
                      </Field>
                      <datalist id="restaurant-menu-categories">
                        {categories.dish.map((item) => (
                          <option key={item} value={item} />
                        ))}
                      </datalist>
                      <Field label="Impuesto">
                        <Select
                          ariaLabel="Impuesto del platillo"
                          value={form.tax}
                          onValueChange={(tax) => patch({ tax })}
                          disabled={!canPrice}
                          options={[
                            { value: "", label: "Selecciona el impuesto" },
                            ...(context?.tax_categories ?? []).map((item) => ({
                              value: item.id,
                              label: `${item.name}${item.rate != null ? ` · ${item.rate * 100}%` : " · Sin tasa vigente"}`,
                              disabled: item.rate == null,
                            })),
                          ]}
                        />
                      </Field>
                    </div>
                    <details className={styles.disclosure}>
                      <summary>
                        Foto y descripción <span>Opcional</span>
                      </summary>
                      <div className={styles.photoEditor}>
                        <button
                          type="button"
                          className={styles.photoUpload}
                          onClick={() => photoRef.current?.click()}
                        >
                          {form.image ? (
                            <img src={form.image} alt="Foto del platillo" />
                          ) : (
                            <>
                              <ImagePlus size={24} />
                              <span>Agregar foto</span>
                              <small>JPG, PNG o WebP · Hasta 1 MB</small>
                            </>
                          )}
                        </button>
                        <input
                          ref={photoRef}
                          hidden
                          type="file"
                          accept="image/jpeg,image/png,image/webp"
                          onChange={(event) => void choosePhoto(event)}
                        />
                        <div className={styles.formStack}>
                          <Field label="Descripción breve">
                            <textarea
                              className={styles.textarea}
                              maxLength={600}
                              rows={3}
                              value={form.description}
                              onChange={(event) =>
                                patch({ description: event.target.value })
                              }
                              placeholder="Ej. Arrachera a la parrilla, tortillas de maíz y salsa de la casa."
                            />
                          </Field>
                          {form.image && (
                            <Button
                              variant="ghost"
                              onClick={() => patch({ image: "" })}
                            >
                              Quitar foto
                            </Button>
                          )}
                        </div>
                      </div>
                    </details>
                    <section className={styles.availability}>
                      <label className={styles.availabilityToggle}>
                        <span className={styles.storeIcon}>
                          <Store size={23} />
                        </span>
                        <span>
                          <strong>Disponible en POS</strong>
                          <small>
                            {form.available
                              ? "Ofrecer este platillo para la venta"
                              : "Conservar el platillo sin ofrecerlo para venta"}
                          </small>
                        </span>
                        <input
                          type="checkbox"
                          role="switch"
                          checked={form.available}
                          onChange={(event) =>
                            patch({ available: event.target.checked })
                          }
                        />
                      </label>
                      {form.available && canAssortment && (
                        <div className={styles.locationChoices}>
                          <h3>¿Dónde lo vas a ofrecer?</h3>
                          {context?.assortments.length ? (
                            context.assortments.map((item) => (
                              <label
                                key={item.id}
                                className={styles.locationChoice}
                              >
                                <input
                                  type="checkbox"
                                  checked={assortments.includes(item.id)}
                                  disabled={!item.locations.length}
                                  onChange={(event) => {
                                    setAssortments((current) =>
                                      event.target.checked
                                        ? [...current, item.id]
                                        : current.filter(
                                            (id) => id !== item.id,
                                          ),
                                    );
                                    setDirty(true);
                                  }}
                                />
                                <span>
                                  <strong>
                                    {item.locations
                                      .map((location) => location.name)
                                      .join(", ") || item.name}
                                  </strong>
                                  <small>
                                    {item.locations.length
                                      ? `Menú compartido · ${item.name}`
                                      : "Este menú todavía no tiene sucursales"}
                                  </small>
                                </span>
                              </label>
                            ))
                          ) : context?.locations.length ? (
                            context.locations.map((item) => (
                              <label
                                key={item.id}
                                className={styles.locationChoice}
                              >
                                <input
                                  type="checkbox"
                                  checked={locations.includes(item.id)}
                                  onChange={(event) => {
                                    setLocations((current) =>
                                      event.target.checked
                                        ? [...current, item.id]
                                        : current.filter(
                                            (id) => id !== item.id,
                                          ),
                                    );
                                    setDirty(true);
                                  }}
                                />
                                <span>{item.name}</span>
                              </label>
                            ))
                          ) : (
                            <p className={styles.notice}>
                              Aún no hay sucursales. Puedes guardar el platillo
                              con “Disponible en POS” apagado y completar la
                              sucursal en Configuración.
                            </p>
                          )}
                        </div>
                      )}
                      {form.available && (
                        <p className={styles.availabilityHint}>
                          POS comprueba las existencias de los ingredientes y el
                          precio de la sucursal al vender. El platillo permanece
                          en tu menú si falta algo.
                        </p>
                      )}
                    </section>
                    {!isNew &&
                      context?.location_status?.some(
                        (location) => !location.available,
                      ) && (
                        <div className={styles.operatingStatus}>
                          <h3>Disponibilidad actual por sucursal</h3>
                          {context.location_status.map((location) => (
                            <div key={location.id}>
                              <strong>{location.name}</strong>
                              <span>{location.message}</span>
                            </div>
                          ))}
                          <p>
                            Estos son los pendientes del platillo guardado. Se
                            revisarán nuevamente después de guardar tus cambios.
                          </p>
                        </div>
                      )}
                    {canPrice && (
                      <BundleEditor
                        companyId={companyId}
                        productId={productId}
                        value={bundle}
                        showErrors={showErrors}
                        onChange={(value) => {
                          setBundle(value);
                          setDirty(true);
                        }}
                      />
                    )}
                    <details className={styles.disclosure}>
                      <summary>Más opciones de venta</summary>
                      <div className={styles.formStack}>
                        <Field label="Lista de precios">
                          <Select
                            ariaLabel="Lista de precios"
                            disabled={!canPrice}
                            value={form.priceList}
                            onValueChange={(priceList) => {
                              const price = context?.prices.find(
                                (item) => item.price_list_id === priceList,
                              );
                              patch({
                                priceList,
                                price:
                                  price?.final_price != null
                                    ? String(price.final_price)
                                    : "",
                              });
                            }}
                            options={
                              context?.price_lists.length
                                ? context.price_lists.map((item) => ({
                                    value: item.id,
                                    label: `${item.name}${item.is_default ? " · General" : ""}`,
                                  }))
                                : [
                                    {
                                      value: "",
                                      label: "Crear precio general al guardar",
                                    },
                                  ]
                            }
                          />
                        </Field>
                        <p className={styles.hint}>
                          Las listas específicas de sucursal o cliente conservan
                          su prioridad. Este precio se guarda en la lista
                          seleccionada.
                        </p>
                        {!isNew && (
                          <label className={styles.check}>
                            <input
                              type="checkbox"
                              checked={form.active}
                              onChange={(event) =>
                                patch({ active: event.target.checked })
                              }
                            />
                            Platillo activo
                          </label>
                        )}
                      </div>
                    </details>
                  </section>
                )}
              </div>
              <aside
                className={styles.editorSummary}
                aria-label={isDish ? "Resumen del platillo" : "Resumen de la base"}
              >
                <div className={styles.menuPreview}>
                  {form.image ? (
                    <img
                      src={form.image}
                      alt={form.name || "Vista previa del platillo"}
                    />
                  ) : (
                    <div className={styles.previewArt}>
                      {isDish ? (
                        <UtensilsCrossed size={45} strokeWidth={1.25} />
                      ) : (
                        <CookingPot size={45} strokeWidth={1.25} />
                      )}
                      <span>
                        {isDish
                          ? "Hecho en tu cocina"
                          : "La base de una buena receta"}
                      </span>
                    </div>
                  )}
                  <div>
                    <small>
                      {form.category ||
                        (isDish ? "Tu menú" : "Bases reutilizables")}
                    </small>
                    <h3>
                      {form.name ||
                        (isDish ? "Tu próximo platillo" : "Tu próxima base")}
                    </h3>
                    {form.description && <p>{form.description}</p>}
                    {isDish && (
                      <strong>
                        {form.price
                          ? money(numberValue(form.price), currency)
                          : "Precio por definir"}
                      </strong>
                    )}
                  </div>
                </div>
                {canCost ? (
                  <div
                    className={styles.costSummary}
                    aria-live="polite"
                    aria-busy={costWaiting}
                  >
                    <div>
                      <span>
                        {isDish ? "Costo de la receta" : "Costo de la tanda"}
                      </span>
                      <strong>
                        {costWaiting
                          ? "Calculando…"
                          : money(currentCost?.total_cost, currency)}
                      </strong>
                    </div>
                    <div>
                      <span>Rendimiento</span>
                      <strong>
                        {isDish
                          ? portions > 0
                            ? `${portions} ${portions === 1 ? "porción" : "porciones"}`
                            : "Por definir"
                          : `${form.yieldQuantity} ${unitLabel(form.yieldUnit)}`}
                      </strong>
                    </div>
                    <div className={styles.costPerPortion}>
                      <span>
                        {isDish
                          ? "Costo por porción"
                          : `Costo por ${baseCostUnit}`}
                      </span>
                      <strong>
                        {costWaiting
                          ? "…"
                          : money(
                              isDish
                                ? currentCost?.cost_per_portion
                                : currentCost?.total_cost != null &&
                                    numberValue(form.yieldQuantity) > 0
                                  ? (currentCost.total_cost * baseCostScale) /
                                    numberValue(form.yieldQuantity)
                                  : null,
                              currency,
                            )}
                      </strong>
                    </div>
                    {margin && (
                      <div>
                        <span>Margen estimado</span>
                        <strong
                          className={
                            margin.amount < 0 ? styles.negative : undefined
                          }
                        >
                          {margin.percent.toLocaleString("es-MX", {
                            maximumFractionDigits: 1,
                          })}
                          %
                        </strong>
                      </div>
                    )}
                    {currentCost && !currentCost.allowed && (
                      <p className={styles.costWarning}>
                        Falta costo vigente en{" "}
                        {
                          currentCost.lines.filter((line) => line.cost == null)
                            .length
                        }{" "}
                        insumos. Completa sus costos para ver el margen.
                      </p>
                    )}
                    {costError && (
                      <p className={styles.costWarning}>{costError}</p>
                    )}
                    <small>
                      Costos vigentes · {currency}
                      {waste > 0 ? ` · Merma ${waste}%` : ""}
                    </small>
                  </div>
                ) : (
                  <p className={styles.hint}>
                    Tu perfil no permite consultar costos.
                  </p>
                )}
              </aside>
            </div>
          </>
        )}
      </Modal>
      {ingredient && (
        <IngredientEditor
          companyId={companyId}
          permissions={permissions}
          {...ingredient}
          onClose={() => setIngredient(null)}
          onSaved={(item) => {
            setIngredient(null);
            if (lines.some((line) => line.id === item.id)) {
              setLines((current) =>
                current.map((line) =>
                  line.id === item.id
                    ? {
                        ...line,
                        name: item.name,
                        unit: canonicalUnit(item.unit),
                        unit_code: compatibleUnits(item.unit).some(
                          (unit) => unit.value === line.unit_code,
                        )
                          ? line.unit_code
                          : canonicalUnit(item.unit),
                      }
                    : line,
                ),
              );
              setPreview(null);
            } else addIngredient(item);
          }}
        />
      )}
      <Modal
        open={discard}
        onOpenChange={setDiscard}
        labelledBy="restaurant-discard-title"
        title="¿Salir sin guardar la receta?"
        description="Los cambios de esta receta se perderán. Los insumos que ya creaste se conservan en el catálogo."
        footer={
          <>
            <Button onClick={() => setDiscard(false)}>Seguir editando</Button>
            <Button variant="danger" onClick={onClose}>
              Salir sin guardar
            </Button>
          </>
        }
      />
    </>
  );
}
