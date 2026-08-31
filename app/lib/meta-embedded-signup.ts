export type EmbeddedSignupData={
  wabaId:string;
  phoneNumberId:string;
  phoneNumber:string;
  event:string;
  mode:"cloud"|"coexistence";
};

export function parseEmbeddedSignupMessage(value:unknown):EmbeddedSignupData|null{
  let payload=value;
  if(typeof payload==="string"){
    try{payload=JSON.parse(payload) as unknown;}catch{return null;}
  }
  if(!payload||typeof payload!=="object"||Array.isArray(payload))return null;
  const record=payload as Record<string,unknown>;
  if(record.type!=="WA_EMBEDDED_SIGNUP")return null;
  const data=record.data&&typeof record.data==="object"&&!Array.isArray(record.data)?record.data as Record<string,unknown>:{};
  const event=String(record.event??"");
  const wabaId=String(data.waba_id??data.wabaId??"").trim();
  const phoneNumberId=String(data.phone_number_id??data.phoneNumberId??"").trim();
  const phoneNumber=String(data.phone_number??data.display_phone_number??"").trim();
  if(!wabaId||event.startsWith("CANCEL")||event.startsWith("ERROR"))return null;
  return{wabaId,phoneNumberId,phoneNumber,event,mode:event.includes("WHATSAPP_BUSINESS_APP")?"coexistence":"cloud"};
}
