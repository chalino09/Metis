import { SatrapyProvider } from "@/app/components/SatrapyProvider";
import { SatrapyShell } from "@/app/components/SatrapyApp";

export default function SatrapyLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <SatrapyProvider><SatrapyShell>{children}</SatrapyShell></SatrapyProvider>;
}
