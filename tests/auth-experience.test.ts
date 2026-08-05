import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const provider = readFileSync("app/components/SatrapyProvider.tsx", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const styles = readFileSync("app/globals.css", "utf8");

test("la ausencia normal de sesión abre un formulario limpio", () => {
  assert.match(provider, /if \(!authData\.user\) \{\s*clearIdentity\(\);\s*return;/);
  assert.match(provider, /setAccessIssue\(hasAuthenticatedUser \? "access_unavailable" : null\)/);
  assert.doesNotMatch(provider, /No fue posible validar tu acceso/);
  assert.match(app, /if \(!appState\) return <LoginScreen \/>/);
  assert.doesNotMatch(app, /useState<string \| null>\(notice\)/);
});

test("un fallo posterior a autenticar usa recuperación y no el error de credenciales", () => {
  assert.match(provider, /setAccessIssue\("membership_missing"\)/);
  assert.match(app, /function AccessRecoveryScreen/);
  assert.match(app, /Tu sesión sigue activa, pero Satrapy no pudo cargar tus permisos/);
  assert.match(app, /Tu sesión es válida, pero no encontramos una empresa asignada/);
  assert.match(app, /Reintentar acceso/);
  assert.match(app, /Usar otra cuenta/);
});

test("los errores del formulario sólo nacen del envío y se limpian al editar", () => {
  assert.match(app, /const \[error, setError\] = useState<AuthFormError \| null>\(null\)/);
  assert.match(app, /async function submit\(event: React\.FormEvent\)/);
  assert.match(app, /setEmail\(event\.target\.value\); clearError\(\);/);
  assert.match(app, /setPassword\(event\.target\.value\); clearError\(\);/);
  assert.match(app, /El correo o la contraseña no coinciden/);
});

test("el formulario expone errores, nombres y foco de forma accesible", () => {
  assert.match(app, /aria-invalid=\{error\?\.field === "email" \|\| undefined\}/);
  assert.match(app, /aria-describedby=\{error\?\.field === "password" \? "auth-form-error" : undefined\}/);
  assert.match(app, /role="alert" tabIndex=\{-1\}/);
  assert.match(app, /aria-label=\{showPassword \? "Ocultar contraseña" : "Mostrar contraseña"\}/);
  assert.match(app, /autoComplete=\{mode === "login" \? "current-password" : "new-password"\}/);
  assert.match(styles, /auth-password-toggle[^}]*width:44px; height:44px/);
  assert.match(styles, /auth-form input:focus-visible/);
});

test("iniciar sesión mantiene la jerarquía principal del acceso", () => {
  assert.match(app, /Bienvenido de nuevo/);
  assert.match(app, /Entrar a Satrapy/);
  assert.match(app, /¿Aún no tienes cuenta\?/);
  assert.match(app, /mode === "login" \? "Crear cuenta" : "Iniciar sesión"/);
  assert.doesNotMatch(app, /Crear cuenta autorizada|¿Es tu primer acceso\?/);
  assert.doesNotMatch(app, /auth-mode-switch/);
  assert.doesNotMatch(styles, /auth-mode-switch/);
});
