"use client";

import { CalendarClock, WandSparkles } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Badge, Button, Field, Input, Modal, useToast } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

export type WeeklyScheduleDay={weekday:number;starts_at:string;ends_at:string;break_minutes:number;net_minutes:number};
export type WeeklyScheduleVersion={id:string;version_number:number;effective_from:string;reason:string;weekly_minutes:number;day_count?:number;days?:WeeklyScheduleDay[]};
export type WeeklyScheduleContext={current:WeeklyScheduleVersion|null;history:WeeklyScheduleVersion[]};
type DraftDay={weekday:number;enabled:boolean;startTime:string;endTime:string;breakMinutes:string};

const weekdays=[{value:1,label:"Lunes",short:"Lun"},{value:2,label:"Martes",short:"Mar"},{value:3,label:"Miércoles",short:"Mié"},{value:4,label:"Jueves",short:"Jue"},{value:5,label:"Viernes",short:"Vie"},{value:6,label:"Sábado",short:"Sáb"},{value:7,label:"Domingo",short:"Dom"}];
const today=()=>new Date().toISOString().slice(0,10);
const emptyDays=():DraftDay[]=>weekdays.map(day=>({weekday:day.value,enabled:false,startTime:"08:00",endTime:"17:00",breakMinutes:"0"}));
const hours=(minutes:number)=>`${new Intl.NumberFormat("es-MX",{maximumFractionDigits:1}).format(minutes/60)} h`;
const formatDate=(value:string)=>new Intl.DateTimeFormat("es-MX",{dateStyle:"medium"}).format(new Date(`${value}T12:00:00`));
export const weeklyScheduleSummary=(context:WeeklyScheduleContext|null)=>context?.current?`${context.current.days?.length??0} días · ${hours(context.current.weekly_minutes)}`:"Sin horario configurado";

