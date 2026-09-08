import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { DataState } from "../app/components/ui/data";

const props = { error: null, empty: "Sin productos", children: <button>Editar producto</button> };

test("la carga inicial no expone acciones ni cantidades provisionales", () => {
  const html = renderToStaticMarkup(<DataState {...props} loading hasData={0} loadingLabel="Cargando productos…" />);
  assert.match(html, /Cargando productos/);
  assert.match(html, /aria-busy="true"/);
  assert.doesNotMatch(html, /Editar producto/);
});
test("una actualización conserva contexto pero bloquea acciones sobre datos anteriores", () => {
  const html = renderToStaticMarkup(<DataState {...props} loading preserveData hasData={4} />);
  assert.match(html, /Actualizando resultados/);
  assert.match(html, /inert=""/);
  assert.match(html, /Editar producto/);
});
test("al finalizar se recuperan las acciones y el error no se convierte en vacío", () => {
  const ready = renderToStaticMarkup(<DataState {...props} loading={false} preserveData hasData={4} />);
  assert.doesNotMatch(ready, /inert|aria-busy/);
  const error = renderToStaticMarkup(<DataState {...props} loading={false} hasData={0} error="Consulta fallida" />);
  assert.match(error, /role="alert"/);
  assert.doesNotMatch(error, /Sin productos/);
});
