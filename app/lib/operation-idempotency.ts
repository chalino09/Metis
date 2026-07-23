export type IdempotencyKeyFactory = () => string;

type Entry = { fingerprint: string; key: string };

export class OperationIdempotencyKeys {
  private readonly entries = new Map<string, Entry>();
  private readonly createKey: IdempotencyKeyFactory;

  constructor(createKey: IdempotencyKeyFactory = () => crypto.randomUUID()) {
    this.createKey = createKey;
  }

  get(scope: string, fingerprint: string): string {
    const current = this.entries.get(scope);
    if (current?.fingerprint === fingerprint) return current.key;
    const key = this.createKey();
    this.entries.set(scope, { fingerprint, key });
    return key;
  }

  clear(scope: string): void {
    this.entries.delete(scope);
  }
}
