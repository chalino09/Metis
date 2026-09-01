export type RestaurantRecipeImportUnit = "g" | "kg" | "ml" | "l" | "piece";

export type RestaurantRecipeImportComponent = {
  source_name: string;
  canonical_name: string;
  alias_reason: string | null;
  quantity: number;
  unit_code: RestaurantRecipeImportUnit | null;
  unit_cost: number | null;
  line_cost: number | null;
  source_row: number;
  warnings: string[];
};

export type RestaurantRecipeImportRecipe = {
  source_name: string;
  name: string;
  recipe_kind: "dish" | "preparation";
  yield_quantity: number | null;
  yield_unit_code: "piece" | "ml";
  portion_count: number | null;
  source_total: number | null;
  calculated_total: number;
  source_row: number;
  components: RestaurantRecipeImportComponent[];
  blockers: string[];
  warnings: string[];
};

export type RestaurantRecipeImportSource = {
  file_name: string;
  sheet_name: string;
  recipes: RestaurantRecipeImportRecipe[];
  blockers: string[];
  warnings: string[];
};

export type RestaurantRecipeCatalogItem = {
  id: string;
  internal_sku: string;
  name: string;
  unit: string;
  purchase_unit_code?: string | null;
  base_units_per_purchase_unit?: number | null;
};

export type RestaurantRecipeIngredientResolution = {
  canonical_name: string;
  source_names: string[];
  usage_count: number;
  status: "existing" | "create" | "blocked";
  existing_product: RestaurantRecipeCatalogItem | null;
  base_unit_code: "g" | "ml" | "piece" | null;
  purchase_unit_code: "KG" | "L" | "PZA" | null;
  base_units_per_purchase_unit: number | null;
  blockers: string[];
  warnings: string[];
};

export type RestaurantRecipeImportPreview = RestaurantRecipeImportSource & {
  ingredients: RestaurantRecipeIngredientResolution[];
  counts: { recipes: number; components: number; existing: number; create: number; blocked: number };
};

export type RestaurantRecipeImportPackage = {
  ingredients: Array<{canonical_key:string;canonical_name:string;existing_product_id:string|null;base_unit_code:"g"|"ml"|"piece";purchase_unit_code:"KG"|"L"|"PZA";base_units_per_purchase_unit:number}>;
  recipes: Array<{name:string;recipe_kind:"dish"|"preparation";yield_quantity:number;yield_unit_code:"piece"|"ml";components:Array<{canonical_key:string;quantity:number;base_unit_code:"g"|"ml"|"piece";sort_order:number;notes:string|null}>}>;
};

const explicitAliases: Record<string, { name: string; reason: string }> = {
  "ACEITE 123": { name: "Aceite", reason: "“123” se conserva como marca del insumo Aceite." },
  "CEBOLLITAS CAMBRAY": { name: "Cebolla cambray", reason: "Se normalizó el plural usado en la receta." },
  "CHILES CUARESMENOS": { name: "Chile cuaresmeño", reason: "Se normalizó el plural usado en la receta." },
  HUEVOS: { name: "Huevo", reason: "Se normalizó el plural usado en la receta." },
  "HARINA DE TRIGO": { name: "Harina", reason: "Se propone unificarla con Harina; debe revisarse antes de confirmar." },
  "COMINO MOLIDO Y ASADO": { name: "Comino", reason: "Se propone unificarlo con Comino; debe revisarse antes de confirmar." },
  "SALSA MAGY": { name: "Salsa Maggi", reason: "Se corrigió la escritura de la marca." },
};

const provisionalChickenIngredients = new Set(["PECHUGA POLLO", "POLLO PIERNA Y MUSLO"]);
const chileCuaresmenoWeightGrams = 1500 / 16;
const chileTampicoWeightGrams = 20 / 4;

