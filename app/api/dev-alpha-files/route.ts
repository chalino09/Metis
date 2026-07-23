import { lstat, readFile, readdir, stat } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const alphaFilePattern = /^(cata_prd|reexic2)_.+\.xlsx?$/i;

// Development-only bridge. Source XLS files are read into memory and are never
// copied, converted, moved, opened in Numbers, or modified.
export async function GET(request: NextRequest) {
  if (process.env.NODE_ENV !== "development") {
    return NextResponse.json({ message: "No disponible." }, { status: 404 });
  }

  const importDirectory = process.env.ALPHA_ERP_IMPORT_DIR;
  if (!importDirectory) {
    return NextResponse.json(
      { message: "No disponible." },
      { status: 409 },
    );
  }

  const requestedName = request.nextUrl.searchParams.get("name");
  try {
    if (!requestedName) {
      const entries = await readdir(importDirectory, { withFileTypes: true });
      const files = await Promise.all(
        entries
          .filter((entry) => entry.isFile() && alphaFilePattern.test(entry.name))
          .sort((first, second) => first.name.localeCompare(second.name))
          .map(async (entry) => {
            const metadata = await stat(resolve(importDirectory, entry.name));
            return {
              name: entry.name,
              type: entry.name.toLowerCase().startsWith("cata_prd_")
                ? "Catálogo de productos"
                : "Existencias por ubicación",
              size: metadata.size,
            };
          }),
      );
      return NextResponse.json({ files }, { headers: { "cache-control": "no-store" } });
    }

    if (requestedName !== basename(requestedName) || !alphaFilePattern.test(requestedName)) {
      return NextResponse.json({ message: "Nombre de archivo no permitido." }, { status: 400 });
    }

    const filePath = resolve(importDirectory, requestedName);
    const metadata = await lstat(filePath);
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      return NextResponse.json({ message: "El archivo solicitado no es un XLS regular permitido." }, { status: 400 });
    }
    const bytes = await readFile(filePath);
    return new NextResponse(bytes, {
      headers: {
        "content-type": "application/vnd.ms-excel",
        "cache-control": "no-store",
      },
    });
  } catch {
    return NextResponse.json(
      { message: "No se pudo completar la solicitud." },
      { status: 404 },
    );
  }
}
