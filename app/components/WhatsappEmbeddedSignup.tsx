"use client";

import { CheckCircle2,MessageCircle,Plus } from "lucide-react";
import { useCallback,useEffect,useRef,useState } from "react";
import { Button,Field,Input,Modal,Select,useToast } from "@/app/components/ui/primitives";
import { parseEmbeddedSignupMessage,type EmbeddedSignupData } from "@/app/lib/meta-embedded-signup";
import { getSupabaseClient } from "@/app/lib/supabase";
import styles from "@/app/components/WhatsappEmbeddedSignup.module.css";

type Location={id:string;name:string;code:string};
type Connection={id:string;display_name:string;status:string;configuration:Record<string,string>};
type Setup={locationId:string;displayName:string;mode:"coexistence"|"cloud"};
type LoginResponse={authResponse?:{code?:string};status?:string};
type FacebookSdk={init:(options:Record<string,unknown>)=>void;login:(callback:(response:LoginResponse)=>void,options:Record<string,unknown>)=>void};

declare global{interface Window{FB?:FacebookSdk;fbAsyncInit?:()=>void}}

export function WhatsappEmbeddedSignup({companyId,locations,connections,onConnected}:{companyId:string;locations:Location[];connections:Connection[];onConnected:()=>Promise<void>}){
  const {toast}=useToast();const [open,setOpen]=useState(false);const [sdkReady,setSdkReady]=useState(false);const [connecting,setConnecting]=useState(false);
  const [setup,setSetup]=useState<Setup>({locationId:locations[0]?.id??"",displayName:"",mode:"coexistence"});
  const codeRef=useRef("");const sessionRef=useRef<EmbeddedSignupData|null>(null);const completingRef=useRef(false);
  const appId=process.env.NEXT_PUBLIC_META_APP_ID??"";const configurationId=process.env.NEXT_PUBLIC_META_WHATSAPP_CONFIGURATION_ID??"";
  const selectedLocationId=setup.locationId||locations[0]?.id||"";

  useEffect(()=>{
    if(!appId)return;
    window.fbAsyncInit=()=>{window.FB?.init({appId,cookie:true,xfbml:false,version:process.env.NEXT_PUBLIC_META_GRAPH_API_VERSION||"v23.0"});setSdkReady(true);};
    if(window.FB){window.fbAsyncInit();return;}
    const existing=document.getElementById("facebook-jssdk");if(existing)return;
    const script=document.createElement("script");script.id="facebook-jssdk";script.async=true;script.defer=true;script.crossOrigin="anonymous";script.src="https://connect.facebook.net/es_LA/sdk.js";document.head.appendChild(script);
  },[appId]);

  const finish=useCallback(async()=>{
    if(completingRef.current||!codeRef.current||!sessionRef.current)return;
    completingRef.current=true;setConnecting(true);
    try{
      const session=(await getSupabaseClient().auth.getSession()).data.session;if(!session)throw new Error("Tu sesión terminó. Inicia sesión nuevamente.");
      const meta=sessionRef.current;
      const response=await fetch("/api/integrations/meta/whatsapp/embedded-signup",{method:"POST",headers:{authorization:`Bearer ${session.access_token}`,"content-type":"application/json"},body:JSON.stringify({company_id:companyId,location_id:selectedLocationId,display_name:setup.displayName,code:codeRef.current,waba_id:meta.wabaId,phone_number_id:meta.phoneNumberId,phone_number:meta.phoneNumber,onboarding_mode:setup.mode})});
      const result=await response.json() as {message?:string;phone_number?:string};if(!response.ok)throw new Error(result.message??"No se completó la conexión.");
      await onConnected();setOpen(false);toast({title:"WhatsApp conectado",description:result.phone_number?`${result.phone_number} quedó asignado a la sucursal.`:result.message,tone:"success"});
    }catch(error){toast({title:"No se conectó el número",description:error instanceof Error?error.message:"Intenta nuevamente.",tone:"error"});}
    finally{setConnecting(false);completingRef.current=false;codeRef.current="";sessionRef.current=null;}
  },[companyId,onConnected,selectedLocationId,setup.displayName,setup.mode,toast]);

  useEffect(()=>{
    const listener=(event:MessageEvent)=>{if(event.origin!=="https://www.facebook.com"&&event.origin!=="https://web.facebook.com")return;const parsed=parseEmbeddedSignupMessage(event.data);if(!parsed)return;sessionRef.current=parsed;void finish();};
    window.addEventListener("message",listener);return()=>window.removeEventListener("message",listener);
  },[finish]);

  function launch(){
    if(!selectedLocationId){toast({title:"Selecciona una sucursal",description:"Cada número debe tener un destino operativo.",tone:"error"});return;}
    if(!appId||!configurationId){toast({title:"Embedded Signup no está configurado",description:"Agrega el App ID y el Configuration ID de Meta al despliegue.",tone:"error"});return;}
    if(!window.FB||!sdkReady){toast({title:"Meta todavía está cargando",description:"Espera unos segundos e intenta nuevamente.",tone:"error"});return;}
    codeRef.current="";sessionRef.current=null;setConnecting(true);
    window.FB.login(response=>{const code=String(response.authResponse?.code??"");if(!code){setConnecting(false);toast({title:"Conexión cancelada",description:"Meta no entregó autorización para el número.",tone:"error"});return;}codeRef.current=code;void finish();},{config_id:configurationId,response_type:"code",override_default_response_type:true,auth_type:"rerequest",extras:setup.mode==="coexistence"?{setup:{},featureType:"whatsapp_business_app_onboarding",sessionInfoVersion:"3"}:{setup:{},sessionInfoVersion:"3"}});
  }

  return <>
    <Button className={`integration-connect-button${connections.length?" is-installed":""}`} variant="secondary" onClick={()=>setOpen(true)}>{connections.length?"Administrar":"Conectar"}</Button>
    <Modal open={open} onOpenChange={next=>!connecting&&setOpen(next)} eyebrow="WhatsApp Business" title="Números y sucursales" description="Conecta cada número mediante Meta y define qué sucursal atenderá sus mensajes." closeDisabled={connecting} footer={<><Button disabled={connecting} onClick={()=>setOpen(false)}>Cerrar</Button><Button variant="primary" loading={connecting} onClick={launch}><Plus size={16} aria-hidden="true"/>Conectar otro número</Button></>}>
      <div className={styles.onboarding}>
        {connections.length?<section aria-labelledby="whatsapp-connected-title"><h3 id="whatsapp-connected-title">Números conectados</h3><div className={styles.numberList}>{connections.map(connection=>{const location=locations.find(item=>item.id===connection.configuration.location_id);return <article key={connection.id}><span><MessageCircle size={19} aria-hidden="true"/></span><div><strong>{connection.configuration.phone_number||connection.display_name}</strong><small>{location?.name??"Sucursal sin identificar"} · {connection.configuration.onboarding_mode==="coexistence"?"Coexistence":"Cloud API"}</small></div><CheckCircle2 size={18} aria-label="Configurado"/></article>})}</div></section>:<p className={styles.empty}>Aún no hay números conectados. El número de prueba aparecerá aquí después de migrar la configuración actual.</p>}
        <section aria-labelledby="whatsapp-new-title"><h3 id="whatsapp-new-title">Nueva conexión</h3><div className="integration-form"><Field label="Modalidad"><Select ariaLabel="Modalidad de WhatsApp" value={setup.mode} onValueChange={value=>setSetup(current=>({...current,mode:value as Setup["mode"]}))} options={[{value:"coexistence",label:"Coexistence · conservar WhatsApp Business App"},{value:"cloud",label:"Cloud API · sólo Satrapy"}]}/></Field><Field label="Sucursal que atenderá el número"><Select ariaLabel="Sucursal que atenderá el número" value={selectedLocationId} onValueChange={value=>setSetup(current=>({...current,locationId:value}))} options={locations.map(location=>({value:location.id,label:location.name}))}/></Field><Field label="Nombre interno (opcional)" hint="Ejemplo: Ventas Tetela"><Input value={setup.displayName} onChange={event=>setSetup(current=>({...current,displayName:event.target.value}))}/></Field></div><p className={styles.notice}>Meta abrirá una ventana segura. Para Coexistence usa un número que siga activo en WhatsApp Business App.</p></section>
      </div>
    </Modal>
  </>;
}
