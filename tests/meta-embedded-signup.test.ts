import assert from "node:assert/strict";
import test from "node:test";
import { parseEmbeddedSignupMessage } from "../app/lib/meta-embedded-signup.ts";

test("parses a coexistence completion without inventing a phone identifier",()=>{
  const parsed=parseEmbeddedSignupMessage(JSON.stringify({type:"WA_EMBEDDED_SIGNUP",event:"FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING",data:{waba_id:"123456"}}));
  assert.deepEqual(parsed,{wabaId:"123456",phoneNumberId:"",phoneNumber:"",event:"FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING",mode:"coexistence"});
});
test("parses the standard cloud completion payload",()=>{
  const parsed=parseEmbeddedSignupMessage({type:"WA_EMBEDDED_SIGNUP",event:"FINISH",data:{waba_id:"123",phone_number_id:"456",display_phone_number:"+52 797 100 0000"}});
  assert.equal(parsed?.phoneNumberId,"456");assert.equal(parsed?.mode,"cloud");
});

test("ignores unrelated, cancelled, and malformed window messages",()=>{
  assert.equal(parseEmbeddedSignupMessage({type:"OTHER",data:{waba_id:"123"}}),null);
  assert.equal(parseEmbeddedSignupMessage({type:"WA_EMBEDDED_SIGNUP",event:"CANCEL",data:{waba_id:"123"}}),null);
  assert.equal(parseEmbeddedSignupMessage("not-json"),null);
});
