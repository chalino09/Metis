export type PosMetricName = "search" | "add_item" | "checkout";

export type PosMetricSample = {
  name: PosMetricName;
  durationMs: number;
  recordedAt: string;
  network: "online" | "offline";
};

export type PosQueuedCartChange<TProduct = unknown> = {
  id: string;
  requestId: string;
  companyId: string;
  cartId: string;
  productId: string;
  quantityDelta: number;
  product: TProduct;
  expectedUnitTotal: number;
  createdAt: string;
};

export type PosQueuedCartChangeGroup<TProduct = unknown> = {
  ids: string[];
  requestId: string;
  companyId: string;
  cartId: string;
  productId: string;
  quantityDelta: number;
  product: TProduct;
  expectedUnitTotal: number;
};

type StoredEnvelope = { iv: number[]; ciphertext: ArrayBuffer };
type StoredValue<T> = { id: string; value: T };

const DATABASE_NAME = "satrapy-pos-resilience";
const DATABASE_VERSION = 1;
const KEY_STORE = "keys";
const VALUE_STORE = "values";
const DEVICE_KEY_ID = "device-aes-gcm";
const fallbackValues = new Map<string, unknown>();
const queueWrites = new Map<string, Promise<void>>();
let deviceKeyPromise: Promise<CryptoKey> | null = null;

function hasIndexedDb() {
  return typeof window !== "undefined" && "indexedDB" in window && "crypto" in window && Boolean(window.crypto.subtle);
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("No se pudo acceder al almacenamiento local."));
  });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("No se pudo guardar el cambio local."));
    transaction.onabort = () => reject(transaction.error ?? new Error("Se canceló el cambio local."));
  });
}

async function openDatabase() {
  if (!hasIndexedDb()) throw new Error("El almacenamiento local seguro no está disponible.");
  const request = window.indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
  request.onupgradeneeded = () => {
    const database = request.result;
    if (!database.objectStoreNames.contains(KEY_STORE)) database.createObjectStore(KEY_STORE);
    if (!database.objectStoreNames.contains(VALUE_STORE)) database.createObjectStore(VALUE_STORE);
  };
  return requestResult(request);
}

async function getDeviceKey(database: IDBDatabase) {
  if (!deviceKeyPromise) {
    deviceKeyPromise = (async () => {
      const readTransaction = database.transaction(KEY_STORE, "readonly");
      const existing = await requestResult(readTransaction.objectStore(KEY_STORE).get(DEVICE_KEY_ID)) as CryptoKey | undefined;
      if (existing) return existing;
      const key = await window.crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
      const writeTransaction = database.transaction(KEY_STORE, "readwrite");
      writeTransaction.objectStore(KEY_STORE).put(key, DEVICE_KEY_ID);
      await transactionDone(writeTransaction);
      return key;
    })().catch((error) => {
      deviceKeyPromise = null;
      throw error;
    });
  }
  return deviceKeyPromise;
}

async function encryptValue(database: IDBDatabase, value: unknown): Promise<StoredEnvelope> {
  const key = await getDeviceKey(database);
  const iv = window.crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const ciphertext = await window.crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext);
  return { iv: [...iv], ciphertext };
}

async function decryptValue<T>(database: IDBDatabase, envelope: StoredEnvelope): Promise<T> {
  const key = await getDeviceKey(database);
  const plaintext = await window.crypto.subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(envelope.iv) }, key, envelope.ciphertext);
  return JSON.parse(new TextDecoder().decode(plaintext)) as T;
}

async function readValue<T>(id: string): Promise<T | null> {
  if (!hasIndexedDb()) return (fallbackValues.get(id) as T | undefined) ?? null;
  const database = await openDatabase();
  try {
    const transaction = database.transaction(VALUE_STORE, "readonly");
    const envelope = await requestResult(transaction.objectStore(VALUE_STORE).get(id)) as StoredEnvelope | undefined;
    return envelope ? await decryptValue<T>(database, envelope) : null;
  } finally {
    database.close();
  }
}

async function writeValue(id: string, value: unknown): Promise<void> {
  if (!hasIndexedDb()) {
    fallbackValues.set(id, value);
    return;
  }
  const database = await openDatabase();
  try {
    const envelope = await encryptValue(database, value);
    const transaction = database.transaction(VALUE_STORE, "readwrite");
    transaction.objectStore(VALUE_STORE).put(envelope, id);
    await transactionDone(transaction);
  } finally {
    database.close();
  }
}

function scopedId(scope: string, name: string) {
  return `${scope}:${name}`;
}

