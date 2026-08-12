"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { getSupabaseClient, isSupabaseConfigured } from "@/app/lib/supabase";
import { withAccessTimeout } from "@/app/lib/access-loading";
import { ROLE_PREVIEW_PERMISSIONS } from "@/app/lib/navigation-access";
import { normalizeProductExperience, type ProductExperience } from "@/app/lib/product-experience";
import type { AppRoleCode, CompanyMembership, LocationRow, RoleOption } from "@/app/lib/types";

export type SatrapyAppState = {
  userId: string;
  email: string;
  membership: CompanyMembership;
};

export type SatrapyAccessIssue = "membership_missing" | "access_unavailable";
type CompanyAccessRow = { id: string; display_name: string; updated_at: string; product_experience_code?: unknown };

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
  accessIssue: SatrapyAccessIssue | null;
  appState: SatrapyAppState | null;
  isSuperAdmin: boolean;
  companies: Array<{ id: string; display_name: string; product_experience_code: ProductExperience; updated_at: string }>;
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
  const [isSuperAdmin, setIsSuperAdmin] = useState(false);
  const [companies, setCompanies] = useState<Array<{ id: string; display_name: string; product_experience_code: ProductExperience; updated_at: string }>>([]);
  const [accessibleLocations, setAccessibleLocations] = useState<LocationRow[]>([]);
  const [previewRole, setPreviewRole] = useState<AppRoleCode | null>(null);
  const [loading, setLoading] = useState(configured);
  const [accessIssue, setAccessIssue] = useState<SatrapyAccessIssue | null>(null);
  const cacheRef = useRef(new Map<string, unknown>());
  const appStateRef = useRef<SatrapyAppState | null>(null);

  useEffect(() => {
    appStateRef.current = appState;
  }, [appState]);

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
    setIsSuperAdmin(false);
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
    setAccessIssue(null);
    let hasAuthenticatedUser = false;
    try {
      const supabase = getSupabaseClient();
      const { data: authData, error: authError } = await withAccessTimeout(supabase.auth.getUser());
      if (!authData.user) {
        clearIdentity();
        return;
      }
      if (authError) throw authError;
      hasAuthenticatedUser = true;
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
      const companyResult = await withAccessTimeout(supabase.from("companies").select("id, display_name, product_experience_code, updated_at").order("display_name"));
      let companyRows = companyResult.data as CompanyAccessRow[] | null;
      let companyError = companyResult.error;
      if (companyError?.message.includes("product_experience_code")) {
        const fallbackCompanyResult = await withAccessTimeout(supabase.from("companies").select("id, display_name, updated_at").order("display_name"));
        companyRows = fallbackCompanyResult.data as CompanyAccessRow[] | null;
        companyError = fallbackCompanyResult.error;
      }
      if (companyError) throw companyError;
      const normalizedCompanies = (companyRows ?? []).map((company) => ({
        ...company,
        product_experience_code: normalizeProductExperience(company.product_experience_code),
      }));
      const availableCompanies = isSuperAdmin ? normalizedCompanies : normalizedCompanies.filter((company) => companyIds.includes(company.id));

      const { data: profile, error: profileError } = await withAccessTimeout(supabase.from("profiles").select("default_company_id").eq("id", authData.user.id).maybeSingle());
      if (profileError) throw profileError;
      const selectedCompany = availableCompanies.find((company) => company.id === profile?.default_company_id) ?? availableCompanies[0];
      if (!selectedCompany) {
        clearIdentity();
        setAccessIssue("membership_missing");
        return;
      }

      const companyRoles = assignmentRows
        .filter((row) => row.company_id === selectedCompany.id || row.company_id === null)
        .map((row) => Array.isArray(row.roles) ? row.roles[0] : row.roles)
        .filter((role): role is RoleOption => Boolean(role));
      const roleIdSet = new Set(assignmentRows.filter((row) => row.company_id === selectedCompany.id || row.company_id === null).map((row) => row.role_id));
      let permissions = ((permissionRows ?? []) as Array<{
        role_id: string;
        permissions: { code: string } | Array<{ code: string }> | null;
      }>)
        .filter((row) => roleIdSet.has(row.role_id))
        .map((row) => Array.isArray(row.permissions) ? row.permissions[0]?.code : row.permissions?.code)
        .filter((code): code is string => Boolean(code));
      if (isSuperAdmin) {
        const { data: permissionCatalog, error: permissionCatalogError } = await withAccessTimeout(supabase
          .from("permissions")
          .select("code"));
        if (permissionCatalogError) throw permissionCatalogError;
        permissions = (permissionCatalog ?? []).map((permission) => permission.code);
      }

      const { data: locationRows, error: locationsError } = await withAccessTimeout(supabase
        .from("locations")
        .select("id, external_code, name, location_type, is_active")
        .eq("company_id", selectedCompany.id)
        .order("name"));
      if (locationsError) throw locationsError;

      setCompanies(availableCompanies);
      setIsSuperAdmin(isSuperAdmin);
      setAccessibleLocations((locationRows ?? []) as LocationRow[]);
      setAppState({
        userId: authData.user.id,
        email: authData.user.email ?? "",
        membership: {
          companyId: selectedCompany.id,
          companyName: selectedCompany.display_name,
          companyUpdatedAt: selectedCompany.updated_at,
          productExperience: selectedCompany.product_experience_code,
          roles: companyRoles,
          permissions: [...new Set(permissions)],
        },
      });
      setAccessIssue(null);
    } catch {
      clearIdentity();
      // Sin una identidad confirmada, la ausencia normal de sesión conduce al
      // formulario limpio. Sólo una sesión válida con un fallo posterior de
      // acceso merece una pantalla de recuperación.
      setAccessIssue(hasAuthenticatedUser ? "access_unavailable" : null);
    } finally {
      setLoading(false);
    }
  }, [clearIdentity, configured]);

  useEffect(() => {
    void Promise.resolve().then(() => loadSession(true));
    if (!configured) return;
    const { data } = getSupabaseClient().auth.onAuthStateChange((event, session) => {
      // Supabase recupera la sesión al volver una pestaña a primer plano y emite
      // SIGNED_IN otra vez. Si la identidad no cambió, no se debe desmontar el
      // espacio de trabajo ni desechar las capturas aún no guardadas.
      if (event === "INITIAL_SESSION" || event === "TOKEN_REFRESHED") return;
      if (event === "SIGNED_IN" && session?.user.id === appStateRef.current?.userId) return;
      if (event === "SIGNED_OUT") {
        clearIdentity();
        setAccessIssue(null);
        setLoading(false);
        return;
      }
      if (event !== "SIGNED_IN") return;
      clearIdentity();
      void loadSession(true);
    });
    return () => data.subscription.unsubscribe();
  }, [clearIdentity, configured, loadSession]);

  const selectCompany = useCallback(async (companyId: string) => {
    if (!appState || !companies.some((company) => company.id === companyId) || companyId === appState.membership.companyId) return;
    try {
      const { error } = await withAccessTimeout(getSupabaseClient().from("profiles").update({ default_company_id: companyId }).eq("id", appState.userId));
      if (error) throw error;
    } catch {
      return;
    }
    queryCache.clear();
    setPreviewRole(null);
    await loadSession(false);
  }, [appState, companies, loadSession, queryCache]);

  const effectiveAppState = useMemo(() => {
    if (!appState || !previewRole) return appState;
    return {
      ...appState,
      membership: {
        ...appState.membership,
        permissions: ROLE_PREVIEW_PERMISSIONS[previewRole],
      },
    };
  }, [appState, previewRole]);

  const value = useMemo<SatrapyContextValue>(() => ({
    configured,
    loading,
    accessIssue,
    appState: effectiveAppState,
    isSuperAdmin,
    companies,
    accessibleLocations,
    previewRole,
    setPreviewRole,
    selectCompany,
    refreshAccess: async () => { queryCache.clear(); await loadSession(true); },
    queryCache,
  }), [accessIssue, accessibleLocations, companies, configured, effectiveAppState, isSuperAdmin, loading, previewRole, queryCache, selectCompany, loadSession]);

  return <SatrapyContext.Provider value={value}>{children}</SatrapyContext.Provider>;
}

export function useSatrapy() {
  const context = useContext(SatrapyContext);
  if (!context) throw new Error("useSatrapy debe utilizarse dentro de SatrapyProvider.");
  return context;
}
