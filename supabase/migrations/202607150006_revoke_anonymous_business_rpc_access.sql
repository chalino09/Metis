-- Business RPCs require an authenticated Satrapy identity. Supabase grants
-- EXECUTE to `anon` when functions are created, so revoking only from PUBLIC
-- is insufficient.
revoke execute on all functions in schema public from anon;

-- Keep future functions closed by default; migrations must grant the precise
-- authenticated contract explicitly.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon;
