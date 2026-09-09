"use client";
import { Plus, Trash2, Soup, GlassWater } from "lucide-react";
import { Field } from "@/app/components/ui/primitives";
import { OperationalButton as Button, OperationalInput as Input } from "@/app/components/reui/operational-controls";
import { ComponentPicker } from "./ComponentPicker";
import { useEffect, useId, useRef } from "react";
import { bundleIssues, nextBundleGroupName, type BundleDraft } from "@/app/lib/restaurant/studio";
import styles from "./restaurant.module.css";

export function BundleEditor({
  companyId,
  productId,
  value,
  onChange,
  showErrors = false,
}: {
  companyId: string;
  productId?: string;
  value: BundleDraft | null;
  onChange: (value: BundleDraft) => void;
  showErrors?: boolean;
}) {
  const id = useId();
  const disclosureRef = useRef<HTMLDetailsElement>(null);
  const issues = showErrors ? bundleIssues(value) : [];
  const hasIssues = issues.length > 0;
  useEffect(() => {
    if (hasIssues && disclosureRef.current) disclosureRef.current.open = true;
  }, [hasIssues]);
  const priceError = issues.find(issue => issue.field === "price");
  const bundle = value ?? {
    is_active: false,
    combo_price_amount: "",
    groups: [
      {
        name: "Sopa",
        minimum_selections: 1,
        maximum_selections: 1,
        options: [],
      },
      {
        name: "Agua",
        minimum_selections: 1,
        maximum_selections: 1,
        options: [],
      },
    ],
    extras: [],
  };
  return (
    <details ref={disclosureRef} className={styles.disclosure} data-bundle-editor>
      <summary>
        Comida completa y extras <span>Opcional</span>
      </summary>
      <div className={styles.formStack}>
        <p className={styles.hint}>
          Usa platillos que ya están en el menú. Cada opción conserva su receta
          y los extras se cobran a su precio vigente.
        </p>
        <label className={styles.check}>
          <input
            type="checkbox"
            checked={bundle.is_active}
            onChange={(event) =>
              onChange({ ...bundle, is_active: event.target.checked })
            }
          />
          Ofrecer también como comida completa
        </label>
        {bundle.is_active && (
          <>
            <Field label="Precio de la comida completa, con impuesto">
              <Input
                type="number"
                min="0.01"
                step="0.01"
                value={bundle.combo_price_amount ?? ""}
                aria-invalid={Boolean(priceError) || undefined}
                aria-describedby={priceError ? `${id}-price-error` : undefined}
                onChange={(event) =>
                  onChange({
                    ...bundle,
                    combo_price_amount: event.target.value,
                  })
                }
                placeholder="Ej. 180.00"
              />
              {priceError && <small id={`${id}-price-error`} className={styles.fieldError}>{priceError.message}</small>}
            </Field>
            <p className={styles.hint}>En cada grupo, selecciona los platillos incluidos. Escribir el nombre del grupo no agrega una opción.</p>
            {issues.some(issue => issue.field === "groups") && <p className={styles.fieldError}>{issues.find(issue => issue.field === "groups")!.message}</p>}
            {bundle.groups.map((group, index) => {
              const nameError = issues.find(issue => issue.field === "name" && issue.groupIndex === index);
              const optionsError = issues.find(issue => issue.field === "options" && issue.groupIndex === index);
              return (
              <section key={index} className={styles.bundleGroup}>
                <header>
                  {index === 0 ? (
                    <Soup size={20} aria-hidden="true" />
                  ) : (
                    <GlassWater size={20} aria-hidden="true" />
                  )}
                  <Field label="Nombre del grupo">
                    <Input
                      value={group.name}
                      aria-invalid={Boolean(nameError) || undefined}
                      aria-describedby={nameError ? `${id}-${index}-name-error` : undefined}
                      onChange={(event) =>
                        onChange({
                          ...bundle,
                          groups: bundle.groups.map((g, i) =>
                            i === index
                              ? { ...g, name: event.target.value }
                              : g,
                          ),
                        })
                      }
                    />
                    {nameError && <small id={`${id}-${index}-name-error`} className={styles.fieldError}>{nameError.message}</small>}
                  </Field>
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={`Quitar grupo ${group.name}`}
                    onClick={() =>
                      onChange({
                        ...bundle,
                        groups: bundle.groups.filter((_, i) => i !== index),
                      })
                    }
                  >
                    <Trash2 size={16} />
                  </Button>
                </header>
                <div className={styles.chips}>
                  {group.options.map((item) => (
                    <span key={item.id}>
                      {item.name}
                      <button
                        type="button"
                        aria-label={`Quitar ${item.name} de ${group.name}`}
                        onClick={() =>
                          onChange({
                            ...bundle,
                            groups: bundle.groups.map((g, i) =>
                              i === index
                                ? {
                                    ...g,
                                    options: g.options.filter(
                                      (option) => option.id !== item.id,
                                    ),
                                  }
                                : g,
                            ),
                          })
                        }
                      >
                        ×
                      </button>
                    </span>
                  ))}
                </div>
                <ComponentPicker
                  companyId={companyId}
                  dishes
                  excludeId={productId}
                  label={`Agregar opción de ${group.name.toLowerCase()}`}
                  errorMessage={optionsError?.message}
                  selectedIds={group.options.map((item) => item.id)}
                  onSelect={(item) =>
                    onChange({
                      ...bundle,
                      groups: bundle.groups.map((g, i) =>
                        i === index
                          ? {
                              ...g,
                              options: [
                                ...g.options,
                                { id: item.id, name: item.name },
                              ],
                            }
                          : g,
                      ),
                    })
                  }
                />
              </section>
            );})}
            {bundle.groups.length < 10 && (
              <Button
                variant="ghost"
                onClick={() =>
                  onChange({
                    ...bundle,
                    groups: [
                      ...bundle.groups,
                      {
                        name: nextBundleGroupName(bundle.groups),
                        minimum_selections: 1,
                        maximum_selections: 1,
                        options: [],
                      },
                    ],
                  })
                }
              >
                <Plus size={16} />
                Agregar grupo de opciones
              </Button>
            )}
            <div className={styles.chips}>
              {bundle.extras.map((item) => (
                <span key={item.id}>
                  {item.name}
                  <button
                    type="button"
                    aria-label={`Quitar extra ${item.name}`}
                    onClick={() =>
                      onChange({
                        ...bundle,
                        extras: bundle.extras.filter(
                          (option) => option.id !== item.id,
                        ),
                      })
                    }
                  >
                    ×
                  </button>
                </span>
              ))}
            </div>
            <ComponentPicker
              companyId={companyId}
              dishes
              excludeId={productId}
              label="Agregar extra con costo adicional"
              selectedIds={bundle.extras.map((item) => item.id)}
              onSelect={(item) =>
                onChange({
                  ...bundle,
                  extras: [...bundle.extras, { id: item.id, name: item.name }],
                })
              }
            />
            <p className={styles.hint}>
              El margen mostrado arriba corresponde al platillo solo. La comida
              completa depende de las opciones elegidas.
            </p>
          </>
        )}
      </div>
    </details>
  );
}
