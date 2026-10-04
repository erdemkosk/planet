# Uzay Sınırı — Godot 4.7

İki küçük gezegen (yarıçap 60 m, merkezleri 350 m arayla, yüzeyler arası ~230 m) karşı karşıya duruyor. Kendi gezegeninde birinci
şahıs kamerayla başlıyorsun: elinde **Kazı Aracı** var. Köstebek gibi kazıp **malzeme** (genel toprak, m³)
topluyorsun. Malzemeyle yükseltip düzleyebilir ve mermi alabilirsin. **Tüfek** ve **pompalı** da elinde.
Rakip gezegen gökyüzünde asılı duruyor; orada beş kişilik bir **rakip takım** var: iki **Kazıcı** ortak
malzeme kazar, **Mühendis** top ve uçaksavar kurar, onarır ve sana ateş eder, **Muhafızlar** üssü dolaşır.
Gezegenlerine inersen siper alırlar, yana kayarlar, siperden çıkıp ateş eder, yaralanınca kaçar ve birbirlerini
yardıma çağırırlar. Nişan alınca adları görünür ("Rakip — Kazıcı").

Her gezegenin merkezinde parlayan bir **çekirdek** var. Kendi gezegenine **top** kur, rakibin gezegenini
dövüp çekirdeğine kadar kraterler aç: rakibin çekirdeği yok olursa **zafer**, seninki yok olursa **yenilgi**.
Maça tam bir top kuracak kadar malzemeyle başlarsın (rakip de); mermiler için kazman gerekir.

Karşıya geçmek için İnşa Aracıyla iki kişilik küçük bir **Mekik** kur: rakip gezegene uç, in, çık ve
çekirdeğe kadar kaz (ya da geri dön).

## Çalıştırma

Godot 4.7 ile `project.godot` dosyasını aç ve **F5**'e bas.

## Kontroller

| Tuş | İşlev |
|---|---|
| WASD · Shift | Yürü · koş |
| Boşluk | Zıpla. Havada basılı tutunca kısa, zayıf jetpack: çukurdan çıkmaya yeter. |
| 1 · 2 · 3 · 4 | Kazı Aracı · Tüfek · Pompalı · İnşa Aracı |
| İnşa Aracı | R / teker: ne kurulacağı (Top, Uçaksavar, varsa Mekik). Yeşil hayalet: kurulabilir; sol tık: kur. |
| Topta (F ile geç) | Fare: nişan · teker: barut · sol tık: ateş · F: in. Yörünge ve düşeceği yer önizlenir. |
| Uçaksavarda (F ile geç) | Fare: nişan · sol tık basılı: ateş · F: in. Gelen düşman mermisi için öndelik (sarı halka) gösterilir. |
| Mekikte (F ile bin) | Yerde: Boşluk / W kalk, fare etrafa bakar. Uçarken: fare burnu yönlendirir · W/S itki / fren-geri · A/D dön · Q/E yana kay · Boşluk/Ctrl yukarı/aşağı · Shift takviye · sağ tık etrafa bak · V dış kamera · L ışıklar · F in (yalnız yerde ya da 3 m altında yavaşken). |
| Sol tık · Sağ tık | Kullan · ikincil işlev. Kazı aracında ters mod (kaz ↔ yükselt), silahta nişan. |
| R | Kazı aracında mod değiştir (Kaz › Yükselt › Düzle). Silahta şarjör doldur. |
| Fare tekerleği | Kazı aracında fırça boyutu |
| T · B / orta tık | Tüfek: mermi türü (Standart · Delici) · tek / 3'lü atış |
| L | Kask feneri |
| F | Etkileşim |
| Esc | Devam · Ayarlar · Çıkış |
| F11 | Tam ekran / pencere |

