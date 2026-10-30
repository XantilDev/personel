-- Güncelleme: yönetici için çalışan pazar izni profili
-- Yönetici: çalışan bazında pazar izni özeti ve ayrıntısı
create or replace function y_pazar_ozet(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return coalesce((select json_agg(r order by r.aktif desc, r.ad) from (
    select c.id, c.ad, c.aktif,
      (select count(*) from _pazarlar(c.id)) as kazanilan,
      (select count(*) from _pazarlar(c.id) where kullanildi is not null) as kullanilan,
      (select count(*) from _pazarlar(c.id) where kullanildi is null) as kalan,
      (select count(*) from izin i where i.calisan_id = c.id and i.pazar_izni) as pazar_izni_girilen,
      (select count(*) from izin i where i.calisan_id = c.id and not i.pazar_izni) as normal_izin
    from calisan c) r), '[]'::json);
end $$;

create or replace function y_pazar_durumu(p_token text, p_calisan bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _yonetici(p_token);
  return json_build_object(
    'pazarlar', coalesce((select json_agg(json_build_object('pazar', pazar, 'kullanildi', kullanildi, 'firma', firma, 'il', il) order by pazar)
                          from _pazarlar(p_calisan)), '[]'::json),
    'kalan', (select count(*) from _pazarlar(p_calisan) where kullanildi is null),
    'izinler', coalesce((select json_agg(json_build_object('id', id, 'tarih', tarih, 'pazar_izni', pazar_izni, 'aciklama', aciklama) order by tarih desc)
                         from izin where calisan_id = p_calisan), '[]'::json)
  );
end $$;

grant execute on function y_pazar_ozet(text), y_pazar_durumu(text, bigint) to anon, authenticated;
