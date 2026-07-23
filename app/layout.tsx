import type { Metadata } from "next";
import { GeistMono, GeistSans } from "geist/font";
import { headers } from "next/headers";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? "http";
  const metadataBase = new URL(`${protocol}://${host}`);

  return {
    metadataBase,
    title: "Satrapy · Operación, en orden",
    description: "Productos, inventario, ubicaciones y operación comercial multiempresa.",
    openGraph: {
      title: "Satrapy · Productos, inventario y ubicaciones",
      description: "Operación clara para productos, inventario y ubicaciones.",
      images: [{ url: "/og.png", width: 1200, height: 630, alt: "Satrapy · Productos, inventario y ubicaciones" }],
    },
    twitter: {
      card: "summary_large_image",
      title: "Satrapy · Productos, inventario y ubicaciones",
      images: ["/og.png"],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es-MX">
      <body
        className={`${GeistSans.variable} ${GeistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