- **Malzeme:** sağ üstte görünür. Kazmak malzeme kazandırır; yükseltmek ve düzlemek malzeme harcar.
- **Mermi:** şarjör + yedek. Yedek bitince doldururken eksik mermiler malzemeyle otomatik alınır; fiyatı sağ panelde yazar.
- **Can:** 100. Ölünce ~4 saniye yerde kalırsın, sonra kendi gezegeninde yeniden doğarsın. Malzeme kalır.
- **Top:** 600 m³, her mermi 40 m³. Mermi ~8–18 saniye uçar, düştüğü yerde ~5–6 m'lik krater açar; çekirdek ~58 m derinde. Toplar vurulup yok edilebilir.
- **Mekik:** 4,6 m, yan yana iki koltuk (pilot solda), kabarcık kanopi. Uçuş yardımlı: bıraktığın hızı tutar,
  tuşları bırakınca yavaşça durup havada asılı kalır, gezegen yakınında kendini düzler. Seyir ~22 m/s, takviye
  ~35 m/s: karşıya ~20–30 saniye. Yere yaklaşınca alçalma hızı kendiliğinden kısılır; yavaş ve alçakken
  Ctrl ile (ya da hiç dokunmadan, yere çok yakınken) bacaklarına oturur. Yakıt yok. Gövde 180: vurulur, çarpınca
  hasar alır; yok olursa pilot dışarı fırlar ve yaralanır. Göstergeler kokpitteki ekranda (hız, dikey hız,
  irtifa, YURT / RAKİP uzaklığı, gövde).
- **Uçaksavar:** 300 m³, her mermi 2 m³. Hızlı, yakınından geçerken havada patlayan (krater açmayan) mermiler atar; yakınında patlarsa gelen top mermisini havada düşürür. Rakip de kurar: mekiğini havada görürse 1–2 saniye sonra ateş açar (üstte kırmızı "RAKİP SENİ GÖRDÜ"). Düz uçarsan isabet alır, manevra yaparsan ıskalar.
- **Çekirdek:** üstte iki çubuk (YURT ÇEKİRDEĞİ · RAKİP ÇEKİRDEĞİ). Yakına düşen patlamalar ve kazı aracıyla doğrudan kazmak hasar verir.

## Kod düzeni

| Klasör | İçerik |
|---|---|
| `scripts/game.gd` | Autoload `Game`: girdi haritası, `Game.material`, mermi yedeği (`take_ammo`), toplam yerçekimi (`gravity_at`, `dominant_body`), hasar yardımcıları (grup `"damageable"`: `damage_target`, `area_damage`) |
| `scripts/main.gd` | Dünyayı kurar: yıldızlı gök, sabit güneş, iki gezegen, oyuncu, ses, HUD, duraklatma menüsü |
| `scripts/planet/` | Voxel gezegen: Surface Nets, LOD octree, GPU/CPU yoğunluk. Ön ayarlar `bodies.gd` içinde (`home`, `rival`); gezegen boyu ve aradaki mesafe tek yerde: `PLANET_RADIUS`, `PLANET_DISTANCE`. API: `apply_brush`, `crater`, `density_at`, `raycast_density`, `brush_applied` sinyali |
| `scripts/player/` | Oyuncu, kazı aracı, ortak kazma çekirdeği `dig.gd`, kollar (viewmodel), astronot gövdesi ve ragdoll |
| `scripts/items/` | Tüfek, pompalı, mermi efektleri, isabet hissi, `explosion.gd`, `ballistics.gd` (yörünge tahmini, iki gezegenin toplam yerçekimi) |
| `scripts/war/` | Savaş: `balance.gd` (tüm denge sabitleri), `core.gd` çekirdek, `cannon.gd` top, `shell.gd` top mermisi, `flak.gd` + `flak_round.gd` uçaksavar, `build_tool.gd` inşa aracı, `rival_team.gd` rakip takım (ortak malzeme, roller) + `ai_rival.gd` tek bot (görev ve çatışma yapay zekâsı), `war.gd` + `war_hud.gd` maç, zafer / yenilgi |
| `scripts/craft/` | Mekik: `skiff.gd` (uçuş, iniş, koltuk, hasar; inşa aracı sözleşmesi `BUILD_COST`, `footprint()`, `place()`), `skiff_build.gd` (prosedürel model), `skiff_shaders.gd`, `skiff_dash.gd` (kokpit ekranı), `skiff_overlay.gd` (nişan halkası), `skiff_audio.gd`, `skiff_wreck.gd` (enkaz) |
| `scripts/ui/` · `scripts/save/` · `scripts/audio/` | HUD, menüler ve ayarlar, ses |
| `tests/` | Yalnızca gezegen ölçüm araçları. Kullanıcı istemedikçe çalıştırılmaz. |

## Yedek

Pivot öncesi projenin tam yedeği (eski oyun: ana gemi, mekik, EVA, hikâye, canlılar…):
`C:\Users\erdem\AppData\Local\UzaySiniri\backups\space_2026-10-04_before_pivot`
