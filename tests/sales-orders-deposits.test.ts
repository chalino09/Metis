import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202607230015_sales_orders_with_deposits.sql", "utf8");
const deliveryDigestRepairSql = readFileSync("supabase/migrations/202607230019_sales_order_delivery_digest.sql", "utf8");
const moduleSource = readFileSync("app/components/SalesOrdersModule.tsx", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const createOrderSql = sql.slice(sql.indexOf("create or replace function public.create_sales_deposit_order"), sql.indexOf("create or replace function public.record_sales_deposit_order_payment"));
const depositSql = sql.slice(sql.indexOf("create or replace function public.record_sales_deposit_order_payment"), sql.indexOf("create or replace function public.create_sales_order_from_cart"));
const completionSql = sql.slice(sql.indexOf("create or replace function public.deliver_sales_deposit_order"), sql.indexOf("grant select on public.sales_deposit_orders"));

test("el pedido y sus pagos tienen pertenencia, acceso y auditoría", () => {
  assert.match(sql, /create table if not exists public\.sales_deposit_orders/);
  assert.match(sql, /create table if not exists public\.sales_deposit_order_lines/);
  assert.match(sql, /create table if not exists public\.sales_deposit_order_payments/);
  assert.match(sql, /has_company_permission\(company_id, 'view_sales_orders'\)/);
  assert.match(sql, /sales_order\.payment_received/);
  assert.match(sql, /unique\(company_id, client_request_id\)/);
});

test("crear y anticipar no reserva ni descuenta inventario", () => {
  assert.doesNotMatch(createOrderSql, /update public\.inventory_balances/);
  assert.doesNotMatch(createOrderSql, /insert into public\.sales\(/);
  assert.doesNotMatch(depositSql, /update public\.inventory_balances/);
  assert.doesNotMatch(depositSql, /insert into public\.sales\(/);
  assert.match(depositSql, /v_amount > round\(v_order\.total_amount - v_order\.paid_amount/);
});

test("la entrega queda separada del pago y confirma venta e inventario", () => {
  assert.match(completionSql, /set search_path = public, extensions/);
  assert.match(completionSql, /for update/);
  assert.match(completionSql, /totalmente pagada antes de confirmar la entrega/);
  assert.match(completionSql, /Existencia insuficiente/);
  assert.match(completionSql, /insert into public\.sales\(/);
  assert.match(completionSql, /update public\.inventory_balances/);
  assert.match(completionSql, /insert into public\.canonical_tickets/);
  assert.match(completionSql, /status = 'completed'/);
  assert.match(deliveryDigestRepairSql, /alter function public\.deliver_sales_deposit_order\(uuid, uuid, uuid, uuid\)/);
  assert.match(deliveryDigestRepairSql, /set search_path to public, extensions/);
});

test("Ventas muestra un flujo explícito de pedidos y anticipos", () => {
  assert.match(app, /\/satrapy\/ventas\/pedidos/);
  assert.match(app, /SalesOrdersView/);
  assert.match(moduleSource, /Cumplimiento de pedidos/);
  assert.match(moduleSource, /Registrar pago a cuenta/);
  assert.match(moduleSource, /Confirmar entrega/);
  assert.match(moduleSource, /deliver_sales_deposit_order/);
  assert.match(sql, /create_sales_order_from_cart/);
  assert.match(sql, /create_sales_order_from_quote/);
});
