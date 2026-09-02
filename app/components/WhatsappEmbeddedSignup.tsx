"use client";

import { CheckCircle2 } from "lucide-react";
import Image from "next/image";
import { useCallback,useEffect,useRef,useState } from "react";
import { Button,Field,Modal,Select,useToast } from "@/app/components/ui/primitives";
import { parseEmbeddedSignupMessage,type EmbeddedSignupData } from "@/app/lib/meta-embedded-signup";
import { getSupabaseClient } from "@/app/lib/supabase";
import styles from "@/app/components/WhatsappEmbeddedSignup.module.css";

type Location={id:string;name:string;code:string};
type Connection={id:string;display_name:string;status:string;configuration:Record<string,string>};
type Setup={locationId:string};
type LoginResponse={authResponse?:{code?:string};status?:string};
type FacebookSdk={init:(options:Record<string,unknown>)=>void;login:(callback:(response:LoginResponse)=>void,options:Record<string,unknown>)=>void};

declare global{interface Window{FB?:FacebookSdk;fbAsyncInit?:()=>void}}

export function WhatsappEmbeddedSignup({companyId,locations,connections,onConnected}:{companyId:string;locations:Location[];connections:Connection[];onConnected:()=>Promise<void>}){
  const {toast}=useToast();const [open,setOpen]=useState(false);const [sdkReady,setSdkReady]=useState(false);const [connecting,setConnecting]=useState(false);
  const [setup,setSetup]=useState<Setup>({locationId:locations[0]?.id??""});
  const codeRef=useRef("");const sessionRef=useRef<EmbeddedSignupData|null>(null);const completingRef=useRef(false);
  const lastLaunchAttemptRef=useRef(0);
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
      const response=await fetch("/api/integrations/meta/whatsapp/embedded-signup",{method:"POST",headers:{authorization:`Bearer ${session.access_token}`,"content-type":"application/json"},body:JSON.stringify({company_id:companyId,location_id:selectedLocationId,display_name:"",code:codeRef.current,waba_id:meta.wabaId,phone_number_id:meta.phoneNumberId,phone_number:meta.phoneNumber})});
      const result=await response.json() as {message?:string;phone_number?:string};if(!response.ok)throw new Error(result.message??"No se completó la conexión.");
      await onConnected();setOpen(false);toast({title:"WhatsApp conectado",description:result.phone_number?`${result.phone_number} quedó asignado a la sucursal.`:result.message,tone:"success"});
    }catch(error){toast({title:"No se conectó el número",description:error instanceof Error?error.message:"Intenta nuevamente.",tone:"error"});}
    finally{setConnecting(false);completingRef.current=false;codeRef.current="";sessionRef.current=null;}
  },[companyId,onConnected,selectedLocationId,toast]);

  useEffect(()=>{
    const listener=(event:MessageEvent)=>{if(event.origin!=="https://www.facebook.com"&&event.origin!=="https://web.facebook.com")return;const parsed=parseEmbeddedSignupMessage(event.data);if(!parsed)return;sessionRef.current=parsed;void finish();};
    window.addEventListener("message",listener);return()=>window.removeEventListener("message",listener);
  },[finish]);

  function launch(){
    const now=Date.now();if(now-lastLaunchAttemptRef.current<1200)return;lastLaunchAttemptRef.current=now;
    if(!selectedLocationId){toast({title:"Selecciona una sucursal",description:"Cada número debe tener un destino operativo.",tone:"error"});return;}
    if(!appId||!configurationId){toast({title:"La conexión con Meta aún no está disponible",description:"Pide al administrador que termine la configuración de WhatsApp.",tone:"error"});return;}
    if(!window.FB||!sdkReady){toast({title:"Meta todavía está cargando",description:"Espera unos segundos e intenta nuevamente.",tone:"error"});return;}
    codeRef.current="";sessionRef.current=null;setConnecting(true);
    window.FB.login(response=>{const code=String(response.authResponse?.code??"");if(!code){setConnecting(false);toast({title:"Conexión cancelada",description:"Meta no entregó autorización para el número.",tone:"error"});return;}codeRef.current=code;void finish();},{config_id:configurationId,response_type:"code",override_default_response_type:true,auth_type:"rerequest",extras:{setup:{},featureType:"whatsapp_business_app_onboarding",sessionInfoVersion:"3"}});
  }

  return <>
    <Button className={`integration-connect-button${connections.length?" is-installed":""}`} variant="secondary" onClick={()=>setOpen(true)}>{connections.length?"Administrar":"Conectar"}</Button>
    <Modal open={open} onOpenChange={next=>!connecting&&setOpen(next)} eyebrow="WhatsApp Business" title="Conectar WhatsApp" description="Asigna el número a una sucursal y continúa en Meta." closeDisabled={connecting} footer={<><Button disabled={connecting} onClick={()=>setOpen(false)}>Cancelar</Button><Button variant="primary" loading={connecting} onClick={launch}>Continuar con Meta</Button></>}>
      <div className={styles.onboarding}>
        {connections.length?<section aria-labelledby="whatsapp-connected-title"><h3 id="whatsapp-connected-title">Números conectados</h3><div className={styles.numberList}>{connections.map(connection=>{const location=locations.find(item=>item.id===connection.configuration.location_id);return <article key={connection.id}><span><Image src="/brands/whatsapp.svg" width={19} height={19} alt=""/></span><div><strong>{connection.configuration.phone_number||connection.display_name}</strong><small>{location?.name??"Sucursal sin identificar"} · {connection.configuration.onboarding_mode==="coexistence"?"También en WhatsApp Business":"Sólo en Satrapy"}</small></div><CheckCircle2 size={18} aria-label="Conectado"/></article>})}</div></section>:null}
        <section aria-labelledby="whatsapp-new-title"><h3 id="whatsapp-new-title">Agregar número</h3><div className="integration-form"><Field label="Sucursal"><Select ariaLabel="Sucursal que atenderá el número" value={selectedLocationId} onValueChange={value=>setSetup({locationId:value})} options={locations.map(location=>({value:location.id,label:location.name}))}/></Field></div><p className={styles.notice}>El número seguirá funcionando en WhatsApp Business y también se conectará con Satrapy.</p></section>
      </div>
    </Modal>
  </>;
}
