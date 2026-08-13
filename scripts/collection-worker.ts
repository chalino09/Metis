import { createClient } from "@supabase/supabase-js";

const workerId = process.env.COLLECTION_WORKER_ID ?? `collection-worker-${process.pid}`;
const batchSize = Math.min(Math.max(Number(process.env.COLLECTION_WORKER_BATCH_SIZE ?? 25), 1), 100);
if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) throw new Error("Faltan credenciales server-side.");
const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const { data: tasks, error } = await supabase.rpc("collection_claim_tasks", { p_worker_id: workerId, p_batch_size: batchSize, p_lease_seconds: 60 });
if (error) throw error;
for (const task of tasks ?? []) {
  try {
    if (task.task_type !== "internal_healthcheck") throw new Error(`Tipo de tarea no soportado en Fase 1: ${task.task_type}`);
    const { error: finishError } = await supabase.rpc("collection_finish_task", { p_task_id: task.id, p_worker_id: workerId, p_success: true, p_result: { mode: "deterministic", provider: null } });
    if (finishError) throw finishError;
  } catch (taskError) {
    const message = taskError instanceof Error ? taskError.message : "Error no identificado";
    const { error: finishError } = await supabase.rpc("collection_finish_task", { p_task_id: task.id, p_worker_id: workerId, p_success: false, p_error: message, p_result: {} });
    if (finishError) throw finishError;
  }
}
console.log(JSON.stringify({ worker_id: workerId, claimed: tasks?.length ?? 0 }));
