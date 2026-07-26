export function roleDisplayName(code: string, fallback?: string) {
  if (code === "super_admin") return "Superadmin";
  if (code === "direccion_admin") return "Administrador";
  return fallback ?? code;
}
