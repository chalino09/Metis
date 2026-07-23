"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { getSupabaseClient, isSupabaseConfigured } from "@/app/lib/supabase";
import { withAccessTimeout } from "@/app/lib/access-loading";
import type { AppRoleCode, CompanyMembership, LocationRow, RoleOption } from "@/app/lib/types";

export type SatrapyAppState = {
  userId: string;
  email: string;
  membership: CompanyMembership;
};

export type QueryCache = {
  get: <T>(key: string) => T | undefined;
  set: <T>(key: string, value: T) => void;
  delete: (key: string) => void;
  invalidate: (prefix: string) => void;
  clear: () => void;
};

type SatrapyContextValue = {
  configured: boolean;
  loading: boolean;
  notice: string | null;
  appState: SatrapyAppState | null;
  companies: Array<{ id: string; display_name: string }>;
  accessibleLocations: LocationRow[];
  previewRole: AppRoleCode | null;
  setPreviewRole: (role: AppRoleCode | null) => void;
  selectCompany: (companyId: string) => Promise<void>;
  refreshAccess: () => Promise<void>;
  queryCache: QueryCache;
};

const SatrapyContext = createContext<SatrapyContextValue | null>(null);

export function SatrapyProvider({ children }: { children: ReactNode }) {
  const configured = isSupabaseConfigured();
  const [appState, setAppState] = useState<SatrapyAppState | null>(null);
  const [companies, setCompanies] = useState<Array<{ id: string; display_name: string }>>([]);
  const [accessibleLocations, setAccessibleLocations] = useState<LocationRow[]>([]);
  const [previewRole, setPreviewRole] = useState<AppRoleCode | null>(null);
  const [loading, setLoading] = useState(configured);
  const [notice, setNotice] = useState<string | null>(null);
  const cacheRef = useRef(new Map<string, unknown>());

  const queryCache = useMemo<QueryCache>(() => ({
    get: <T,>(key: string) => cacheRef.current.get(key) as T | undefined,
    set: <T,>(key: string, value: T) => { cacheRef.current.set(key, value); },
    delete: (key: string) => { cacheRef.current.delete(key); },
    invalidate: (prefix: string) => {
      for (const key of cacheRef.current.keys()) if (key.startsWith(prefix)) cacheRef.current.delete(key);
    },
    clear: () => { cacheRef.current.clear(); },
  }), []);

  const clearIdentity = useCallback(() => {
    queryCache.clear();
    setAppState(null);
    setCompanies([]);
    setAccessibleLocations([]);
    setPreviewRole(null);
  }, [queryCache]);

  const loadSession = useCallback(async (showLoading = false) => {
    if (!configured) {
      clearIdentity();
      setLoading(false);
      return;
    }
    if (showLoading) setLoading(true);
    setNotice(null);
    try {
      const supabase = getSupabaseClient();
      const { data: authData, error: authError } = await withAccessTimeout(supabase.auth.getUser());
      if (authError) throw authError;
      if (!authData.user) {
        clearIdentity();
        return;
      }
      let { data: assignments, error: assignmentsError } = await withAccessTimeout(supabase
        .from("user_roles")
        .select("company_id, role_id, roles(code, display_name)")
        .eq("is_active", true)
        .eq("user_id", authData.user.id));
      if (assignmentsError?.message.includes("is_active")) {
        ({ data: assignments, error: assignmentsError } = await withAccessTimeout(supabase
          .from("user_roles")
          .select("company_id, role_id, roles(code, display_name)")
          .eq("user_id", authData.user.id)));
      }
      if (assignmentsError) throw assignmentsError;

      const assignmentRows = (assignments ?? []) as Array<{
        company_id: string | null;
        role_id: string;
        roles: RoleOption | RoleOption[] | null;
      }>;
      const allAssignedRoles = assignmentRows
        .map((row) => Array.isArray(row.roles) ? row.roles[0] : row.roles)
        .filter((role): role is RoleOption => Boolean(role));
      const roleIds = assignmentRows.map((row) => row.role_id);
      const { data: permissionRows, error: permissionError } = roleIds.length
        ? await withAccessTimeout(supabase.from("role_permissions").select("role_id, permissions(code)").in("role_id", roleIds))
        : { data: [], error: null };
      if (permissionError) throw permissionError;

      const isSuperAdmin = allAssignedRoles.some((role) => role.code === "super_admin");
      const companyIds = assignmentRows.map((row) => row.company_id).filter((id): id is string => Boolean(id));
      const { data: companyRows, error: companyError } = await withAccessTimeout(supabase.from("companies").select("id, display_name").order("display_name"));
      if (companyError) throw companyError;
      const availableCompanies = isSuperAdmin ? companyRows ?? [] : (companyRows ?? []).filter((company) => companyIds.includes(company.id));

      const { data: profile, error: profileError } = await withAccessTimeout(supabase.from("profiles").select("default_company_id").eq("id", authData.user.id).maybeSingle());
      if (profileError) throw profileError;
      const selectedCompany = availableCompanies.find((company) => company.id === profile?.default_company_id) ?? availableCompanies[0];
      if (!selectedCompany) {
        clearIdentity();
        setNotice("No fue posible completar el acceso. Contacta a tu administrador.");
        return;
      }

      const companyRoles = assignmentRows
        .filter((row) => row.company_id === selectedCompany.id || row.company_id === null)
        .map((row) => Array.isArray(row.roles) ? row.roles[0] : row.roles)
        .filter((role): role is RoleOption => Boolean(role));
      const roleIdSet = new Set(assignmentRows.filter((row) => row.company_id === selectedCompany.id || row.company_id === null).map((row) => row.role_id));
      const permissions = ((permissionRows ?? []) as Array<{
        role_id: string;
        permissions: { code: string } | Array<{ code: string }> | null;
      }>)
        .filter((row) => roleIdSet.has(row.role_id))
        .map((row) => Array.isArray(row.permissions) ? row.permissions[0]?.code : row.permissions?.code)
        .filter((code): code is string => Boolean(code));

      const { data: locationRows, error: locationsError } = await withAccessTimeout(supabase
        .from("locations")
        .select("id, external_code, name, location_type, is_active")
        .eq("company_id", selectedCompany.id)
        .order("name"));
      if (locationsError) throw locationsError;

      setCompanies(availableCompanies);
      setAccessibleLocations((locationRows ?? []) as LocationRow[]);
      setAppState({
        userId: authData.user.id,
        email: authData.user.email ?? "",
        membership: {
          companyId: selectedCompany.id,
          companyName: selectedCompany.display_name,
          roles: companyRoles,
          permissions: [...new Set(permissions)],
        },
      });
      setNotice(null);
    } catch {
      clearIdentity();
      setNotice("No fue posible validar tu acceso. Intenta de nuevo o contacta a tu administrador.");
    } finally {
      setLoading(false);
    }
  }, [clearIdentity, configured]);

  useEffect(() => {
    void Promise.resolve().then(() => loadSession(true));
    if (!configured) return;
    const { data } = getSupabaseClient().auth.onAuthStateChange((event) => {
      if (event === "TOKEN_REFRESHED") return;
      queryCache.clear();
      void loadSession(event === "SIGNED_IN" || event === "SIGNED_OUT");
    });
    return () => data.subscription.unsubscribe();
  }, [configured, loadSession, queryCache]);

  const selectCompany = useCallback(async (companyId: string) => {
    if (!appState || !companies.some((company) => company.id === companyId) || companyId === appState.membership.companyId) return;
    try {
      const { error } = await withAccessTimeout(getSupabaseClient().from("profiles").update({ default_company_id: companyId }).eq("id", appState.userId));
      if (error) throw error;
    } catch {
      setNotice("No se pudo cambiar de empresa. Un administrador debe actualizar tu empresa predeterminada.");
      return;
    }
    queryCache.clear();
    setPreviewRole(null);
    await loadSession(false);
  }, [appState, companies, loadSession, queryCache]);

  const value = useMemo<SatrapyContextValue>(() => ({
    configured,
    loading,
    notice,
    appState,
    companies,
    accessibleLocations,
    previewRole,
    setPreviewRole,
    selectCompany,
    refreshAccess: async () => { queryCache.clear(); await loadSession(true); },
    queryCache,
  }), [accessibleLocations, appState, companies, configured, loading, notice, previewRole, queryCache, selectCompany, loadSession]);

  return <SatrapyContext.Provider value={value}>{children}</SatrapyContext.Provider>;
}

export function useSatrapy() {
  const context = useContext(SatrapyContext);
  if (!context) throw new Error("useSatrapy debe utilizarse dentro de SatrapyProvider.");
  return context;
}
