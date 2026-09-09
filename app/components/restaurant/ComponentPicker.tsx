"use client";

import { useEffect, useId, useRef, useState } from "react";
import { CookingPot, Leaf, Plus, Search } from "lucide-react";

import { OperationalButton as Button, OperationalInput as Input } from "@/app/components/reui/operational-controls";
import { getSupabaseClient } from "@/app/lib/supabase";
import {
  restaurantError,
  unitLabel,
  type ComponentOption,
} from "@/app/lib/restaurant/studio";
import styles from "./restaurant.module.css";

export function ComponentPicker({
  companyId,
  selectedIds,
  onSelect,
  onCreate,
  dishes = false,
  label = "Buscar insumo o base",
  excludeId,
  errorMessage,
}: {
  companyId: string;
  selectedIds: string[];
  onSelect: (item: ComponentOption) => void;
  onCreate?: (name: string) => void;
  dishes?: boolean;
  label?: string;
  excludeId?: string;
  errorMessage?: string;
}) {
  const id = useId();
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<ComponentOption[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [activeIndex, setActiveIndex] = useState(-1);
  const [loadedQuery, setLoadedQuery] = useState<string | null>(null);
  const ref = useRef<HTMLInputElement>(null);
  const available = items.filter(
    (item) => item.id !== excludeId && !selectedIds.includes(item.id),
  );
  const normalized = (value: string) =>
    value
      .trim()
      .normalize("NFD")
      .replace(/\p{Diacritic}/gu, "")
      .toLocaleLowerCase("es-MX");
  const exactMatch = items.some(
    (item) => normalized(item.name) === normalized(query),
  );
  useEffect(() => {
    if (!open) return;
    let active = true;
    const timer = setTimeout(async () => {
      setLoading(true);
      setError("");
      try {
        const { data, error: failure } = await getSupabaseClient().rpc(
          dishes
            ? "search_restaurant_catalog"
            : "search_restaurant_recipe_components",
          {
            p_company_id: companyId,
            p_query: query.trim() || null,
            p_page: 1,
            p_page_size: 20,
            ...(dishes ? { p_role: "dish", p_is_sellable: true } : {}),
          },
        );
        if (!active) return;
        if (failure) throw failure;
        setItems((data as { items?: ComponentOption[] })?.items ?? []);
        setLoadedQuery(query);
        setActiveIndex(-1);
      } catch (failure) {
        if (active) {
          setError(restaurantError(failure));
          setItems([]);
          setLoadedQuery(query);
        }
      } finally {
        if (active) setLoading(false);
      }
    }, 180);
    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [companyId, dishes, open, query]);
  function select(item: ComponentOption) {
    onSelect(item);
    setQuery("");
    setOpen(false);
    setActiveIndex(-1);
    ref.current?.focus();
  }
  const waiting = loading || loadedQuery !== query;
  return (
    <div
      className={styles.picker}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false);
      }}
    >
      <label htmlFor={id} className={styles.inputLabel}>
        {label}
      </label>
      <div className={styles.searchControl}>
        <Search size={18} aria-hidden="true" />
        <Input
          id={id}
          ref={ref}
          value={query}
          placeholder={
            dishes
              ? "Buscar en el menú…"
              : "Escribe arrachera, tortilla, salsa…"
          }
          autoComplete="off"
          aria-invalid={Boolean(errorMessage) || undefined}
          aria-describedby={errorMessage ? `${id}-error` : undefined}
          role="combobox"
          aria-autocomplete="list"
          aria-expanded={open}
          aria-controls={`${id}-list`}
          aria-activedescendant={
            open && !waiting && activeIndex >= 0
              ? `${id}-option-${activeIndex}`
              : undefined
          }
          onFocus={() => setOpen(true)}
          onChange={(event) => {
            setQuery(event.target.value);
            setOpen(true);
            setActiveIndex(-1);
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape" && open) {
              event.preventDefault();
              event.stopPropagation();
              setOpen(false);
            }
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              setOpen(true);
              if (!waiting)
                setActiveIndex((index) =>
                  event.key === "ArrowDown"
                    ? Math.min(index + 1, available.length - 1)
                    : Math.max(index - 1, 0),
                );
            }
            if (event.key === "Enter") {
              event.preventDefault();
              if (open && !waiting && available[activeIndex])
                select(available[activeIndex]);
            }
          }}
        />
      </div>
      {errorMessage && <p id={`${id}-error`} className={styles.fieldError}>{errorMessage}</p>}
      {open && (
        <div className={styles.pickerPopover}>
          <div className={styles.pickerHeading}>
            {query
              ? "Coincidencias del catálogo"
              : dishes
                ? "Platillos del menú"
                : "Insumos y bases disponibles"}
          </div>
          {waiting ? (
            <p role="status">Buscando…</p>
          ) : error ? (
            <p role="alert" className={styles.error}>
              {error}
            </p>
          ) : null}
          <div
            id={`${id}-list`}
            role="listbox"
            aria-label={label}
            className={styles.pickerList}
          >
            {!waiting &&
              !error &&
              available.map((item, index) => (
                <button
                  type="button"
                  key={item.id}
                  id={`${id}-option-${index}`}
                  role="option"
                  aria-selected={activeIndex === index}
                  tabIndex={-1}
                  className={styles.pickerOption}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => select(item)}
                >
                  <span className={styles.ingredientIcon}>
                    {item.catalog_role === "preparation" ? (
                      <CookingPot size={19} aria-hidden="true" />
                    ) : (
                      <Leaf size={19} aria-hidden="true" />
                    )}
                  </span>
                  <span>
                    <strong>{item.name}</strong>
                    <small>
                      {item.catalog_role === "preparation"
                        ? "Base preparada"
                        : dishes
                          ? "Platillo"
                          : "Insumo"}{" "}
                      · {unitLabel(item.unit)}
                    </small>
                  </span>
                  <Plus size={17} aria-hidden="true" />
                </button>
              ))}
          </div>
          {!waiting && !error && !available.length && (
            <p>No hay más coincidencias. Prueba otro nombre.</p>
          )}
          {onCreate && !waiting && !error && !exactMatch && (
            <Button
              variant="ghost"
              className={styles.inlineCreate}
              onClick={() => {
                setOpen(false);
                onCreate(query.trim());
                setQuery("");
              }}
            >
              <Plus size={16} aria-hidden="true" />
              Crear{" "}
              {query.trim()
                ? `“${query.trim()}” como insumo`
                : "un insumo nuevo"}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
