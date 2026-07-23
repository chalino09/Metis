export const ACCESS_CHECK_TIMEOUT_MS = 12_000;

export class AccessCheckTimeoutError extends Error {
  constructor() {
    super("La validación de acceso tardó demasiado.");
    this.name = "AccessCheckTimeoutError";
  }
}

export function withAccessTimeout<T>(operation: PromiseLike<T>, timeoutMs = ACCESS_CHECK_TIMEOUT_MS): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timeout = globalThis.setTimeout(() => reject(new AccessCheckTimeoutError()), timeoutMs);
    Promise.resolve(operation).then(
      (value) => {
        globalThis.clearTimeout(timeout);
        resolve(value);
      },
      (error: unknown) => {
        globalThis.clearTimeout(timeout);
        reject(error);
      },
    );
  });
}
