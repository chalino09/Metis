/* eslint-disable @next/next/no-img-element -- Bounded restaurant-only image data. */
"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import {
  ArrowDownToLine,
  ArrowRight,
  ChefHat,
  Check,
  CookingPot,
  Copy,
  Leaf,
  Plus,
  RefreshCw,
  Search,
  Store,
  UtensilsCrossed,
} from "lucide-react";
import { Badge, Button, Input } from "@/app/components/ui/primitives";
import { RestaurantCatalogImportModal } from "@/app/components/RestaurantCatalogImportModal";
import { getSupabaseClient } from "@/app/lib/supabase";
import {
  money,
  restaurantError,
  unitLabel,
  type CatalogItem,
  type CulinaryRole,
} from "@/app/lib/restaurant/studio";
import { DishEditor } from "./DishEditor";
import { IngredientEditor } from "./IngredientEditor";
import { Select } from "./controls";
import styles from "./restaurant.module.css";

const PAGE_SIZE = 24;
const sections = [
  {
    role: "dish",
    href: "/satrapy/inventario/productos",
    title: "Menú",
    icon: UtensilsCrossed,
  },
  {
    role: "ingredient",
    href: "/satrapy/inventario/productos?seccion=insumos",
    title: "Insumos",
    icon: Leaf,
  },
  {
    role: "preparation",
    href: "/satrapy/inventario/productos?seccion=preparaciones",
    title: "Preparaciones",
    icon: CookingPot,
  },
] as const;
export function RestaurantWorkspace({
  companyId,
  permissions,
}: {
  companyId: string;
  permissions: string[];
}) {
  const params = useSearchParams();
  const role: CulinaryRole =
    params.get("seccion") === "insumos"
      ? "ingredient"
      : params.get("seccion") === "preparaciones"
        ? "preparation"
        : "dish";
  // Each section owns its filters and draft; company switching never reuses another company's editor.
  return (
    <RestaurantSection
      key={`${companyId}:${role}`}
      companyId={companyId}
      permissions={permissions}
      role={role}
    />
  );
}
function RestaurantSection({
  companyId,
  permissions,
  role,
}: {
  companyId: string;
  permissions: string[];
  role: CulinaryRole;
}) {
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [page, setPage] = useState(1);
  const [result, setResult] = useState<{ items: CatalogItem[]; total: number }>(
    { items: [], total: 0 },
  );
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [editor, setEditor] = useState<{
    productId?: string;
    duplicate?: boolean;
    initialStep?: number;
  } | null>(null);
  const [importing, setImporting] = useState(false);
  const [notice, setNotice] = useState("");
  const canManage =
    permissions.includes("manage_products") &&
    (role === "ingredient" ||
      (permissions.includes("manage_recipes") &&
        permissions.includes("view_recipes")));
  const title =
    role === "dish"
      ? "Menú"
      : role === "ingredient"
        ? "Insumos"
        : "Preparaciones";
  const singular =
    role === "dish" ? "platillo" : role === "ingredient" ? "insumo" : "base";
  useEffect(() => {
    const timer = setTimeout(() => {
      setQuery(search);
      setPage(1);
    }, 220);
    return () => clearTimeout(timer);
  }, [search]);
  useEffect(() => {
    let active = true;
    void (async () => {
      setLoading(true);
      setError("");
      try {
        const { data, error: failure } = await getSupabaseClient().rpc(
          "search_restaurant_studio_catalog",
          {
            p_company_id: companyId,
            p_role: role,
            p_query: query.trim() || null,
            p_page: page,
            p_page_size: PAGE_SIZE,
            p_is_sellable: filter === "all" ? null : filter === "available",
          },
        );
        if (failure) throw failure;
        const next = data as { items: CatalogItem[]; total: number };
        if (!active) return;
        setResult(next);
      } catch (failure) {
        if (active) setError(restaurantError(failure));
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => {
      active = false;
    };
  }, [companyId, role, query, page, filter, refresh]);
  const reload = useCallback(async () => {
    setRefresh((value) => value + 1);
  }, []);
  const clearFilters = () => {
    setSearch("");
    setQuery("");
    setFilter("all");
    setPage(1);
  };
  function open(
    item?: CatalogItem,
    extra?: { duplicate?: boolean; initialStep?: number },
  ) {
    setEditor({ productId: item?.id, ...extra });
  }
  return (
    <div className={`content-frame ${styles.workspace}`}>
      <header className={styles.workspaceHeader}>
        <div>
          <div className={styles.eyebrow}>
            <span />
            <ChefHat size={15} aria-hidden="true" />
            Restaurante
          </div>
          <h1>{title}</h1>
          <p>
            {role === "dish"
              ? "Platillos, recetas y precios de venta."
              : role === "ingredient"
                ? "Ingredientes, unidades y costos."
                : "Salsas, caldos y mezclas para tus recetas."}
          </p>
        </div>
        <div className={styles.headerActions}>
          <Button
            variant="ghost"
            size="icon"
            aria-label="Actualizar catálogo"
            disabled={loading}
            onClick={() => void reload()}
          >
            <RefreshCw size={18} />
          </Button>
          {canManage && (
            <Button variant="primary" size="lg" onClick={() => open()}>
              <Plus size={18} />
              {role === "preparation" ? "Crear una base" : `Crear ${singular}`}
            </Button>
          )}
        </div>
      </header>
      <nav className={styles.navigation} aria-label="Restaurante">
        {sections.map((section) => (
          <Link
            key={section.role}
            href={section.href}
            className={role === section.role ? styles.activeNav : undefined}
            aria-current={role === section.role ? "page" : undefined}
          >
            <section.icon size={18} aria-hidden="true" />
            {section.title}
          </Link>
        ))}
        <div className={styles.navSpacer} />
        {permissions.includes("view_purchase_receipts") && (
          <Link
            href="/satrapy/compras/recepciones"
            className={styles.navUtility}
          >
            <ArrowDownToLine size={16} />
            Entradas de insumos
          </Link>
        )}
      </nav>
      {notice && (
        <div role="status" className={styles.savedNotice}>
          <Check size={17} />
          <span>{notice}</span>
          <button
            aria-label="Ocultar confirmación"
            onClick={() => setNotice("")}
          >
            ×
          </button>
        </div>
      )}
      <section className={styles.guide}>
        <span className={styles.guideIcon}>
          {role === "dish" ? (
            <UtensilsCrossed size={26} strokeWidth={1.5} />
          ) : role === "ingredient" ? (
            <Leaf size={26} strokeWidth={1.5} />
          ) : (
            <CookingPot size={26} strokeWidth={1.5} />
          )}
        </span>
        <div>
          <h2>
            {role === "dish"
              ? "Crear platillo"
              : role === "ingredient"
                ? "Importar insumos"
                : "Crear preparación"}
          </h2>
          <p>
            {role === "dish"
              ? "Agrega ingredientes, porciones y precio."
              : role === "ingredient"
                ? "Carga varios insumos desde un archivo."
                : "Agrega ingredientes e indica cuánto rinde."}
          </p>
        </div>
        {role === "dish" ? (
          <div className={styles.guideSteps}>
            <span>Receta</span>
            <ArrowRight size={14} />
            <span>Precio</span>
            <ArrowRight size={14} />
            <span>POS</span>
          </div>
        ) : role === "ingredient" && canManage ? (
          <Button variant="secondary" onClick={() => setImporting(true)}>
            <ArrowDownToLine size={16} />
            Importar insumos
          </Button>
        ) : null}
      </section>
      <div className={styles.toolbar}>
        <div className={styles.catalogSearch}>
          <Search size={18} aria-hidden="true" />
          <Input
            aria-label={`Buscar ${role === "dish" ? "en el menú" : role === "ingredient" ? "insumos" : "bases"}`}
            placeholder={
              role === "dish"
                ? "Buscar un platillo…"
                : role === "ingredient"
                  ? "Buscar por nombre, código o alias…"
                  : "Buscar una base…"
            }
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>
        <Select
          ariaLabel="Filtrar catálogo"
          value={filter}
          onValueChange={(value) => {
            setFilter(value);
            setPage(1);
          }}
          options={[
            {
              value: "all",
              label:
                role === "dish"
                  ? "Todo el menú"
                  : role === "ingredient"
                    ? "Todos los insumos"
                    : "Todas las bases",
            },
            {
              value: "available",
              label: role === "dish" ? "Venta habilitada" : "Activos",
            },
            {
              value: "paused",
              label: role === "dish" ? "Venta deshabilitada" : "Inactivos",
            },
          ]}
        />
        <span className={styles.resultCount} role="status">
          {loading
            ? "Actualizando…"
            : `${result.total} ${result.total === 1 ? singular : role === "dish" ? "platillos" : role === "ingredient" ? "insumos" : "bases"}`}
        </span>
        {(search || filter !== "all") && (
          <Button variant="ghost" onClick={clearFilters}>
            Limpiar
          </Button>
        )}
      </div>
      {error ? (
        <div className={styles.loadError}>
          <p role="alert">{error}</p>
          <Button onClick={() => void reload()}>Reintentar</Button>
        </div>
      ) : loading && !result.items.length ? (
        <div
          className={styles.skeletons}
          aria-label="Cargando catálogo"
          role="status"
        >
          {Array.from({ length: 6 }, (_, index) => (
            <div key={index} />
          ))}
        </div>
      ) : !result.items.length ? (
        <div className={styles.emptyCatalog}>
          <ChefHat size={42} strokeWidth={1.3} />
          <h2>
            {search || filter !== "all"
              ? "No encontramos coincidencias"
              : `Aquí comienza tu ${role === "dish" ? "menú" : role === "ingredient" ? "despensa" : "recetario de bases"}`}
          </h2>
          <p>
            {search || filter !== "all"
              ? "Prueba otro nombre o limpia los filtros."
              : `Crea ${role === "preparation" ? "una base" : `tu primer ${singular}`} para comenzar.`}
          </p>
          {search || filter !== "all" ? (
            <Button onClick={clearFilters}>Limpiar filtros</Button>
          ) : (
            canManage && (
              <Button variant="primary" onClick={() => open()}>
                <Plus size={17} />
                Crear {singular}
              </Button>
            )
          )}
        </div>
      ) : role === "ingredient" ? (
        <div className={styles.pantry} aria-busy={loading}>
          <div className={styles.pantryHead}>
            <span>Insumo</span>
            <span>Cómo lo compras</span>
            <span>En tus recetas</span>
            <span />
          </div>
          {result.items.map((item) => (
            <div key={item.id} className={styles.pantryRow}>
              <div className={styles.ingredientName}>
                <span className={styles.ingredientIcon}>
                  <Leaf size={20} />
                </span>
                <div>
                  <button
                    className={styles.itemTitle}
                    disabled={!canManage}
                    onClick={() => open(item)}
                  >
                    {item.name}
                  </button>
                  <small>
                    {item.product_group ?? "Sin categoría"} ·{" "}
                    {item.internal_sku}
                  </small>
                </div>
              </div>
              <div>
                <strong>
                  {item.purchase_unit_code || "Presentación pendiente"}
                </strong>
                <small>
                  {item.base_units_per_purchase_unit
                    ? `${Number(item.base_units_per_purchase_unit).toLocaleString("es-MX")} ${unitLabel(item.unit)} por presentación`
                    : "Completa su contenido"}
                </small>
              </div>
              <div>
                <strong>{item.usage_count ?? 0} recetas</strong>
                <small>Se mide en {unitLabel(item.unit)}</small>
              </div>
              <Badge tone={item.is_active ? "success" : "neutral"}>
                {item.is_active ? "Activo" : "Inactivo"}
              </Badge>
            </div>
          ))}
        </div>
      ) : (
        <div className={styles.menuGrid} aria-busy={loading}>
          {result.items.map((item) => (
            <article key={item.id} className={styles.dishCard}>
              <button
                className={styles.cardOpen}
                aria-label={`Editar ${singular} ${item.name}`}
                disabled={!canManage}
                onClick={() => open(item)}
              >
                <div className={styles.cardImage}>
                  {item.image_data ? (
                    <img src={item.image_data} alt="" loading="lazy" />
                  ) : (
                    <div className={styles.dishArt}>
                      <span>
                        {role === "preparation" ? (
                          <CookingPot size={34} strokeWidth={1.3} />
                        ) : (
                          <UtensilsCrossed size={34} strokeWidth={1.3} />
                        )}
                      </span>
                      <small>
                        {item.product_group ||
                          (role === "dish"
                            ? "De nuestra cocina"
                            : "Preparación de la casa")}
                      </small>
                    </div>
                  )}
                  <span
                    className={`${styles.cardStatus} ${!item.is_active ? styles.pausedStatus : item.recipe_status !== "active" ? styles.draftStatus : (item.ready_location_count ?? 0) > 0 || role === "preparation" ? styles.readyStatus : item.is_sellable ? styles.draftStatus : styles.pausedStatus}`}
                  >
                    <span />
                    {!item.is_active
                      ? "Inactivo"
                      : item.recipe_status !== "active"
                        ? item.recipe_status === "draft"
                          ? "En preparación"
                          : "Falta receta"
                        : role === "preparation"
                          ? "Lista para usar"
                          : (item.ready_location_count ?? 0) > 0
                            ? "Disponible en POS"
                            : item.is_sellable
                              ? "POS pendiente"
                              : "Venta deshabilitada"}
                  </span>
                </div>
                <div className={styles.cardBody}>
                  <span className={styles.cardCategory}>
                    {item.product_group ||
                      (role === "dish" ? "Platillo" : "Base reutilizable")}
                  </span>
                  <h2>{item.name}</h2>
                  <div className={styles.cardDetails}>
                    <span>
                      <ChefHat size={14} />
                      {item.recipe_status === "active"
                        ? "Receta lista"
                        : "Receta por completar"}
                    </span>
                    {role === "dish" ? (
                      <strong>
                        {item.price != null
                          ? money(item.price, item.currency_code ?? "MXN")
                          : "Sin precio"}
                      </strong>
                    ) : (
                      <strong>
                        {item.recipe_yield_quantity
                          ? `${Number(item.recipe_yield_quantity).toLocaleString("es-MX")} ${unitLabel(item.recipe_yield_unit_code ?? "")}`
                          : "Sin rendimiento"}
                      </strong>
                    )}
                  </div>
                </div>
              </button>
              <footer
                className={styles.cardFooter}
                title={item.location_status
                  ?.filter((location) => !location.available)
                  .map((location) => `${location.name}: ${location.message}`)
                  .join(" ")}
              >
                <span>
                  {role === "dish" ? (
                    <>
                      <Store size={14} />
                      {item.offered_location_count ?? 0}{" "}
                      {(item.offered_location_count ?? 0) === 1
                        ? "sucursal"
                        : "sucursales"}
                    </>
                  ) : (
                    <>
                      <CookingPot size={14} />
                      En {item.usage_count ?? 0} recetas
                    </>
                  )}
                </span>
                {canManage && (
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label={`Crear variante de ${item.name}`}
                    onClick={() => open(item, { duplicate: true })}
                  >
                    <Copy size={15} />
                  </Button>
                )}
                {canManage && (
                  <button
                    className={styles.textButton}
                    onClick={() =>
                      open(item, {
                        initialStep:
                          role === "dish" && item.recipe_status === "active"
                            ? 3
                            : 1,
                      })
                    }
                  >
                    {item.recipe_status === "active" ? "Editar" : "Completar"}
                    <ArrowRight size={14} />
                  </button>
                )}
              </footer>
            </article>
          ))}
        </div>
      )}
      {!error && result.total > PAGE_SIZE && (
        <div className={styles.pagination}>
          <span>
            Página {page} de {Math.ceil(result.total / PAGE_SIZE)}
          </span>
          <div>
            <Button
              disabled={page === 1 || loading}
              onClick={() => setPage((value) => value - 1)}
            >
              Anterior
            </Button>
            <Button
              disabled={page * PAGE_SIZE >= result.total || loading}
              onClick={() => setPage((value) => value + 1)}
            >
              Siguiente
            </Button>
          </div>
        </div>
      )}
      {role === "dish" &&
        permissions.some((permission) =>
          ["import_data", "import_prices", "import_costs"].includes(permission),
        ) && (
          <p className={styles.importNote}>
            ¿Tienes un recetario completo?{" "}
            <Link href="/satrapy/configuracion/importaciones">
              Importar recetas e insumos por lote
              <ArrowRight size={14} />
            </Link>
          </p>
        )}
      {editor &&
        (role === "ingredient" ? (
          <IngredientEditor
            companyId={companyId}
            permissions={permissions}
            productId={editor.productId}
            onClose={() => setEditor(null)}
            onSaved={(item) => {
              setEditor(null);
              setNotice(`${item.name}: insumo guardado.`);
              void reload();
            }}
          />
        ) : (
          <DishEditor
            key={`${editor.productId ?? "new"}:${Boolean(editor.duplicate)}`}
            companyId={companyId}
            permissions={permissions}
            kind={role}
            {...editor}
            onClose={() => setEditor(null)}
            onSaved={(item) => {
              setEditor(null);
              setNotice(
                `${item.name}: ${item.available ? "venta habilitada" : "guardado"}.`,
              );
              void reload();
            }}
          />
        ))}
      <RestaurantCatalogImportModal
        companyId={companyId}
        role="ingredient"
        open={importing}
        onOpenChange={setImporting}
        onImported={reload}
      />
    </div>
  );
}
