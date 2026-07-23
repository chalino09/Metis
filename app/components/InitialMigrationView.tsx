"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { ArrowRight, CheckCircle2, Circle, Database, RefreshCw } from "lucide-react";
import { Badge, Button } from "@/app/components/ui/primitives";
import { DataState, PageHeading } from "@/app/components/ui/data";
import { getSupabaseClient } from "@/app/lib/supabase";

type CoverageCheck={code:string;label:string;count:number;status:"ready"|"pending"};
type CoverageModule={code:string;label:string;description:string;href:string;checks:CoverageCheck[]};
type Readiness={observed_at:string;files:number;ready_checks:number;total_checks:number;modules:CoverageModule[]};

export function InitialMigrationView({companyId}:{companyId:string}){
  const [data,setData]=useState<Readiness|null>(null);const [loading,setLoading]=useState(true);const [error,setError]=useState<string|null>(null);
  const load=useCallback(async()=>{setLoading(true);setError(null);const {data:result,error:rpcError}=await getSupabaseClient().rpc("get_initial_migration_readiness",{p_company_id:companyId});setData((result as Readiness|null)??null);setError(rpcError?"No se pudo calcular la cobertura de la migración.":null);setLoading(false);},[companyId]);
  useEffect(()=>{void Promise.resolve().then(load);},[load]);
  const ready=data?.ready_checks??0;const total=data?.total_checks??0;const percentage=total?Math.round(ready/total*100):0;
  const next=useMemo(()=>data?.modules.find((module)=>module.checks.some((check)=>check.status!=="ready")),[data]);
  return <div className="content-frame initial-migration">
    <PageHeading eyebrow="Puesta en marcha" title="Migración inicial" description="Revisa la cobertura real por módulo y apartado. El porcentaje sólo cuenta información que Satrapy pudo comprobar." action={<Button variant="secondary" loading={loading} onClick={()=>void load()}><RefreshCw size={15}/>Actualizar</Button>}/>
    <DataState loading={loading&&!data} error={error} errorAction={<Button size="sm" onClick={()=>void load()}>Reintentar</Button>} hasData={data?.modules.length??0} empty="No fue posible determinar los módulos.">
      <section className="migration-progress-card"><div className="migration-progress-card__summary"><span><Database size={22}/></span><div><small>Cobertura detectada</small><strong>{ready} de {total} verificaciones con evidencia</strong><p>{data?.files??0} lotes conservados en el Centro de Migración.</p></div><b>{percentage}%</b></div><progress max={Math.max(total,1)} value={ready}/><footer><span>“Sin evidencia” no siempre bloquea la operación, pero evita declarar una migración completa sin datos comprobables.</span>{next&&<Link className="ui-button ui-button--primary ui-button--sm" href={next.href}>Revisar siguiente <ArrowRight size={14}/></Link>}</footer></section>
      <section className="migration-coverage"><header><div><h2>Cobertura por módulo</h2><p>Cada módulo muestra sus apartados; una sola fila existente ya prueba presencia, no calidad ni conciliación.</p></div><Badge>{data?.modules.length??0} módulos</Badge></header><div className="migration-coverage__grid">{data?.modules.map((module)=>{const moduleReady=module.checks.filter((check)=>check.status==="ready").length;return <article key={module.code}><header><div><strong>{module.label}</strong><p>{module.description}</p></div><Badge tone={moduleReady===module.checks.length?"success":moduleReady?"warning":"neutral"}>{moduleReady} de {module.checks.length}</Badge></header><div className="migration-coverage__checks">{module.checks.map((check)=><div className={check.status==="ready"?"is-ready":""} key={check.code}><span>{check.status==="ready"?<CheckCircle2 size={15}/>:<Circle size={15}/>}</span><strong>{check.label}</strong><small>{check.status==="ready"?`${check.count.toLocaleString("es-MX")} detectados`:"Sin evidencia"}</small></div>)}</div><Link href={module.href}>Revisar módulo <ArrowRight size={14}/></Link></article>;})}</div></section>
    </DataState>
  </div>;
}
