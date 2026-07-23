"use client";

import { useEffect, type RefObject } from "react";

export function useDismissiblePopover<T extends HTMLElement>(
  containerRef: RefObject<T | null>,
  open: boolean,
  onDismiss: () => void,
) {
  useEffect(() => {
    if (!open) return;

    function handlePointerDown(event: PointerEvent) {
      const container = containerRef.current;
      if (container && event.target instanceof Node && !container.contains(event.target)) onDismiss();
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onDismiss();
    }

    document.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [containerRef, onDismiss, open]);
}