export async function readPosCache<T>(scope: string, name: string): Promise<T | null> {
  return readValue<T>(scopedId(scope, `cache:${name}`));
}

export async function writePosCache<T>(scope: string, name: string, value: T): Promise<void> {
  await writeValue(scopedId(scope, `cache:${name}`), { id: name, value } satisfies StoredValue<T>);
}

export async function readPosCachedValue<T>(scope: string, name: string): Promise<T | null> {
  const stored = await readPosCache<StoredValue<T>>(scope, name);
  return stored?.value ?? null;
}

export async function readPosQueue<TProduct>(scope: string): Promise<Array<PosQueuedCartChange<TProduct>>> {
  return (await readValue<Array<PosQueuedCartChange<TProduct>>>(scopedId(scope, "queue"))) ?? [];
}

export async function appendPosQueue<TProduct>(scope: string, change: PosQueuedCartChange<TProduct>): Promise<void> {
  await updatePosQueue<TProduct>(scope, (queue) => [...queue, change]);
}

export async function replacePosQueue<TProduct>(scope: string, queue: Array<PosQueuedCartChange<TProduct>>): Promise<void> {
  await updatePosQueue<TProduct>(scope, () => queue);
}

export async function removePosQueueItems<TProduct>(scope: string, ids: string[]): Promise<Array<PosQueuedCartChange<TProduct>>> {
  const removed = new Set(ids);
  let remaining: Array<PosQueuedCartChange<TProduct>> = [];
  await updatePosQueue<TProduct>(scope, (queue) => {
    remaining = queue.filter((item) => !removed.has(item.id));
    return remaining;
  });
  return remaining;
}

async function updatePosQueue<TProduct>(scope: string, update: (queue: Array<PosQueuedCartChange<TProduct>>) => Array<PosQueuedCartChange<TProduct>>): Promise<void> {
  const previous = queueWrites.get(scope) ?? Promise.resolve();
  const next = previous.then(async () => {
    const queue = await readPosQueue<TProduct>(scope);
    await writeValue(scopedId(scope, "queue"), update(queue));
  });
  queueWrites.set(scope, next);
  try {
    await next;
  } finally {
    if (queueWrites.get(scope) === next) queueWrites.delete(scope);
  }
}

export function groupConsecutiveCartChanges<TProduct>(queue: Array<PosQueuedCartChange<TProduct>>): Array<PosQueuedCartChangeGroup<TProduct>> {
  const groups: Array<PosQueuedCartChangeGroup<TProduct>> = [];
  for (const change of queue) {
    const current = groups.at(-1);
    if (current && current.requestId === change.requestId && current.cartId === change.cartId && current.productId === change.productId) {
      current.ids.push(change.id);
      current.quantityDelta += change.quantityDelta;
      continue;
    }
    groups.push({
      ids: [change.id],
      requestId: change.requestId,
      companyId: change.companyId,
      cartId: change.cartId,
      productId: change.productId,
      quantityDelta: change.quantityDelta,
      product: change.product,
      expectedUnitTotal: change.expectedUnitTotal,
    });
  }
  return groups;
}

export function isPosCartRevisionConflict(message: string) {
  return /carrito cambi[oó] en otra operaci[oó]n/i.test(message);
}

export function rebasePosCartQuantityDelta(expectedQuantity: number, requestedDelta: number, authoritativeQuantity: number) {
  const intendedQuantity = Math.max(0, expectedQuantity + requestedDelta);
  return intendedQuantity - authoritativeQuantity;
}

export function percentile95(values: number[]) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)];
}

export async function recordPosMetric(scope: string, sample: PosMetricSample): Promise<Record<PosMetricName, number | null>> {
  const id = scopedId(scope, "metrics");
  const current = (await readValue<PosMetricSample[]>(id)) ?? [];
  const next = [...current, sample].slice(-300);
  await writeValue(id, next);
  return {
    search: percentile95(next.filter((item) => item.name === "search").map((item) => item.durationMs)),
    add_item: percentile95(next.filter((item) => item.name === "add_item").map((item) => item.durationMs)),
    checkout: percentile95(next.filter((item) => item.name === "checkout").map((item) => item.durationMs)),
  };
}

export async function getPosMetricP95(scope: string): Promise<Record<PosMetricName, number | null>> {
  const current = (await readValue<PosMetricSample[]>(scopedId(scope, "metrics"))) ?? [];
  return {
    search: percentile95(current.filter((item) => item.name === "search").map((item) => item.durationMs)),
    add_item: percentile95(current.filter((item) => item.name === "add_item").map((item) => item.durationMs)),
    checkout: percentile95(current.filter((item) => item.name === "checkout").map((item) => item.durationMs)),
  };
}
