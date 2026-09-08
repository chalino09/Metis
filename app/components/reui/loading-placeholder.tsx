"use client";

import { Card } from "./card";

/** Decorative geometry only; never represents quantities or business progress. */
export function LoadingPlaceholder({ label = "Cargando información…", kind = "table" }: { label?: string; kind?: "page" | "table" | "detail" }) {
  return <div className={`operational-loading operational-loading--${kind}`} role="status" aria-live="polite" aria-busy="true">
    <span className="operational-loading__label">{label}</span>
    <div aria-hidden="true">
      {kind === "page" && <div className="operational-loading__heading"><i/><i/></div>}
      <Card className="operational-loading__card">
        <div className="operational-loading__toolbar"><i/><i/></div>
        {Array.from({ length: kind === "detail" ? 3 : 6 }, (_, row) => <div className="operational-loading__row" key={row}><i/><i/><i/><i/></div>)}
      </Card>
    </div>
  </div>;
}
