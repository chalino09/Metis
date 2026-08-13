"use client";

import { useEffect, useState } from "react";
import { DataPagination, DataState, PageHeading, Table } from "@/app/components/ui/data";
import { Badge, Select } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";
import Link from "next/link";

type Task={id:string;task_type:string;purpose:string;reason:string;status:string;run_at:string;attempt_count:number;maximum_attempts:number;last_error:string|null};
type Response={configuration_status:"configured"|"not_configured";items:Task[];pagination:{page:number;page_size:number;total:number}};
const statusLabels:Record<string,string>={pending:"Pendiente",leased:"En proceso",completed:"Completada",failed:"Fallida",cancelled:"Cancelada"};

export function CollectionAutomationModule({companyId}:{companyId:string}){
  const [status,setStatus]=useState("pending");const [page,setPage]=useState(1);const [data,setData]=useState<Response|null>(null);const [loading,setLoading]=useState(true);const [error,setError]=useState<string|null>(null);
  useEffect(()=>{let current=true;void getSupabaseClient().rpc("collection_list_tasks",{p_company_id:companyId,p_status:status||null,p_page:page,p_page_size:25}).then(({data:result,error:loadError})=>{if(!current)return;if(loadError)setError(loadError.message);else setData(result as Response);setLoading(false);});return()=>{current=false;};},[companyId,page,status]);
  return <main className="content-frame module-page collection-automation">
    <PageHeading eyebrow="Cuentas por cobrar" title="Gestiones de cobranza" description="Consulta el estado de las tareas de seguimiento. Esta bandeja no modifica saldos ni envía comunicaciones." />
    <nav className="receivables-tabs" aria-label="Vistas de cuentas por cobrar"><Link href="/satrapy/ventas/cuentas-por-cobrar">Cartera</Link><Link href="/satrapy/ventas/cuentas-por-cobrar/automatizacion" aria-current="page">Gestiones</Link></nav>
    {data?.configuration_status==="not_configured"&&<section className="data-state data-state--empty" role="status" aria-live="polite"><div><strong>Automatización no configurada</strong><span>No se pueden generar ni reclamar tareas hasta aprobar responsables, horarios y frecuencia.</span></div></section>}
    <section aria-labelledby="collection-tasks-heading"><div className="collection-automation__toolbar"><div><h2 id="collection-tasks-heading">Tareas técnicas</h2><p>Consulta paginada por estado; los errores solo son visibles para roles autorizados.</p></div><label>Estado<Select ariaLabel="Estado de tareas" value={status} onValueChange={(value)=>{setLoading(true);setError(null);setStatus(value);setPage(1);}} options={[{value:"pending",label:"Pendientes"},{value:"leased",label:"Programadas / en proceso"},{value:"completed",label:"Completadas"},{value:"failed",label:"Fallidas"},{value:"cancelled",label:"Canceladas"}]} /></label></div>
      <DataState loading={loading} error={error} hasData={data?.items.length??0} empty="No hay tareas en este estado."><Table><thead><tr><th>Tipo</th><th>Propósito</th><th>Programada</th><th>Estado</th><th>Intentos</th><th>Resultado técnico</th></tr></thead><tbody>{data?.items.map(task=><tr key={task.id}><td>{task.task_type}</td><td><strong>{task.purpose}</strong><small>{task.reason}</small></td><td>{new Date(task.run_at).toLocaleString("es-MX")}</td><td><Badge>{statusLabels[task.status]??task.status}</Badge></td><td>{task.attempt_count} / {task.maximum_attempts}</td><td>{task.last_error??"Sin error"}</td></tr>)}</tbody></Table></DataState>
      <DataPagination page={page} onChange={(nextPage)=>{setLoading(true);setError(null);setPage(nextPage);}} total={data?.pagination.total??0} pageSize={25} label="tareas" />
    </section>
  </main>;
}
