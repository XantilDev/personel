-- Teknik kayıtlarda sürüm: kaydın yazıldığı andaki uygulama sürümü (kayıt sonradan gönderilse de doğru görünsün).
-- Supabase › SQL Editor'a yapıştırıp Run'a bas. Mevcut verileri silmez.
create or replace function log_ekle(p_token text, p_cihaz jsonb, p_kayitlar jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s record; cid bigint;
        did text := left(coalesce(p_cihaz->>'id', ''), 64);
        n int := 0;
begin
  select * into s from _surucu(p_token); cid := s.cid;
  if did = '' then raise exception 'Cihaz kimliği yok'; end if;
  insert into cihaz (id, calisan_id, model, android, surum, surum_ad, durum, lat, lon, son)
  values (did, cid, left(p_cihaz->>'model', 80), left(p_cihaz->>'android', 20), (p_cihaz->>'surum')::int, left(p_cihaz->>'surum_ad', 40),
          left(p_cihaz->>'durum', 80), (p_cihaz->>'lat')::double precision, (p_cihaz->>'lon')::double precision, now())
  on conflict (id) do update set calisan_id = excluded.calisan_id, model = excluded.model, android = excluded.android,
    surum = excluded.surum, surum_ad = excluded.surum_ad, durum = excluded.durum,
    lat = coalesce(excluded.lat, cihaz.lat), lon = coalesce(excluded.lon, cihaz.lon), son = now();
  if jsonb_typeof(p_kayitlar) = 'array' then
    insert into teknik_log (cihaz_id, calisan_id, zaman, surum, tur, olay, mesaj, veri, lat, lon, hiz, sahsi)
    select did, cid,
           least(coalesce(to_timestamp((k->>'t')::bigint / 1000.0), now()), now() + interval '5 minutes'),
           coalesce(case when (k->>'s') ~ '^[0-9]{1,6}$' then (k->>'s')::int end, (p_cihaz->>'surum')::int),
           left(coalesce(k->>'tur', 'bilgi'), 10), left(coalesce(k->>'olay', '?'), 30), left(k->>'m', 1000),
           case when k ? 'v' and length((k->'v')::text) < 4000 then k->'v' end,
           (k->>'lat')::double precision, (k->>'lon')::double precision, (k->>'hiz')::int,
           coalesce((k->>'sahsi')::boolean, false)
    from (select value k from jsonb_array_elements(p_kayitlar) limit 500) x;
    get diagnostics n = row_count;
  end if;
  if random() < 0.02 then delete from teknik_log where zaman < now() - interval '30 days'; end if;
  return json_build_object('eklendi', n);
end $$;
