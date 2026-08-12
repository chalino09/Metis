"use client";

import { Store } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Badge, Button, Modal, useToast } from "@/app/components/ui/primitives";
import { productReadinessSummary } from "@/app/lib/product-readiness";
import { productVocabulary, type ProductExperience } from "@/app/lib/product-experience";
import { getSupabaseClient } from "@/app/lib/supabase";

type AssortmentLocation = { id: string; code: string; name: string };
type AssortmentOption = {
  id: string;
  code: string;
  name: string;
  status: "draft" | "active" | "inactive";
  included: boolean;
  locations: AssortmentLocation[];
};
type CommercialContext = {
  product: { id: string; code: string; name: string; is_sellable: boolean };
  assortments: AssortmentOption[];
  included_assortment_count: number;
  offered_location_count: number;
  commercial_readiness: { pos_ready: boolean; blockers?: string[] };
};

function statusLabel(status: AssortmentOption["status"]) {
  return status === "active" ? "Activo" : status === "draft" ? "Borrador" : "Inactivo";
}

export function ProductCommercializationModal({
  companyId,
  product,
  open,
  initialReason,
  experience="core",
  onOpenChange,
  onSaved,
}: {
  companyId: string;
  product: { id: string; name: string } | null;
  open: boolean;
  initialReason: string;
  experience?: ProductExperience;
  onOpenChange: (open: boolean) => void;
  onSaved?: () => Promise<void> | void;
}) {
  const words = productVocabulary(experience);
  const { toast } = useToast();
  const [context, setContext] = useState<CommercialContext | null>(null);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [reason, setReason] = useState(initialReason);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!open || !product) return;
    setLoading(true);
    setError(null);
    const { data, error: contextError } = await getSupabaseClient().rpc("get_product_sales_assortment_context", {
      p_company_id: companyId,
      p_product_id: product.id,
    });
    if (contextError || !data) {
      setContext(null);
      setError(`No se pudo cargar la comercialización del ${words.singular}. Verifica la actualización de la base e intenta nuevamente.`);
    } else {
      const next = data as CommercialContext;
      setContext(next);
      setSelectedIds(next.assortments.filter((assortment) => assortment.included).map((assortment) => assortment.id));
    }
    setLoading(false);
  }, [companyId, open, product, words.singular]);

  useEffect(() => {
    void Promise.resolve().then(() => {
      setReason(initialReason);
      return load();
    });
  }, [initialReason, load]);

  function toggle(id: string) {
    setSelectedIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  }

  async function save() {
    if (!product || !reason.trim()) return;
    setSaving(true);
    const { data, error: saveError } = await getSupabaseClient().rpc("set_product_sales_assortments", {
      p_company_id: companyId,
      p_product_id: product.id,
      p_assortment_ids: selectedIds,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (saveError) {
      toast({ title: "No se pudo guardar la comercialización", description: saveError.message, tone: "error" });
      return;
    }
    const result = data as { assortments?: number } | null;
    toast({
      title: "Disponibilidad actualizada",
      description: result?.assortments
        ? `El ${words.singular} quedó disponible en ${result.assortments} catálogo${result.assortments === 1 ? "" : "s"} de sucursal.`
        : `El ${words.singular} no estará disponible en ninguna sucursal.`,
      tone: "success",
    });
    await onSaved?.();
    onOpenChange(false);
  }

  const blockers = context?.commercial_readiness.blockers ?? [];
  const readinessText = context?.commercial_readiness.pos_ready
    ? "Configuración comercial completa"
    : productReadinessSummary(blockers);

  return (
    <Modal
      open={open}
      onOpenChange={(nextOpen) => !saving && onOpenChange(nextOpen)}
      eyebrow="Disponibilidad comercial"
      title={product?.name ?? words.singularTitle}
      description="Elige en qué sucursales se ofrecerá. Esta decisión no modifica precios ni existencias."
      footer={<>
        <Button variant="secondary" disabled={saving} onClick={() => onOpenChange(false)}>Cerrar</Button>
        <Button variant="primary" loading={saving} disabled={loading || !context || !reason.trim()} onClick={() => void save()}>Guardar disponibilidad</Button>
      </>}
    >
      {loading && <p className="product-commercialization__state">Cargando sucursales…</p>}
      {error && <div className="product-commercialization__error"><p>{error}</p><Button size="sm" onClick={() => void load()}>Reintentar</Button></div>}
      {!loading && context && <>
        <div className="product-commercialization__summary">
          <article><span>Configuración</span><strong>{readinessText}</strong></article>
          <article><span>Catálogos</span><strong>{selectedIds.length}</strong></article>
          <article><span>Sucursales activas</span><strong>{context.offered_location_count}</strong></article>
        </div>
        {!context.assortments.length ? (
          <div className="product-commercialization__empty">
            <Store size={20} />
            <div><strong>Aún no hay productos configurados por sucursal</strong><p>Abre Configuración → Productos por sucursal, crea el primer catálogo y después regresa a este {words.singular}.</p></div>
          </div>
        ) : (
          <fieldset className="product-commercialization__options">
            <legend>Catálogos por sucursal</legend>
            {context.assortments.map((assortment) => (
              <label key={assortment.id}>
                <input type="checkbox" checked={selectedIds.includes(assortment.id)} onChange={() => toggle(assortment.id)} />
                <span className="product-commercialization__option-copy">
                  <span><strong>{assortment.name}</strong><Badge tone={assortment.status === "active" ? "success" : assortment.status === "draft" ? "info" : "neutral"}>{statusLabel(assortment.status)}</Badge></span>
                  <small>{assortment.code}</small>
                  <span className="product-commercialization__locations">
                    {assortment.locations.length
                      ? assortment.locations.map((location) => <em key={location.id}>{location.name}</em>)
                      : <em>Sin sucursales asignadas</em>}
                  </span>
                </span>
              </label>
            ))}
          </fieldset>
        )}
        <label className="operation-reason product-commercialization__reason">
          Motivo obligatorio
          <textarea required rows={2} value={reason} onChange={(event) => setReason(event.target.value)} placeholder={`Ej. Habilitar ${words.singular} en la sucursal`} />
        </label>
        <p className="product-commercialization__note">El POS sólo lo ofrecerá en las sucursales de un catálogo activo y seguirá validando precio, impuesto y existencia.</p>
      </>}
    </Modal>
  );
}