export function CollaboratorWeeklyScheduleModal({companyId,collaborator,open,onOpenChange,onSaved}:{companyId:string;collaborator:{id:string;name:string}|null;open:boolean;onOpenChange:(open:boolean)=>void;onSaved:(context:WeeklyScheduleContext)=>void}){
  const {toast}=useToast();
  const [context,setContext]=useState<WeeklyScheduleContext|null>(null);
  const [days,setDays]=useState<DraftDay[]>(emptyDays);
  const [effectiveFrom,setEffectiveFrom]=useState(today());
  const [reason,setReason]=useState("");
  const [loading,setLoading]=useState(false);
  const [saving,setSaving]=useState(false);
  const [error,setError]=useState<string|null>(null);
  const enabledDays=useMemo(()=>days.filter(day=>day.enabled),[days]);

  useEffect(()=>{
    if(!open||!collaborator)return;
    let active=true;
    void Promise.resolve().then(async()=>{
      if(!active)return;setLoading(true);setError(null);setEffectiveFrom(today());setReason("");
      const {data,error:rpcError}=await getSupabaseClient().rpc("get_collaborator_weekly_schedule",{p_company_id:companyId,p_collaborator_id:collaborator.id,p_on_date:today()});
      if(!active)return;setLoading(false);
      if(rpcError){setError(rpcError.message.includes("schema cache")?"Falta aplicar la migración de horarios semanales.":rpcError.message);setContext(null);setDays(emptyDays());return;}
      const next=data as WeeklyScheduleContext;setContext(next);
      const current=new Map((next.current?.days??[]).map(day=>[day.weekday,day]));
      setDays(weekdays.map(day=>{const saved=current.get(day.value);return {weekday:day.value,enabled:Boolean(saved),startTime:saved?.starts_at??"08:00",endTime:saved?.ends_at??"17:00",breakMinutes:String(saved?.break_minutes??0)};}));
    });
    return()=>{active=false;};
  },[collaborator,companyId,open]);

  function updateDay(weekday:number,values:Partial<DraftDay>){setDays(current=>current.map(day=>day.weekday===weekday?{...day,...values}:day));}
  function applyPreset(lastWeekday:5|6){setDays(current=>current.map(day=>({...day,enabled:day.weekday<=lastWeekday,startTime:day.weekday<=lastWeekday?"08:00":day.startTime,endTime:day.weekday<=lastWeekday?"17:00":day.endTime,breakMinutes:day.weekday<=lastWeekday?"0":day.breakMinutes})));}
  async function save(){
    if(!collaborator)return;
    if(!enabledDays.length||!effectiveFrom||!reason.trim()){setError("Selecciona al menos un día y captura vigencia y motivo.");return;}
    if(enabledDays.some(day=>!day.startTime||!day.endTime||day.startTime===day.endTime||Number(day.breakMinutes)<0)){setError("Revisa entrada, salida y descanso de los días seleccionados.");return;}
    setSaving(true);setError(null);
    const {data,error:rpcError}=await getSupabaseClient().rpc("save_collaborator_weekly_schedule",{p_company_id:companyId,p_collaborator_id:collaborator.id,p_effective_from:effectiveFrom,p_days:enabledDays.map(day=>({weekday:day.weekday,start_time:day.startTime,end_time:day.endTime,break_minutes:Number(day.breakMinutes||0)})),p_reason:reason.trim()});
    setSaving(false);
    if(rpcError){setError(rpcError.message);return;}
    const next=data as WeeklyScheduleContext;onSaved(next);onOpenChange(false);toast({title:"Horario semanal guardado",description:"La nueva versión conserva el horario anterior en el historial.",tone:"success"});
  }

  return <Modal open={open} onOpenChange={value=>!saving&&onOpenChange(value)} className="collaborator-schedule-dialog" eyebrow="Colaboradores · Horario" title={collaborator?`Horario de ${collaborator.name}`:"Horario semanal"} description="Define la jornada habitual. Las incidencias reales se siguen capturando desde Nómina." closeDisabled={saving} footer={<><Button variant="secondary" disabled={saving} onClick={()=>onOpenChange(false)}>Cancelar</Button><Button variant="primary" loading={saving} onClick={()=>void save()}>Guardar nueva vigencia</Button></>}>
    {loading?<p role="status">Cargando horario…</p>:<div className="collaborator-schedule">
      {error&&<p className="collaborator-schedule__error" role="alert">{error}</p>}
      <section className="collaborator-schedule__toolbar" aria-label="Atajos de horario"><div><CalendarClock size={19} aria-hidden="true"/><span><strong>Semana habitual</strong><small>{enabledDays.length} {enabledDays.length===1?"día seleccionado":"días seleccionados"}</small></span></div><div><Button type="button" size="sm" variant="secondary" onClick={()=>applyPreset(5)}><WandSparkles size={14} aria-hidden="true"/>Lunes a viernes</Button><Button type="button" size="sm" variant="secondary" onClick={()=>applyPreset(6)}>Lunes a sábado</Button></div></section>
      <fieldset className="collaborator-schedule__week"><legend className="sr-only">Días y horas de trabajo</legend>{days.map(day=>{const label=weekdays.find(item=>item.value===day.weekday)!;return <div className={day.enabled?"is-working":""} key={day.weekday}><label className="collaborator-schedule__day"><input type="checkbox" checked={day.enabled} onChange={event=>updateDay(day.weekday,{enabled:event.target.checked})}/><span>{label.label}</span></label><label><span>Entrada</span><Input type="time" disabled={!day.enabled} value={day.startTime} onChange={event=>updateDay(day.weekday,{startTime:event.target.value})} aria-label={`Entrada del ${label.label}`}/></label><label><span>Salida</span><Input type="time" disabled={!day.enabled} value={day.endTime} onChange={event=>updateDay(day.weekday,{endTime:event.target.value})} aria-label={`Salida del ${label.label}`}/></label><label><span>Descanso</span><Input type="number" min="0" max="720" step="5" inputMode="numeric" disabled={!day.enabled} value={day.breakMinutes} onChange={event=>updateDay(day.weekday,{breakMinutes:event.target.value})} aria-label={`Minutos de descanso del ${label.label}`}/></label></div>;})}</fieldset>
      <div className="collaborator-schedule__details"><Field label="Vigente desde"><Input required type="date" value={effectiveFrom} onChange={event=>setEffectiveFrom(event.target.value)}/></Field><Field label="Motivo"><Input required value={reason} onChange={event=>setReason(event.target.value)} placeholder="Ej. Horario habitual de apertura"/></Field></div>
      {context?.history.length?<section className="collaborator-schedule__history" aria-labelledby="schedule-history-title"><h3 id="schedule-history-title">Historial de horarios</h3><ul>{context.history.map(item=><li key={item.id}><span><strong>Versión {item.version_number}</strong><small>Desde {formatDate(item.effective_from)} · {item.day_count} días · {hours(item.weekly_minutes)}</small></span><Badge tone={context.current?.id===item.id?"success":"neutral"}>{context.current?.id===item.id?"Vigente":"Histórico"}</Badge></li>)}</ul></section>:null}
    </div>}
  </Modal>;
}
