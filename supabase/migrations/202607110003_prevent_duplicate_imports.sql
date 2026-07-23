-- One exact Alpha file can be imported once per company and import type.
-- Backfill the batch-level digest from the existing audit record before
-- enforcing the uniqueness invariant for all future imports.
alter table public.import_batches
  add column if not exists file_sha256 text;

update public.import_batches batch
set file_sha256 = file.file_sha256
from public.import_files file
where file.import_batch_id = batch.id
  and batch.file_sha256 is null;

alter table public.import_batches
  alter column file_sha256 set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.import_batches'::regclass
      and conname = 'import_batches_company_type_file_sha256_key'
  ) then
    alter table public.import_batches
      add constraint import_batches_company_type_file_sha256_key
      unique (company_id, import_type, file_sha256);
  end if;
end;
$$;
