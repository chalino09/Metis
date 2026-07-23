"use client";

import * as Dialog from "@radix-ui/react-dialog";
import * as RadixSelect from "@radix-ui/react-select";
import * as RadixTabs from "@radix-ui/react-tabs";
import * as RadixToast from "@radix-ui/react-toast";
import { Check, ChevronDown, X } from "lucide-react";
import {
  createContext,
  forwardRef,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ButtonHTMLAttributes,
  type InputHTMLAttributes,
  type ReactNode,
} from "react";

function cx(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "ghost" | "danger";
  size?: "sm" | "md" | "lg" | "icon";
  loading?: boolean;
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant = "secondary", size = "md", loading = false, disabled, children, type = "button", ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={cx("ui-button", `ui-button--${variant}`, `ui-button--${size}`, className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...props}
    >
      {loading && <span className="ui-button__spinner" aria-hidden="true" />}
      <span className={loading ? "ui-button__content is-loading" : "ui-button__content"}>{children}</span>
    </button>
  );
});

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input(
  { className, ...props },
  ref,
) {
  return <input ref={ref} className={cx("ui-input", className)} {...props} />;
});

export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: ReactNode;
  hint?: string;
  error?: string;
  children: ReactNode;
}) {
  return <label className="ui-field"><span>{label}</span>{children}{error ? <small className="ui-field__error">{error}</small> : hint ? <small>{hint}</small> : null}</label>;
}

export function Badge({
  tone = "neutral",
  children,
  className,
}: {
  tone?: "neutral" | "primary" | "success" | "warning" | "danger" | "info";
  children: ReactNode;
  className?: string;
}) {
  return <span className={cx("ui-badge", `ui-badge--${tone}`, className)}>{children}</span>;
}

export type SelectOption = { value: string; label: string; disabled?: boolean };

export function Select({
  value,
  onValueChange,
  options,
  placeholder = "Seleccionar",
  ariaLabel,
  disabled,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: SelectOption[];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
}) {
  const selected = options.find((option) => option.value === value);
  return (
    <RadixSelect.Root value={value} onValueChange={onValueChange} disabled={disabled}>
      <RadixSelect.Trigger className="ui-select" aria-label={ariaLabel}>
        <RadixSelect.Value>{selected?.label ?? placeholder}</RadixSelect.Value>
        <RadixSelect.Icon><ChevronDown size={15} /></RadixSelect.Icon>
      </RadixSelect.Trigger>
      <RadixSelect.Portal>
        <RadixSelect.Content className="ui-select__content" position="popper" sideOffset={6}>
          <RadixSelect.Viewport>
            {options.map((option) => (
              <RadixSelect.Item className="ui-select__item" value={option.value} disabled={option.disabled} key={option.value}>
                <RadixSelect.ItemText>{option.label}</RadixSelect.ItemText>
                <RadixSelect.ItemIndicator><Check size={14} /></RadixSelect.ItemIndicator>
              </RadixSelect.Item>
            ))}
          </RadixSelect.Viewport>
        </RadixSelect.Content>
      </RadixSelect.Portal>
    </RadixSelect.Root>
  );
}

export function Tabs({
  value,
  onValueChange,
  items,
}: {
  value: string;
  onValueChange: (value: string) => void;
  items: Array<{ value: string; label: string; disabled?: boolean }>;
}) {
  return (
    <RadixTabs.Root value={value} onValueChange={onValueChange}>
      <RadixTabs.List className="ui-tabs" aria-label="Secciones">
        {items.map((item) => <RadixTabs.Trigger className="ui-tabs__trigger" value={item.value} disabled={item.disabled} key={item.value}>{item.label}</RadixTabs.Trigger>)}
      </RadixTabs.List>
    </RadixTabs.Root>
  );
}

type ModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  eyebrow?: string;
  title: string;
  description?: string;
  children?: ReactNode;
  footer?: ReactNode;
  labelledBy?: string;
};

export function Modal({ open, onOpenChange, eyebrow, title, description, children, footer, labelledBy }: ModalProps) {
  const titleId = labelledBy ?? "satrapy-dialog-title";
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="ui-dialog-overlay" />
        <Dialog.Content className="ui-dialog" aria-describedby={description ? `${titleId}-description` : undefined}>
          <Dialog.Close asChild><button className="ui-dialog__close" aria-label="Cerrar"><X size={17} /></button></Dialog.Close>
          {eyebrow && <span className="eyebrow">{eyebrow}</span>}
          <Dialog.Title id={titleId}>{title}</Dialog.Title>
          {description && <Dialog.Description id={`${titleId}-description`}>{description}</Dialog.Description>}
          {children && <div className="ui-dialog__body">{children}</div>}
          {footer && <div className="ui-dialog__footer">{footer}</div>}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function Drawer({
  open,
  onOpenChange,
  title,
  children,
  className,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="ui-dialog-overlay" />
        <Dialog.Content className={cx("ui-drawer", className)}>
          <Dialog.Title>{title}</Dialog.Title>
          <Dialog.Close asChild><button className="ui-dialog__close" aria-label="Cerrar"><X size={17} /></button></Dialog.Close>
          <div className="ui-drawer__body">{children}</div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

type ToastItem = { id: number; title: string; description?: string; tone: "success" | "error" | "info" };
type ToastContextValue = { toast: (item: Omit<ToastItem, "id">) => void };
const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const toast = useCallback((item: Omit<ToastItem, "id">) => {
    const id = Date.now();
    setItems((current) => [...current.slice(-2), { ...item, id }]);
  }, []);
  const context = useMemo(() => ({ toast }), [toast]);
  return (
    <ToastContext.Provider value={context}>
      <RadixToast.Provider swipeDirection="right" duration={5000}>
        {children}
        {items.map((item) => (
          <RadixToast.Root className={cx("ui-toast", `ui-toast--${item.tone}`)} key={item.id} defaultOpen onOpenChange={(open) => !open && setItems((current) => current.filter((entry) => entry.id !== item.id))}>
            <RadixToast.Title>{item.title}</RadixToast.Title>
            {item.description && <RadixToast.Description>{item.description}</RadixToast.Description>}
            <RadixToast.Close className="ui-toast__close" aria-label="Cerrar"><X size={14} /></RadixToast.Close>
          </RadixToast.Root>
        ))}
        <RadixToast.Viewport className="ui-toast-viewport" />
      </RadixToast.Provider>
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) throw new Error("useToast debe usarse dentro de ToastProvider");
  return context;
}
