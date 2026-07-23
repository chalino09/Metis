"use client";

import { Boxes, RefreshCw, Trash2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { DataPagination, DataState, DataToolbar } from "@/app/components/ui/data";
import { Badge, Button, Modal, Select, useToast } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

const PAGE_SIZE = 50;

type Assortment = { id: string; code: string; name: string; status: "draft" | "active" | "inactive" };
type Location = { id: string; external_code: string; name: string };
type Assignment = { id: string; location_id: string };
type MembershipItem = { product_id: string; code: string | null; name: string; included: boolean };
type MembershipResult = { items: MembershipItem[]; total: number; member_count: number; page: number; page_size: number };

export function CommercialAssortmentsView({ companyId }: { companyId: string }) {
  const { toast } = useToast();
  const [assortments, setAssortments] = useState<Assortment[]>([]);
  const [locations, setLocations] = useState<Location[]>([]);
  const [catalogTotal, setCatalogTotal] = useState(0);
  const [selectedId, setSelectedId] = useState("");
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [membership, setMembership] = useState<MembershipResult | null>(null);
  const [selectedProductIds, setSelectedProductIds] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [membershipFilter, setMembershipFilter] = useState<"all" | "included" | "excluded">("all");
  const [page, setPage] = useState(1);
  const [newCode, setNewCode] = useState("SURTIDO-GENERAL");
  const [newName, setNewName] = useState("Surtido general");
  const [newLocationIds, setNewLocationIds] = useState<string[]>([]);
  const [locationId, setLocationId] = useState("");
  const [confirmation, setConfirmation] = useState<"create" | "refresh" | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestId = useRef(0);

  const selected = assortments.find((assortment) => assortment.id === selectedId) ?? null;

  const loadBase = useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = getSupabaseClient();
    const [assortmentResult, locationResult, productResult] = await Promise.all([
      supabase.from("sales_assortments").select("id, code, name, status").eq("company_id", companyId).order("name"),
      supabase.from("locations").select("id, external_code, name").eq("company_id", companyId).eq("is_active", true).eq("location_type", "sucursal").order("name"),
      supabase.from("products").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("is_sellable", true),
    ]);
    if (assortmentResult.error || locationResult.error || productResult.error) {
      setError("No se pudo cargar la configuración de surtidos.");
      setLoading(false);
      return;
    }
    const nextAssortments = (assortmentResult.data ?? []) as Assortment[];
    const nextLocations = (locationResult.data ?? []) as Location[];
    setAssortments(nextAssortments);
    setLocations(nextLocations);
    setCatalogTotal(productResult.count ?? 0);
    setNewLocationIds((current) => {
      const valid = current.filter((id) => nextLocations.some((location) => location.id === id));
      return valid.length ? valid : nextLocations.map((location) => location.id);
    });
    setSelectedId((current) => nextAssortments.some((item) => item.id === current) ? current : nextAssortments[0]?.id ?? "");
    setLoading(false);
  }, [companyId]);

  const loadSelected = useCallback(async () => {
    if (!selectedId) {
      setAssignments([]);
      setMembership(null);
      return;
    }
    const current = ++requestId.current;
    setLoading(true);
    setError(null);
    const supabase = getSupabaseClient();
    const [membershipResult, assignmentResult] = await Promise.all([
      supabase.rpc("list_sales_assortment_membership", {
        p_company_id: companyId,
        p_assortment_id: selectedId,
        p_query: debouncedQuery || null,
        p_membership: membershipFilter === "all" ? null : membershipFilter,
        p_page: page,
        p_page_size: PAGE_SIZE,
      }),
      supabase.from("location_sales_assortments").select("id, location_id").eq("assortment_id", selectedId).is("valid_to", null),
    ]);
    if (current !== requestId.current) return;
    if (membershipResult.error || assignmentResult.error) {
      setError("No se pudo cargar el surtido.");
      setLoading(false);
      return;
    }
    setMembership(membershipResult.data as MembershipResult);
    setAssignments((assignmentResult.data ?? []) as Assignment[]);
    setSelectedProductIds([]);
    setLoading(false);
  }, [companyId, debouncedQuery, membershipFilter, page, selectedId]);

  useEffect(() => { void Promise.resolve().then(loadBase); }, [loadBase]);
  useEffect(() => { void Promise.resolve().then(loadSelected); }, [loadSelected]);
  useEffect(() => {
    const timer = window.setTimeout(() => { setDebouncedQuery(query.trim()); setPage(1); }, 280);
    return () => window.clearTimeout(timer);
  }, [query]);

  function requestCreate(event: React.FormEvent) {
    event.preventDefault();
    if (newCode.trim() && newName.trim() && newLocationIds.length) setConfirmation("create");
  }

  async function createAssortment() {
    setBusy(true);
    const { data, error: createError } = await getSupabaseClient().rpc("prepare_pos_operation", {
      p_company_id: companyId,
      p_code: newCode.trim(),
      p_name: newName.trim(),
      p_location_ids: newLocationIds,
    });
    setBusy(false);
    if (createError || !data) {
      toast({ title: "No se pudo crear el surtido", description: createError?.message ?? "Intenta de nuevo.", tone: "error" });
      return;
    }
    const result = data as { assortment_id: string; products_processed: number; locations_assigned: number };
    setConfirmation(null);
    await loadBase();
    setSelectedId(result.assortment_id);
    toast({ title: "Surtido creado", description: `${result.products_processed.toLocaleString("es-MX")} productos y ${result.locations_assigned} sucursal${result.locations_assigned === 1 ? "" : "es"}.`, tone: "success" });
  }

  async function changeStatus(status: string) {
    if (!selected) return;
    setBusy(true);
    const { error: updateError } = await getSupabaseClient().from("sales_assortments").update({ status }).eq("id", selected.id);
    setBusy(false);
    if (updateError) {
      toast({ title: "No se pudo cambiar el estado", description: updateError.message, tone: "error" });
      return;
    }
    await loadBase();
    toast({ title: "Estado actualizado", description: `El surtido quedó ${status === "active" ? "activo" : status === "draft" ? "en borrador" : "inactivo"}.`, tone: "success" });
  }

  async function refreshCatalog() {
    if (!selected) return;
    setBusy(true);
    const { data, error: refreshError } = await getSupabaseClient().rpc("refresh_pos_assortment_catalog", { p_company_id: companyId, p_assortment_id: selected.id });
    setBusy(false);
    if (refreshError || !data) {
      toast({ title: "No se pudieron incorporar productos", description: refreshError?.message ?? "Intenta de nuevo.", tone: "error" });
      return;
    }
    const result = data as { products_added: number };
    setConfirmation(null);
    await loadSelected();
    toast({ title: "Membresía actualizada", description: result.products_added ? `${result.products_added} productos nuevos incorporados.` : "No había productos nuevos.", tone: "success" });
  }

  async function updateMembership(included: boolean) {
    if (!selected || !selectedProductIds.length) return;
    setBusy(true);
    const { data, error: updateError } = await getSupabaseClient().rpc("set_sales_assortment_membership", {
      p_company_id: companyId,
      p_assortment_id: selected.id,
      p_product_ids: selectedProductIds,
      p_included: included,
    });
    setBusy(false);
    if (updateError) {
      toast({ title: "No se pudo actualizar la membresía", description: updateError.message, tone: "error" });
      return;
    }
    const updated = Number((data as { updated?: number } | null)?.updated ?? 0);
    await loadSelected();
    toast({ title: "Membresía actualizada", description: `${updated} producto${updated === 1 ? "" : "s"} ${included ? "incluido" : "retirado"}${updated === 1 ? "" : "s"}.`, tone: "success" });
  }

  async function assignLocation() {
    if (!selected || !locationId) return;
    setBusy(true);
    const { error: assignmentError } = await getSupabaseClient().from("location_sales_assortments").insert({ assortment_id: selected.id, location_id: locationId });
    setBusy(false);
    if (assignmentError) {
      toast({ title: "No se pudo asignar la sucursal", description: assignmentError.message, tone: "error" });
      return;
    }
    setLocationId("");
    await loadSelected();
  }

  async function removeLocation(assignmentId: string) {
    setBusy(true);
    const { error: assignmentError } = await getSupabaseClient().from("location_sales_assortments").update({ valid_to: new Date().toISOString() }).eq("id", assignmentId);
    setBusy(false);
    if (assignmentError) {
      toast({ title: "No se pudo retirar la sucursal", description: assignmentError.message, tone: "error" });
      return;
    }
    await loadSelected();
  }

  const activeLocations = assignments.flatMap((assignment) => {
    const location = locations.find((item) => item.id === assignment.location_id);
    return location ? [{ assignment, location }] : [];
  });
  const availableLocations = locations.filter((location) => !assignments.some((assignment) => assignment.location_id === location.id));
  const currentPageIds = membership?.items.map((item) => item.product_id) ?? [];
  const allPageSelected = currentPageIds.length > 0 && currentPageIds.every((id) => selectedProductIds.includes(id));
  const activationBlocked = (membership?.member_count ?? 0) === 0 || assignments.length === 0;
  const toggleLocation = (id: string) => setNewLocationIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  const toggleProduct = (id: string) => setSelectedProductIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);

  return (
    <div className="content-frame">
      <header className="page-heading">
        <div><span className="eyebrow">Configuración comercial</span><h1>Surtidos comerciales</h1><p>Define qué productos pertenecen a cada surtido y en qué sucursales se utiliza.</p></div>
        <Button variant="secondary" onClick={() => { void loadBase(); void loadSelected(); }}><RefreshCw size={16} /> Actualizar</Button>
      </header>
      <div className="pos-prep-layout">
        <aside className="pos-prep-panel">
          <h2>Crear surtido</h2>
          <form className="pos-prep-create" onSubmit={requestCreate}>
            <label>Código<input value={newCode} onChange={(event) => setNewCode(event.target.value)} /></label>
            <label>Nombre<input value={newName} onChange={(event) => setNewName(event.target.value)} /></label>
            <fieldset className="pos-prep-locations">
              <legend>Sucursales</legend>
              {locations.map((location) => <label key={location.id}><input type="checkbox" checked={newLocationIds.includes(location.id)} onChange={() => toggleLocation(location.id)} /><span><strong>{location.name}</strong><small>{location.external_code}</small></span></label>)}
            </fieldset>
            <p className="pos-prep-help">Se incluirán los {catalogTotal.toLocaleString("es-MX")} productos vendibles actuales. La membresía puede ajustarse después.</p>
            <Button type="submit" variant="primary" loading={busy} disabled={!catalogTotal || !newLocationIds.length}><Boxes size={15} /> Crear surtido</Button>
          </form>
          <div className="pos-prep-assortments">
            {assortments.map((assortment) => <button className={assortment.id === selectedId ? "is-selected" : ""} key={assortment.id} onClick={() => { setSelectedId(assortment.id); setPage(1); }}><span><strong>{assortment.name}</strong><small>{assortment.code}</small></span><Badge tone={assortment.status === "active" ? "success" : assortment.status === "draft" ? "info" : "neutral"}>{assortment.status === "active" ? "Activo" : assortment.status === "draft" ? "Borrador" : "Inactivo"}</Badge></button>)}
          </div>
        </aside>
        <section className="pos-prep-main">
          <DataState loading={loading && Boolean(selectedId) && !membership} error={error} hasData={selected ? 1 : 0} empty="Aún no hay surtidos comerciales.">
            {selected && <>
              <div className="pos-prep-heading">
                <div><span className="eyebrow">Surtido seleccionado</span><h2>{selected.name}</h2><p>{selected.code} · La disponibilidad operativa no cambia esta membresía.</p></div>
                <div className="pos-prep-heading-actions">
                  <Button variant="secondary" onClick={() => setConfirmation("refresh")} disabled={busy}>Agregar productos nuevos</Button>
                  <Select value={selected.status} onValueChange={(value) => void changeStatus(value)} ariaLabel="Estado del surtido" disabled={busy} options={[{ value: "draft", label: "Borrador" }, { value: "active", label: "Activo", disabled: activationBlocked && selected.status !== "active" }, { value: "inactive", label: "Inactivo" }]} />
                </div>
              </div>
              <div className="pos-prep-kpis"><article><span>Miembros</span><strong>{membership?.member_count ?? 0}</strong></article><article><span>Sucursales</span><strong>{assignments.length}</strong></article><article><span>Catálogo</span><strong>{catalogTotal}</strong></article></div>
              <div className="pos-prep-controls">
                <section>
                  <h3>Sucursales asignadas</h3>
                  <div className="pos-prep-inline"><Select value={locationId} onValueChange={setLocationId} ariaLabel="Asignar sucursal" options={[{ value: "", label: "Seleccionar sucursal", disabled: true }, ...availableLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))]} disabled={busy || !availableLocations.length} /><Button onClick={() => void assignLocation()} disabled={!locationId || busy}>Asignar</Button></div>
                  <div className="pos-prep-chips">{activeLocations.length ? activeLocations.map(({ assignment, location }) => <span key={assignment.id}>{location.external_code} · {location.name}<button aria-label={`Retirar ${location.name}`} onClick={() => void removeLocation(assignment.id)} disabled={busy}><Trash2 size={13} /></button></span>) : <small>Sin sucursales asignadas.</small>}</div>
                </section>
                <section><h3>Regla operativa</h3><p className="pos-prep-help">Un bloqueo de readiness impide vender, pero nunca retira el producto del surtido.</p></section>
              </div>
              <div className="pos-bulk-actions"><span><strong>{selectedProductIds.length}</strong> seleccionados</span><Button size="sm" variant="secondary" disabled={!selectedProductIds.length || busy} onClick={() => void updateMembership(true)}>Incluir</Button><Button size="sm" variant="secondary" disabled={!selectedProductIds.length || busy} onClick={() => void updateMembership(false)}>Retirar</Button></div>
              <div className="pos-prep-table">
                <DataToolbar search={query} onSearchChange={setQuery} placeholder="Buscar producto o código" filters={<Select value={membershipFilter} onValueChange={(value) => { setMembershipFilter(value as typeof membershipFilter); setPage(1); }} ariaLabel="Filtrar membresía" options={[{ value: "all", label: "Todos" }, { value: "included", label: "Incluidos" }, { value: "excluded", label: "Fuera del surtido" }]} />} activeFilters={(query.trim() ? 1 : 0) + (membershipFilter !== "all" ? 1 : 0)} onClear={() => { setQuery(""); setDebouncedQuery(""); setMembershipFilter("all"); setPage(1); }} results={membership?.total ?? 0} />
                <DataState loading={loading} error={error} hasData={membership?.items.length ?? 0} empty="No hay productos para este filtro.">
                  <div className="table-wrap surface-table"><table><thead><tr><th className="selection-cell"><input type="checkbox" aria-label="Seleccionar página" checked={allPageSelected} onChange={() => setSelectedProductIds(allPageSelected ? selectedProductIds.filter((id) => !currentPageIds.includes(id)) : [...new Set([...selectedProductIds, ...currentPageIds])])} /></th><th>Producto</th><th>Código</th><th>Pertenencia comercial</th></tr></thead><tbody>{(membership?.items ?? []).map((item) => <tr key={item.product_id}><td className="selection-cell"><input type="checkbox" aria-label={`Seleccionar ${item.name}`} checked={selectedProductIds.includes(item.product_id)} onChange={() => toggleProduct(item.product_id)} /></td><td><strong>{item.name}</strong></td><td className="mono">{item.code ?? "—"}</td><td><Badge tone={item.included ? "success" : "neutral"}>{item.included ? "Incluido" : "Fuera"}</Badge></td></tr>)}</tbody></table></div>
                </DataState>
                <Pagination page={page} total={membership?.total ?? 0} onChange={setPage} />
              </div>
            </>}
          </DataState>
        </section>
      </div>
      <Modal open={confirmation === "create"} onOpenChange={(open) => { if (!open && !busy) setConfirmation(null); }} eyebrow="Configuración comercial" title="Crear surtido" description="Se creará el surtido, se incluirán los productos vendibles actuales y se asignarán las sucursales seleccionadas." footer={<><Button variant="secondary" onClick={() => setConfirmation(null)} disabled={busy}>Cancelar</Button><Button variant="primary" onClick={() => void createAssortment()} loading={busy}>Crear surtido</Button></>}><div className="pos-prep-confirm-summary"><span><strong>{catalogTotal}</strong> productos</span><span><strong>{newLocationIds.length}</strong> sucursales</span></div></Modal>
      <Modal open={confirmation === "refresh"} onOpenChange={(open) => { if (!open && !busy) setConfirmation(null); }} eyebrow="Membresía comercial" title="Agregar productos nuevos" description="Se incorporarán los productos vendibles que aún no pertenecen al surtido. No se retirará ningún miembro existente." footer={<><Button variant="secondary" onClick={() => setConfirmation(null)} disabled={busy}>Cancelar</Button><Button variant="primary" onClick={() => void refreshCatalog()} loading={busy}>Incorporar</Button></>} />
    </div>
  );
}

function Pagination({ page, total, onChange }: { page: number; total: number; onChange: (page: number) => void }) {
  return <DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={onChange} />;
}