export function restaurantImportKey(value: unknown) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toUpperCase()
    .replace(/\b\d+(?:\.\d+)?\s*(?:PZA|PZAS|PIEZA|PIEZAS|KG|GR|G|ML|L)\b/g, "")
    .replace(/[^A-Z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function titleCase(value: string) {
  return value.toLocaleLowerCase("es-MX").replace(/(^|\s)\p{L}/gu, letter => letter.toLocaleUpperCase("es-MX"));
}

function canonicalIngredient(sourceName: string) {
  const key = restaurantImportKey(sourceName);
  const alias = explicitAliases[key];
  if (alias) return { key: restaurantImportKey(alias.name), name: alias.name, reason: alias.reason };
  return { key, name: titleCase(key), reason: key !== restaurantImportKey(sourceName.trim()) ? "Se retiró la cantidad escrita dentro del nombre." : null };
}

function numberValue(value: unknown) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  const parsed = Number(String(value ?? "").trim().replace(",", "."));
  return Number.isFinite(parsed) ? parsed : null;
}

function unitValue(value: unknown): RestaurantRecipeImportUnit | null {
  const unit = restaurantImportKey(value);
  if (["PZA", "PZAS", "PIEZA", "PIEZAS"].includes(unit)) return "piece";
  if (["GR", "G", "GRAMO", "GRAMOS"].includes(unit)) return "g";
  if (["KG", "KILO", "KILOS", "KILOGRAMO", "KILOGRAMOS"].includes(unit)) return "kg";
  if (["ML", "MILILITRO", "MILILITROS"].includes(unit)) return "ml";
  if (["L", "LT", "LITRO", "LITROS"].includes(unit)) return "l";
  return null;
}

function parseYield(value: unknown) {
  const source = String(value ?? "").trim();
  const portions = source.match(/(\d+(?:[.,]\d+)?)\s*PORCIONES?/i);
  if (portions) {
    const amount = numberValue(portions[1]);
    return amount ? { recipe_kind: "dish" as const, yield_quantity: amount, yield_unit_code: "piece" as const, portion_count: amount } : null;
  }
  const volume = source.match(/(\d+(?:[.,]\d+)?)\s*L(?:ITROS?)?$/i);
  if (volume) {
    const liters = numberValue(volume[1]);
    return liters ? { recipe_kind: "preparation" as const, yield_quantity: liters * 1000, yield_unit_code: "ml" as const, portion_count: 1 } : null;
  }
  return null;
}

function isYieldMarker(value: unknown) {
  return Boolean(parseYield(value));
}

function normalizeRecipeName(value: string) {
  const key = restaurantImportKey(value).replace("CHILAQULES", "CHILAQUILES");
  if (key === "LENTEJAS") return "Lentejas guisadas";
  return titleCase(key);
}

export async function parseRestaurantRecipeWorkbook(input: ArrayBuffer, fileName: string): Promise<RestaurantRecipeImportSource> {
  const XLSX = await import("xlsx");
  const workbook = XLSX.read(input, { type: "array", cellDates: false });
  const sheetName = workbook.SheetNames.find(name => restaurantImportKey(name) === "DETALLE RECETAS");
  if (!sheetName) return { file_name: fileName, sheet_name: "", recipes: [], blockers: ["No se encontró la hoja DETALLE_RECETAS."], warnings: [] };
  const sheet = workbook.Sheets[sheetName];
  const rows = XLSX.utils.sheet_to_json<unknown[]>(sheet, { header: 1, defval: null, raw: true });
  if (rows.length > 1000) return { file_name: fileName, sheet_name: sheetName, recipes: [], blockers: ["La hoja supera el máximo de 1,000 filas por lote."], warnings: [] };
  const recipes: RestaurantRecipeImportRecipe[] = [];
  let current: RestaurantRecipeImportRecipe | null = null;
  for (let index = 3; index < rows.length; index += 1) {
    const values = rows[index] ?? [];
    const marker = String(values[1] ?? "").trim();
    if (marker && !isYieldMarker(marker)) {
      current = {
        source_name: marker,
        name: normalizeRecipeName(marker),
        recipe_kind: "dish",
        yield_quantity: null,
        yield_unit_code: "piece",
        portion_count: null,
        source_total: null,
        calculated_total: 0,
        source_row: index + 1,
        components: [],
        blockers: [],
        warnings: [],
      };
      recipes.push(current);
    } else if (marker && current) {
      const parsedYield = parseYield(marker);
      if (parsedYield) Object.assign(current, parsedYield);
    }
    if (!current || !String(values[3] ?? "").trim()) continue;
    const sourceName = String(values[3]).trim();
    const canonical = canonicalIngredient(sourceName);
    let quantity = numberValue(values[4]);
    let unit = unitValue(values[5]);
    const componentWarnings: string[] = [];
    if (!unit && canonical.key === "AJO" && numberValue(values[5]) != null) {
      unit = "piece";
      componentWarnings.push(`Fila ${index + 1}: se interpretó Ajo en piezas; la unidad contenía el costo 0.08.`);
    }
    if (canonical.reason) componentWarnings.push(canonical.reason);
    if (canonical.key === "CHILE TAMPICO" && unit === "piece" && quantity) {
      quantity = (quantity * chileTampicoWeightGrams) / 1000;
      unit = "kg";
      componentWarnings.push("Se convirtió con la referencia provisional del archivo: 4 piezas de Chile Tampico = 20 g.");
    }
    if (canonical.key === "CHILE CUARESMENO") {
      componentWarnings.push(`Peso provisional deducido del archivo: 16 piezas = 1.5 kg (${chileCuaresmenoWeightGrams.toFixed(2)} g por pieza).`);
    }
    if (provisionalChickenIngredients.has(canonical.key)) {
      componentWarnings.push("Se manejará provisionalmente como insumo independiente por kg; después podrá vincularse al despiece de Pollo entero.");
    }
    const component: RestaurantRecipeImportComponent = {
      source_name: sourceName,
      canonical_name: canonical.name,
      alias_reason: canonical.reason,
      quantity: quantity ?? 0,
      unit_code: unit,
      unit_cost: numberValue(values[6]),
      line_cost: numberValue(values[7]),
      source_row: index + 1,
      warnings: componentWarnings,
    };
    if (!(quantity && quantity > 0)) current.blockers.push(`Fila ${index + 1}: indica una cantidad válida para ${sourceName}.`);
    if (!unit) current.blockers.push(`Fila ${index + 1}: revisa la unidad de ${sourceName}.`);
    current.components.push(component);
    current.calculated_total += component.line_cost ?? 0;
    const sourceTotal = numberValue(values[8]);
    if (sourceTotal != null) current.source_total = sourceTotal;
  }
  for (const recipe of recipes) {
    recipe.calculated_total = Number(recipe.calculated_total.toFixed(6));
    if (restaurantImportKey(recipe.source_name) === "LENTEJAS" && !recipe.yield_quantity) {
      recipe.recipe_kind = "dish";
      recipe.yield_quantity = 8;
      recipe.yield_unit_code = "piece";
      recipe.portion_count = 8;
      recipe.warnings.push("Rendimiento confirmado provisionalmente: 0.5 kg de lentejas para 8 porciones.");
    }
    if (!recipe.yield_quantity || !recipe.portion_count) recipe.blockers.push(`${recipe.name}: falta indicar el rendimiento.`);
    if (!recipe.components.length) recipe.blockers.push(`${recipe.name}: no contiene ingredientes.`);
    if (recipe.source_total != null && Math.abs(recipe.source_total - recipe.calculated_total) > 1) {
      recipe.warnings.push(`${recipe.name}: el total escrito (${recipe.source_total}) no coincide con la suma de líneas (${recipe.calculated_total}). Satrapy recalculará el costo.`);
    }
  }
  const blockers = recipes.flatMap(recipe => recipe.blockers);
  const warnings = recipes.flatMap(recipe => [...recipe.warnings, ...recipe.components.flatMap(component => component.warnings)]);
  if (recipes.length !== 10) blockers.push(`Se esperaban 10 recetas y se detectaron ${recipes.length}.`);
  return { file_name: fileName, sheet_name: sheetName, recipes, blockers, warnings };
}

function inferredPresentation(units: Set<RestaurantRecipeImportUnit>) {
  if ([...units].some(unit => unit === "kg" || unit === "g")) return { base: "g" as const, purchase: "KG" as const, factor: 1000 };
  if ([...units].some(unit => unit === "l" || unit === "ml")) return { base: "ml" as const, purchase: "L" as const, factor: 1000 };
  if (units.has("piece")) return { base: "piece" as const, purchase: "PZA" as const, factor: 1 };
  return null;
}

export function reconcileRestaurantRecipeImport(source: RestaurantRecipeImportSource, catalog: RestaurantRecipeCatalogItem[]): RestaurantRecipeImportPreview {
  const existing = new Map(catalog.map(item => [restaurantImportKey(item.name), item]));
  const grouped = new Map<string, { name: string; sourceNames: Set<string>; units: Set<RestaurantRecipeImportUnit>; usage: number; warnings: Set<string> }>();
  source.recipes.forEach(recipe => recipe.components.forEach(component => {
    const key = restaurantImportKey(component.canonical_name);
    const item = grouped.get(key) ?? { name: component.canonical_name, sourceNames: new Set(), units: new Set(), usage: 0, warnings: new Set() };
    item.sourceNames.add(component.source_name);
    if (component.unit_code) item.units.add(component.unit_code);
    item.usage += 1;
    component.warnings.forEach(warning => item.warnings.add(warning));
    grouped.set(key, item);
  }));
  const ingredients = [...grouped.entries()].map(([key, item]): RestaurantRecipeIngredientResolution => {
    const product = existing.get(key) ?? null;
    const presentation = inferredPresentation(item.units);
    const blockers: string[] = [];
    if (!presentation) blockers.push("No fue posible definir una unidad base.");
    if (item.units.has("piece") && [...item.units].some(unit => unit !== "piece")) blockers.push("La receta mezcla piezas con peso o volumen para el mismo insumo.");
    if (product && presentation) {
      const productUnit = restaurantImportKey(product.unit);
      const compatible = (presentation.base === "piece" && ["PIECE", "PZA", "PIEZA"].includes(productUnit))
        || (presentation.base === "g" && ["G", "GR", "KG"].includes(productUnit))
        || (presentation.base === "ml" && ["ML", "L"].includes(productUnit));
      const provisionalCuaresmenoConversion = key === "CHILE CUARESMENO" && presentation.base === "g";
      if (!compatible && !provisionalCuaresmenoConversion) blockers.push(`La unidad existente (${product.unit}) no es compatible con las cantidades del Excel.`);
      if (provisionalCuaresmenoConversion) item.warnings.add(`Se reutilizará el insumo existente y se configurará por peso con la equivalencia provisional de ${chileCuaresmenoWeightGrams.toFixed(2)} g por pieza.`);
    }
    return {
      canonical_name: item.name,
      source_names: [...item.sourceNames],
      usage_count: item.usage,
      status: blockers.length ? "blocked" : product ? "existing" : "create",
      existing_product: product,
      base_unit_code: presentation?.base ?? null,
      purchase_unit_code: presentation?.purchase ?? null,
      base_units_per_purchase_unit: presentation?.factor ?? null,
      blockers,
      warnings: [...item.warnings],
    };
  }).sort((a,b) => a.status.localeCompare(b.status) || a.canonical_name.localeCompare(b.canonical_name,"es"));
  return {
    ...source,
    ingredients,
    counts: {
      recipes: source.recipes.length,
      components: source.recipes.reduce((sum, recipe) => sum + recipe.components.length, 0),
      existing: ingredients.filter(item => item.status === "existing").length,
      create: ingredients.filter(item => item.status === "create").length,
      blocked: ingredients.filter(item => item.status === "blocked").length + source.blockers.length,
    },
  };
}

function catalogBaseUnit(item:RestaurantRecipeIngredientResolution){
  const unit=restaurantImportKey(item.existing_product?.unit);
  if(["PIECE","PZA","PIEZA"].includes(unit))return "piece" as const;
  if(["ML","L"].includes(unit))return "ml" as const;
  if(["G","GR","KG"].includes(unit))return "g" as const;
  return item.base_unit_code;
}

function componentInBaseUnits(component:RestaurantRecipeImportComponent,base:"g"|"ml"|"piece"){
  if(base==="g")return component.unit_code==="kg"?component.quantity*1000:component.quantity;
  if(base==="ml")return component.unit_code==="l"?component.quantity*1000:component.quantity;
  if(base==="piece"&&restaurantImportKey(component.canonical_name)==="CHILE CUARESMENO"){
    return component.unit_code==="kg"?(component.quantity*1000)/chileCuaresmenoWeightGrams:component.quantity;
  }
  return component.quantity;
}

export function buildRestaurantRecipeImportPackage(preview:RestaurantRecipeImportPreview):RestaurantRecipeImportPackage{
  if(preview.counts.blocked)throw new Error("Resuelve los bloqueos antes de confirmar.");
  const resolutions=new Map(preview.ingredients.map(item=>[restaurantImportKey(item.canonical_name),item]));
  const ingredients=preview.ingredients.map(item=>{
    const base=catalogBaseUnit(item);
    if(!base||!item.purchase_unit_code||!item.base_units_per_purchase_unit)throw new Error(`Falta configurar ${item.canonical_name}.`);
    return {canonical_key:restaurantImportKey(item.canonical_name),canonical_name:item.canonical_name,existing_product_id:item.existing_product?.id??null,base_unit_code:base,purchase_unit_code:base==="piece"?"PZA":item.purchase_unit_code,base_units_per_purchase_unit:base==="piece"?1:item.base_units_per_purchase_unit};
  });
  const recipes=preview.recipes.map(recipe=>{
    const divisor=recipe.recipe_kind==="dish"?Number(recipe.portion_count):1;
    if(!(divisor>0)||!recipe.yield_quantity)throw new Error(`Falta el rendimiento de ${recipe.name}.`);
    return {
      name:recipe.name,recipe_kind:recipe.recipe_kind,
      yield_quantity:recipe.recipe_kind==="dish"?1:recipe.yield_quantity,
      yield_unit_code:recipe.recipe_kind==="dish"?"piece" as const:recipe.yield_unit_code,
      components:recipe.components.map((component,index)=>{
        const resolution=resolutions.get(restaurantImportKey(component.canonical_name));
        const base=resolution&&catalogBaseUnit(resolution);
        if(!base)throw new Error(`Falta resolver ${component.canonical_name}.`);
        return {canonical_key:restaurantImportKey(component.canonical_name),quantity:Number((componentInBaseUnits(component,base)/divisor).toFixed(6)),base_unit_code:base,sort_order:index,notes:component.warnings.length?component.warnings.join(" "):null};
      }),
    };
  });
  return {ingredients,recipes};
}
