export type NeutralValueState = "zero_no_operations" | "unavailable";

export function neutralMetricValue(
  state: NeutralValueState | undefined,
  format: "integer" | "percent" | "currency",
) {
  if (state === "unavailable") return "No disponible";
  if (state === "zero_no_operations") return format === "integer" ? "0" : "$0";
  return null;
}
