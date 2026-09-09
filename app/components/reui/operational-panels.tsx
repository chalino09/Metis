"use client";

import { useRef, useId, type ComponentProps, type ReactNode } from "react";
import { Dialog } from "radix-ui";
import { preventDialogDismissForOpenSelect } from "@/components/reui/compact-select";
import { X, FileText } from "lucide-react";
import { cn } from "@/app/lib/utils";
import { Button } from "./button";
import { Card } from "./card";
import { ScrollArea } from "./scroll-area";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "./tabs";
import type { Drawer as LegacyDrawer, Modal as LegacyModal, Tabs as LegacyTabs } from "../ui/primitives";

type PanelProps = ComponentProps<typeof LegacyModal> & {
  drawer?: boolean;
  returnFocusRef?: { current: HTMLElement | null };
};

function OperationalPanel({ open, onOpenChange, title, eyebrow, description, children, footer, className, closeDisabled, returnFocusRef, drawer = false }: PanelProps) {
  const previousFocus = useRef<HTMLElement | null>(null);
  const descriptionId = useId();
  return <Dialog.Root open={open} onOpenChange={onOpenChange}>
    <Dialog.Portal>
      <Dialog.Overlay className={cn("ui-dialog-overlay purchasing-overlay", !drawer && "purchasing-overlay--modal")} />
      <Dialog.Content className={cn("purchasing-surface purchasing-panel", drawer ? "purchasing-panel--drawer" : "purchasing-panel--modal", className)}
        aria-describedby={description ? descriptionId : undefined}
        onEscapeKeyDown={preventDialogDismissForOpenSelect}
        onOpenAutoFocus={() => { previousFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null; }}
        onCloseAutoFocus={event => {
          const target = returnFocusRef?.current ?? previousFocus.current;
          if (target?.isConnected) { event.preventDefault(); target.focus(); }
        }}>
        <header className="purchasing-panel__header">
          <span className="purchasing-panel__icon"><FileText size={20} aria-hidden="true" /></span>
          <div>{eyebrow && <span className="eyebrow">{eyebrow}</span>}<Dialog.Title>{title}</Dialog.Title>
            {description && <Dialog.Description id={descriptionId}>{description}</Dialog.Description>}</div>
          <Dialog.Close asChild><Button variant="ghost" size="icon" aria-label="Cerrar" disabled={closeDisabled}><X size={18} aria-hidden="true" /></Button></Dialog.Close>
        </header>
        <ScrollArea className="purchasing-panel__scroll" viewportProps={{ tabIndex: 0, "aria-label": `Contenido de ${title}` }}>
          <div className="purchasing-panel__body">{children}</div>
        </ScrollArea>
        {footer && <footer className="purchasing-panel__footer">{footer}</footer>}
      </Dialog.Content>
    </Dialog.Portal>
  </Dialog.Root>;
}

export function OperationalDrawer(props: ComponentProps<typeof LegacyDrawer>) { return <OperationalPanel {...props} drawer />; }
export function OperationalModal(props: ComponentProps<typeof LegacyModal>) { return <OperationalPanel {...props} />; }

export function OperationalTabs({ items, ariaLabel, className, ...props }: ComponentProps<typeof LegacyTabs>) {
  return <Tabs {...props} className={cn("purchasing-tabs", className)}><TabsList aria-label={ariaLabel ?? "Secciones"}>
    {items.map(item => <TabsTrigger key={item.value} value={item.value} disabled={item.disabled}>{item.label}</TabsTrigger>)}
  </TabsList></Tabs>;
}

/** Document sections keep the summary visible while separating line items and evidence. */
export function OperationalDocumentTabs({ sections, defaultValue }: { sections: { id: string; label: string; content: ReactNode }[]; defaultValue?: string }) {
  return <Tabs defaultValue={defaultValue ?? sections[0]?.id} className="purchasing-tabs purchasing-document-tabs">
    <TabsList aria-label="Detalle del documento">{sections.map(section => <TabsTrigger key={section.id} value={section.id}>{section.label}</TabsTrigger>)}</TabsList>
    {sections.map(section => <TabsContent value={section.id} key={section.id}><Card className="purchasing-document-card">{section.content}</Card></TabsContent>)}
  </Tabs>;
}
