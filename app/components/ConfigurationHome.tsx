"use client";

import Link from "next/link";
import { ArrowRight, Building2, Database, Landmark, ReceiptText, Settings2, ShoppingCart } from "lucide-react";
import { PageHeading } from "@/app/components/ui/data";

type Module = { title:string;description:string;icon:typeof Building2;links:Array<{label:string;href:string;visible:boolean}> };

export function ConfigurationHome({permissions}:{permissions:string[]}){
  const has=(...codes:string[])=>codes.some((code)=>permissions.includes(code)||permissions.includes("*"));
  const modules:Module[]=[
    {title:"Empresa",description:"Define la estructura operativa antes de asignar personas, cajas e inventario.",icon:Building2,links:[{label:"Sucursales y ubicaciones",href:"/satrapy/configuracion/empresa/sucursales",visible:has("manage_locations")},{label:"Usuarios y accesos",href:"/satrapy/configuracion/usuarios",visible:has("manage_company_users")}]},
    {title:"Migración",description:"Organiza la carga inicial y conserva cada archivo, validación y promoción.",icon:Database,links:[{label:"Migración inicial",href:"/satrapy/configuracion/migracion-inicial",visible:has("import_data","import_prices","import_costs","import_accounting_opening")},{label:"Centro de Migración",href:"/satrapy/configuracion/importaciones",visible:has("import_data","import_prices","import_costs","import_accounting_opening")},{label:"Auditoría de importaciones",href:"/satrapy/configuracion/auditoria-importaciones",visible:has("view_import_audit")}]},
    {title:"Ventas",description:"Configura caja, precios, descuentos y disponibilidad comercial.",icon:ShoppingCart,links:[{label:"Configuración comercial",href:"/satrapy/configuracion/ventas",visible:has("manage_payment_methods","manage_discount_policies","manage_locations","manage_prices","manage_ticket_branding")},{label:"Surtidos comerciales",href:"/satrapy/configuracion/surtidos",visible:has("manage_assortments")},{label:"Auditoría comercial",href:"/satrapy/configuracion/auditoria-comercial",visible:has("view_sales_audit")}]},
    {title:"Compras",description:"Administra las cuentas desde las que se preparan y confirman pagos.",icon:ReceiptText,links:[{label:"Cuentas pagadoras",href:"/satrapy/configuracion/cuentas-bancarias",visible:has("manage_supplier_paying_accounts")}]},
    {title:"Contabilidad",description:"Mantén la base contable y las cuentas financieras sin duplicar catálogos.",icon:Landmark,links:[{label:"Configuración contable",href:"/satrapy/configuracion/contabilidad",visible:has("view_accounting","configure_accounting")},{label:"Cuentas financieras",href:"/satrapy/configuracion/cuentas-bancarias",visible:has("view_banking","manage_supplier_paying_accounts")}]},
  ].map((module)=>({...module,links:module.links.filter((link)=>link.visible)})).filter((module)=>module.links.length);
  return <div className="content-frame configuration-home"><PageHeading eyebrow="Administración" title="Configuración general" description="Ajusta cada área desde un solo lugar, sin mezclar operación diaria con decisiones estructurales."/><section className="configuration-home__intro"><span><Settings2 size={21}/></span><div><strong>Configuración por módulos</strong><p>Empieza por Empresa y Migración. Después completa únicamente los módulos que correspondan a tu operación.</p></div></section><div className="configuration-module-grid">{modules.map((module)=>{const Icon=module.icon;return <article className="configuration-module-card" key={module.title}><header><span><Icon size={19}/></span><div><h2>{module.title}</h2><p>{module.description}</p></div></header><div>{module.links.map((link)=><Link href={link.href} key={link.href}><span>{link.label}</span><ArrowRight size={15}/></Link>)}</div></article>;})}</div></div>;
}
