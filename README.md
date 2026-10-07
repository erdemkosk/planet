# Uzay Sınırı — Godot 4.7

İki küçük gezegen (yarıçap 30 m, merkezleri 350 m arayla, yüzeyler arası ~290 m) karşı karşıya duruyor. Kendi gezegeninde birinci
şahıs kamerayla başlıyorsun: elinde **Kazı Aracı** var. Köstebek gibi kazıp **malzeme** (genel toprak, m³)
topluyorsun. Malzemeyle yükseltip düzleyebilir ve mermi alabilirsin. Elinde yalnız **Kazı Aracı** (1) ve
**İnşa Aracı** (2) var: silahları önce bir **Silahlık** kurup orada **üretmen** gerekir (tüfek, pompalı, keskin
nişancı, itici, roketatar, raylı tüfek, hafif makineli, el bombası). Ürettiğin **her silah yanındadır** (sınır
yok): 3, 4, 5 … tuşları sırayla senin silahların. Ölen botların ve oyuncuların elindeki silah yere düşer; F'ye
basılı tutup alırsın (sende yoksa **ganimet** olarak eklenir, varsa mermisini alırsın).
Sondaj torpidosu artık atılmaz, **kurulur**: düşman gezegenine bir
**Sondaj Kulesi** dikersin, torpidoyu toprağa indirir, torpido oradan çekirdeğe kazar.
Rakip gezegen gökyüzünde asılı duruyor; orada üç kişilik bir **rakip takım** var: **Kazıcı** (ortak
malzeme kazar), **Mühendis** top ve uçaksavar kurar, onarır ve sana ateş eder, **Akıncı** baskınlar arasında üssü dolaşır.
Gezegenlerine inersen siper alırlar, yana kayarlar, siperden çıkıp ateş eder, yaralanınca kaçar ve birbirlerini
yardıma çağırırlar. Nişan alınca adları görünür ("Rakip — Kazıcı").

**Rakip mekik baskınları:** ~4. dakikadan sonra Mühendis kendi gezegeninde bir **mekik** kurar (koyu gri gövde,
kırmızı şeritler, "RK-0N"; malzemesi yetiyorsa **Silahlı Mekik**). İki bot biner (biri pilot) ve bizim gezegene
uçar: oyuncuyla aynı uçuş modeliyle kalkar, tırmanır, yoldaki gezegenin çevresinden dolaşır, tepelerin önünde
yükselir, yaklaşırken iniş yeri arar (düz zemin, krater / kazılmış kuyu değil, yapılardan uzak) ve üssümüzün
15–25 m ötesine (tercihen bir tepenin arkasına) iner. Uçarken üstte **"RAKİP MEKİĞİ YAKLAŞIYOR · N m"** ve ona
bir işaret / ekran kenarında ok çıkar. Uçaksavarımız onu görünce ateş eder; vurulunca ya da yakınında patlama
olunca pilot 0,6–1,5 s'de bir yön değiştirerek zikzak çizer (uçaksavarın takibi baştan başlar). **Silahlı
Mekik** inmeden önce ~25 s saldırı geçişleri yapar: önce uçaksavar ve toplarımız, sonra yayan sen, mekiklerin,
öbür yapılar ve dost botlar; hedefin önüne (biraz şaşarak) nişan alır, döner topu seri seri ve ısısını
kollayarak, yapılara 4'lü roket salvosu atar, gezegenin içinden ateş etmez, gövdesi %40'ın altına düşünce
saldırıyı keser. İnince botlar çıkar, savaşır, yapılarımıza ateş eder, rahat bırakılırsa çekirdeğe kuyu kazar;
biri ağır yaralanınca, mekik vurulunca ya da sen yanına gelince, en geç 4 dakika sonra binip dönerler (mekik
üslerinin yanına iner, aralarda onarılır). Yolda gövdesi %30'un altına düşerse geri döner. Mekik düşürülürse
içindekiler fırlayıp ölür; ~90 s sonra yenisi kurulur. Mekik baskınları ve çıkarma kapsülleri sırayla gelir
(aynı anda ikisi olmaz). Tek oyuncuda inmiş, boş bir rakip mekiğine F ile binersen onu **ele geçirirsin**
(boyası kalır).

**Rakibin kazı taktikleri ve üssü:** botlar toprağı strateji için kazar (her kazı gerçek, çok oyunculuda
eşitlenir, Tünel tarayıcı görür; takımın dakikada sınırlı bir kazı payı var).
- **Lağımcı tüneli:** bazı baskınlar (mekik ya da kapsül) üssümüzden 25–40 m öteye iner; içlerinden biri
  ~2 m genişliğinde bir tünel kazar: rampayla 3,5 m derine iner, toprağın altından topumuzun /
  uçaksavarımızın / taretimizin yanından geçip **arkasında yüzeye çıkar** ve ona saldırır, ya da üssümüzün
  altına kadar gidip oradan çekirdeğe kuyu açar. Diğer akıncılar peşinden tünele girer. Kazarken üstte
  "Rakip kazıyor: NN m" görünür. Aynı anda tek lağımcı olur.
- **Siper:** çatışmada yakında siper bulamayan bot olduğu yere hızla ~1,2 m'lik bir çukur kazar, içine
  çömelir, başını çıkarıp ateş eder. Muhafızlar zamanla toplarının önüne bir **hendek** hattı kazar.
- **Karşı tünel:** onların çekirdeğine doğru kazarsan (üslerinin altından çekirdeğe giden hattın ~15 m
  yakınında, 2,5 m'den derin), Mühendis ya da bir muhafız tünelinin ucuna doğru kazar ve seni yer altında
  karşılar; sen gitmişsen tüneline el bombası atıp onu çökertir.
- **Kaçış / pusu:** canı azalan ve siper bulamayan bot 2–3 m aşağı kazıp gözden kaybolur, iyileşince çıkar.
  Muhafızlar, gezegenlerinde senin yürüdüğün yolun 8–12 m yanına bir çukur kazıp orada pusuya yatar.
- **Sığınak:** üslerine top mermisi düşerken botlar Sığınak Modüllerine ya da Mühendis'in topların arkasına
  kazdığı sığınağa (rampa, ~1 m toprak altında oda, ateş yarığı, ışık) koşup bekler.
- **Üs parçaları:** Mühendis malzeme yettikçe çekirdeğinin yanına bir kuyu kazıp **Çekirdek Kalkanı**
  kurar (toplar kurulunca ilk iş), sonra toplarının yanına 2 **Otomatik Taret**, bir **Sığınak Modülü** ve
  tünellerine **ışık** koyar. Akıncılar önce taretleri ve çekirdek kalkanını hedefler; kapalı **Zırhlı
  Kapı**'dan geçemez, durup ateşle açarlar; duvarların ve modüllerin içinden geçmeyip yanından dolaşırlar.
- Toprağın altında sıkışan bot kendine yukarı rampa kazar (en kötü durumda yüzeye çıkarılır).

**Botların tepkileri ve beden dili** (kameraya ~60 m içindeki botlarda görünür):
- **Seni görünce:** bir an irkilir, başını sana çevirir, sol koluyla seni gösterir; başının üstünde küçük
  kırmızı bir **"!"** (~1 s) ve konuşma satırı ("Düşman görüldü! Saat 3 yönünde, 40 metre!"). Ancak bu
  ~0,75 s'lik andan sonra ateş eder. Yakındaki takım arkadaşları başlarını bildirilen yere çevirir, boşta
  olanlar o yöne bakan bir siper arar.
- **El işaretleri:** ilerlerken "İlerle!" (kol iki kez ileri), beklerken yumruk havada ("Pozisyonu koru!"),
  ateş altında şarjör değiştirmeden önce kaskına vurur ("Beni koruyun!"); "El bombası atıyorum!",
  "Geri çekiliyorum!", mekik baskını dönerken "Mekiğe!".
- **Duygular:** yakına düşen patlamada çömelip kolunu vizörünün önüne kaldırır; yakında bir arkadaşı
  düşünce ona bakar, durur, en yakını "Kazıcı düştü!" der; seni vurunca kısa bir yumruk ("Hedef etkisiz!");
  canı %35'in altındayken topallar, eli böğründe, "Yaralıyım!"; yoğun ateş altında kambur durur
  ("Bastırıldım!").
- **Boşta:** etrafına bakınır, gerinir, tüfeğini kontrol eder, vizörünü siler; kazıcılar arada dinlenir
  (eğilip eli dizinde), muhafızlar devriyede başlarıyla tarar, mühendisler yapılarının yanına gidip elini
  panele koyup aletiyle tarar.
- **Dost botlar:** yanlarına gelince el sallar (ya da başıyla selam verir); yakınında bir rakibi
  vurunca yumruk kaldırır, "İyi atış!"; gördükleri düşmanı sana gösterir ("Düşman! Saat 2 yönünde, 25
  metre!" — saat senin baktığın yöne göre) ve düşmanın üstünde ~2 s sarı bir "!" yanar; F komutunda
  başıyla onaylayıp avuç kaldırır ("Anlaşıldı, peşindeyim!").
- **Duyma:** silah sesini ~45 m'den duyarlar, boştakiler sesin geldiği yere döner ve siper alır.
  **Susturucu** takılı silahın sesi yalnız ~16 m'den duyulur (eklentinin "ses" değeri); 2 m'den yakına
  geçen mermi yine fark edilir ama susturuculu ve uzaktan atılmışsa yerin yalnız kabaca tahmin edilir.

**Her maç yeni gezegenler:** iki gezegen de maç başında tek bir **tohumdan** rastgele kurulur: renk ailesi
(Kızıl çöl, Hardal, Gül kayası, Bakır, Kül, Mor bazalt, Buzul, Yosun, Toprak; küçük renk oynamalarıyla),
kabartma (kıtalar, tepeler, sıradağlar, kraterler; bazen düzlükler, basamaklar, yarıklar ya da küçük
volkan konileri), kaya sıklığı ve gürültü tohumları. Yurt ile Rakip hiçbir zaman aynı renk grubundan
(sıcak / soğuk / yeşil) gelmez. Gezegenlerin bir de adı olur ("Yurt — Kızıl Kum · Rakip — Kül Ovası":
başlangıçta ekranda, maç sonunda tohumla birlikte altta küçük yazar). Tek oyuncuda **Yeniden başla** yeni
bir tohum çeker. Çekirdek renkleri (bizimki mor, rakibinki kızıl) takım rengi olarak hep aynı kalır. Kabartma 30 m'lik
gezegene göre sınırlıdır (en yüksek yer ~6,5 m): doğma, inşa ve çekirdek derinliği değişmez. Çok oyunculuda
tohum oda sahibinin maç ayarından gelir, iki taraf aynı gezegenleri kurar (oda boyunca, yeniden başlatınca da aynı). Eğitim Alanı sabit gezegenini korur.
Aynı tohumu tekrar oynamak: oyunu `-- --seed=123456` ile başlat.

**Dost botlar (tek oyuncu):** Yurt'ta yanında iki dost bot var (`Balance.ALLY_COUNT`), rakip botlarla aynı
yapay zekâ (siper, kayma, zıplama, isabet tepkileri, ragdoll): beyaz tüfek, göğüste "DOST", camgöbeği /
yeşil rol ışığı, nişan alınca yeşil ad etiketi ("Dost — Muhafız").
- **Muhafız:** üsse yakınken (üsten ~50 m) yürüyerek seni ~7 m yandan-geriden takip eder (3 m'den yakına gelmez, kazarken / nişan alırken görüşünden çekilir); sen uzaktayken, mekikteyken
  ya da ölüyken üssü ve yapılarını dolaşır. Ona bakıp **F**: "Üssü koru" ↔ "Beni takip et".
- **Kazıcı:** üssün 12–24 m çevresinde (yapılardan ve senden uzakta) çukur kazar; kazdıkça **senin
  malzemen** saniyede 4 m³ artar (kazan bir oyuncunun yarısı kadar). F: "Beni takip et" ↔ "Kazmaya dön".
- Gezegenimize inen rakip botlara (çıkarma kapsülü ekipleri) ateş ederler; kapsül yakına inince ve
  gezegenimizde rakip bot dolaşırken oraya koşarlar (Kazıcı yalnız yakınsa). Rakip botlar, top mermileri
  ve patlamalar onları düşman sayar; senin isabetlerin onlara dörtte bir hasar verir (dost ateşi) ve
  onları sana düşman etmez. Ölünce rakip botlar gibi 10 s sonra bizim Taşıyıcı'nın iniş gemisiyle üssün yanına inerler;
  silah ya da malzeme düşürmezler. Çok oyunculuda ve Eğitim Alanı'nda dost bot yoktur.

Her gezegenin merkezinde parlayan bir **çekirdek** var (bizimki mor, rakibinki kızıl plazma). Kendi gezegenine **top** kur, rakibin gezegenini
dövüp çekirdeğine kadar kraterler aç: rakibin çekirdeği yok olursa **zafer**, seninki yok olursa **yenilgi**.
Maça tam bir top kuracak kadar malzemeyle başlarsın (rakip de); mermiler için kazman gerekir.

Karşıya geçmek için İnşa Aracıyla iki kişilik küçük bir **Mekik** kur: rakip gezegene uç, in, çık ve
çekirdeğe kadar kaz (ya da geri dön). Düşman gezegeninde de kurabilirsin: **Sondaj Kulesi** (yalnız orada),
onu korumak için **Uçaksavar** ve geri dönmek için **Mekik** / **Silahlı Mekik**. Silahlık, Top ve Delici Top
yalnız kendi gezegenine kurulur. Orada kurduğun yapı senindir: rakip muhafızlar ona yürüyüp ateş eder
(hâlâ torpido indiren bir kuleye en çok bot gider, kazıcılar da).

## Çalıştırma

Godot 4.7 ile `project.godot` dosyasını aç ve **F5**'e bas. Oyun ana menüyle açılır: **Tek Oyuncu**
(eskisi gibi, yapay zekâ rakibe karşı), **Çok Oyunculu**, **Ayarlar**, **Çıkış**.

## Çok Oyunculu

İki oyuncu, senin sinyal sunucun (`wss://38-242-230-203.sslip.io`, relay-main/server.js) üzerinden
buluşur; oyun trafiği iki bilgisayar arasında doğrudan (WebRTC, `addons/webrtc_native`; aynı ağda
doğrudan olmazsa TURN) akar.

**Oda kurmak:** Çok Oyunculu › adını yaz › **Oda Kur** › modu seç › **Odayı Aç**. Ekranda büyük bir
oda kodu çıkar (`UZAY-` önekli 5 harf; **Kopyala** panoya alır). Arkadaşın katılınca ikiniz de maça
geçersiniz; **Şimdi başla** ile beklemeden başlayabilirsin, arkadaşın sonra da katılır (dünya ona
o anki haliyle gönderilir). **Odaya katılmak:** **Odaya Katıl** › kodu yaz › **Katıl**, ya da
"Açık odalar" listesinden seç. Odada en çok iki kişi olur; üçüncüsü "Oda dolu" görür.

**Modlar**
- **Birlikte:** ikiniz Yurt'tasınız, rakip yapay zekâ takımı. Malzeme **ortak**: ikinizin kazdığı ve harcadığı tek bir **TAKIM MALZEMESİ** (oda sahibinde tutulur). Arkadaşın İnşa Aracı elindeyken onun hologramını soluk camgöbeği ve adıyla görürsün ("Ali · Taret yerleştiriyor"); kurunca "Arkadaşın (Ali) Uçaksavar kurdu"; orta tık / B ile bıraktığı "BURAYA KUR" işaretlerini ikiniz de 20 sn görürsünüz. Takım malzemesi iki kişilik başlar; ölünce yere düşen pay bunun yarısı kadardır (kişisel modda olanın yarısı). Z (kendi kurduğunu geri al) ve X (sök, yarı fiyatı geri) katılan için de çalışır.
  Birbirinize ateş ederseniz hasar dörtte birdir (yapılardaki gibi). Arkadaşın mekiği uçururken
  F ile **yolcu koltuğuna** oturabilirsin (fare: etrafa bak, F: in — yerdeyken ya da alçak ve yavaşken).
- **Karşı Karşıya:** oda sahibi Yurt, katılan Rakip gezegeninde başlar; yapay zekâ yok. İkiniz de
  aynı malzemeyle başlarsınız, herkes kendi gezegenine kurar, kendi topunu / uçaksavarını kullanır;
  rakibin çekirdeğini yok eden kazanır. Göstergeler herkese kendi gözünden: üstteki çubuklar
  "YURT ÇEKİRDEĞİ" = kendi çekirdeğin, "RAKİP ÇEKİRDEĞİ" = karşı tarafın.

**Oyun içi:** Enter sohbeti açar (Enter gönder, Esc kapat). Sağ üstte mod, arkadaşının adı ve ping.
Esc menüsü oyunu **durdurmaz**; **Odadan Ayrıl** ana menüye döner. Maç bitince oda sahibi
**Yeniden başla** ile ikiniz için yeni maç açar (katılan "Host yeniden başlatabilir…" görür).
Oda sahibi çıkarsa katılan "Host ayrıldı" ile menüye döner; katılan çıkarsa oyun sürer (Karşı
Karşıya'da oda sahibine "yapay zekâya karşı devam et" önerilir).

**Neler eşitlenir:** oyuncular (20 Hz konum, bakış, koşma / zıplama / jetpack alevi ve sesi, eldeki
alet, çömelme / kayma, keskin nişancı dürbün parlaması, kazı ışını ve sesi, namlu ışığı, iz mermisi,
isabet tozu, silah sesi ve vızıltısı, fener, ragdoll, ölüm ve yeniden doğma, isim etiketi, el bombaları); arazi (her kazma / yükseltme / düzleme, botların kazısı, top
kraterleri: sıralı işlemler, 2 saniyede bir bölge sağlama toplamı ve gerekirse bölge yeniden
gönderimi, katılınca tüm arazi; Tünel tarayıcının gördüğü kazı izleri de); yapılar (kurulma, can, nişan açıları, kimin kullandığı, yok
olma), top mermileri ve uçaksavar mermileri (iki tarafta da uçar, isabeti oda sahibi belirler),
çekirdek canı ve yok oluşu, mekik (konum, hız, itki alevleri, ışıklar, ses, iniş, pilot / yolcu,
gövde canı, hasar efekti, yok olma), yapay zekâ botları (10 Hz, ara değerleme; atış, isabet sarsılması, kazı, ölüm,
yeniden doğma), maç sonu ve yeniden başlatma, sohbet. İsabet tepkileri de eşitlenir: merminin değdiği
yer (kafa, kol, bacak…) iki tarafa da gider; botların ve öbür oyuncunun sarsılması, sendelemesi, yere
düşüp kalkması ve ölü bedenin vurulduğu yere göre savrulması öbür ekranda da aynı biçimde görünür.
Yere düşen malzeme kutuları da eşitlenir: kutuları oda sahibi oluşturur; katılan ölünce payı oda
sahibinden düşürülür, kutuyu kim önce alırsa malzeme onundur. Rakibin çıkarma kapsülleri de eşitlenir
(uçuş, iniş, havada vurulma, sonradan katılana da gösterilir). Rakibin mekik baskınları da: botların
uçurduğu mekik oda sahibinde uçar, katılana mekik eşitlemesiyle (20 Hz) gelir, içinde oturan pilot
görünür, Silahlı Mekik'in atışları iki ekranda da uçar (hasarı oda sahibi verir), "RAKİP MEKİĞİ
YAKLAŞIYOR" uyarısı katılanda da çıkar; çok oyunculuda rakip mekiğine binilemez (ele geçirme yalnız tek
oyuncuda). Cesetler her ekranda yerel olarak kalır.
Raylı Tüfek'in ışını öbür ekranda da çizilir (deldiği toprak oda sahibinde kazılır); Otomatik Kazıcı'yı
katılan kurarsa ürettiği malzeme katılana gider.

**Kim karar verir:** oda sahibi (host) botları, mermi / patlama isabetlerini, tüm canları,
yapıların kurulmasını ve maç sonunu yönetir. Herkes kendi yürüyüşünü ve uçurduğu mekiği kendisi
sürer. Katılanın mermisi isabeti kendi ekranında bulur ve oda sahibine bildirir.

**Bilinen sınırlar**
- İki oyuncu; oda sahibi ayrılırsa oda kapanır (devir yok).
- Katılanın ekranındaki botlar ve uzak oyuncu ~0,1–0,15 sn geriden gelir; çok hızlı hedeflerde
  isabet kendi ekranına göre sayılır.
- Aynı yeri aynı anda ikiniz kazarsanız arazi birkaç saniye farklı görünebilir; sağlama toplamı
  bunu düzeltir.
- Birlikte modunda boştaki (kimsenin kullanmadığı) uçaksavarların mermisi oda sahibinin
  malzemesinden düşer.
- Botların "yakın / uzak" ayrıntı düzeyi iki oyuncuya göre seçilir, ama görüş hattı ölçümü oda
  sahibinin bilgisayarında yapılır.
- Sunucu adresi / anahtarı: `scripts/net/mp_config.gd` (ortam değişkenleri `UZAY_SIGNALING_URL`,
  `UZAY_RELAY_KEY`, yerel sunucu için `UZAY_USE_LOCAL=1`, ya da `user://relay.cfg`).
- WebRTC eklentisi yalnız Windows x86_64 ve Linux x86_64 için var.
- Roketatar, Kinetik İtici, Sondaj Kulesi ve torpidosu, el bombası ve Delici Top eşitlenir (roket ve bomba
  iki ekranda da uçar, isabeti oda sahibi belirler; İtici'nin itişi, botları savurması ve mermi
  saptırması oda sahibinde olur; kulenin hazırlığı ve canı, torpidonun gömülmesi, canı ve çekirdeğe
  varışı oda sahibinden gelir). Düşman gezegenine kurma kuralını da oda sahibi denetler.
  Saptırılan bir top mermisi öbür ekranda ancak düştüğünde doğru yere gelir.
  Botların el bombaları, atış hareketi, torpidoları, Delici Topları ve torpido avı da eşitlenir.
  Tünel tarayıcının dalgası yereldir (gördüğü izler eşit).
- Uçuştaki top mermileri sonradan katılana gönderilmez.

**İki pencerede denemek (tek bilgisayar):** Godot'ta *Debug › Customize Run Instances…* ile 2
örnek aç (ya da dışa aktarılmış oyunu iki kez çalıştır). Birinde Oda Kur, diğerinde kodla Katıl.

## Kontroller

| Tuş | İşlev |
|---|---|
| WASD · Shift | Yürü · koş |
| Boşluk | Zıpla. Havada basılı tutunca kısa, zayıf jetpack: çukurdan çıkmaya yeter. |
| 1 · 2 | Kazı Aracı (Matkap) · İnşa Aracı (başlangıçta yalnız bunlar) |
| 3 · 4 · 5 … 9 · 0 | Yanındaki silahlar, şu sabit sırayla ama yalnız sende olanlar arka arkaya: Tüfek, Pompalı, Hafif Makineli, Keskin Nişancı, Kinetik İtici, Roketatar, Delici Raylı Tüfek. İlk ürettiğin silah 3, ikincisi 4… (ör. yalnız Pompalı ve Roketatar varsa: 3 Pompalı, 4 Roketatar). Sınır yok: ürettiğin her silah yanındadır. |
| Fare tekerleği (silah elde) | Silahlar arasında sırayla geç (aşağı: sonraki, yukarı: önceki, başa döner; dürbündeki Keskin Nişancı'da zum; Matkap ve İnşa Aracı'nda tekerin kendi işi) |
| Silahlıkta (F) | İki sekme (tıkla ya da **Tab**). **ÜRETİM:** her silahın kartı (resim, bedel, süre, hasar / atış / şarjör). Karta tıkla (G: el bombası): üretim başlar, bitince yanına eklenir ("YENİ SİLAH · tuş 4"); uzaklaşabilirsin. **CEPHANELİK:** yanındaki bütün silahlar (salt okunur): tuşu, resmi, şarjör / yedek, atış modu, ağırlığı, elindekinde "ELDE", ganimette "GANİMET". Esc / F: kapat. |
| F basılı (yerde silah) | Yerdeki silahın üstüne gelince "[F basılı tut] Tüfek al · ganimet": ~0,5 s basılı tut. Sende olmayan silah **ganimet** olarak eklenir (sıradaki tuşu alır, eline geçer, ölünce gider); sende olan silahın yalnız mermisini alırsın ("Mermi al (+N)"). |
| Raylı Tüfek elde | Sol tık basılı: şarj et (~1,2 s, nişangâhta şarj halkası), bırak: ateş (az şarj = az hasar; %15'in altı yalnız boşaltır) · Sağ tık: 2,5× dürbün; dürbünde şarj ederken 30 m içindeki düşmanlar **toprağın içinden** görünür · R: şarjör (4) ya da şarj ederken şarjı boşalt |
| Hafif Makineli elde | Sol tık: ateş · B / orta tık: TEK ↔ SERİ (sağ alttaki silah panelinde ve bir an nişangâhın yanında yazar) · Sağ tık: nişan (gez-arpacık) · R: şarjör (32) |
| Keskin Nişancı elde | Sağ tık basılı: dürbün (4× / 6×: teker, B ya da orta tık) · Shift: nefesini tut (dürbünde) · her atıştan sonra sürgü (~1,3 s) · R: şarjör (5 mermi) |
| Ctrl (basılı) · C | Çömel (basılı tut) · çömel aç / kapa. Koşarken basınca **kayarsın** (Boşluk: kayarken zıpla, hızın kalır). Alçak tavanın altında ayağa kalkamazsın. |
| İnşa Aracı | Üç **kategori**, on kart; bazı kartların **çeşitleri** var: **Savunma**: Top (Standart / Delici), Uçaksavar, Taret · **Üs**: Sığınak (Modül / Duvar / Kapı / Işık), Çekirdek Kalkanı, Radar, Silahlık, Otomatik Kazıcı · **Saldırı**: Mekik (Silahsız / Silahlı), Sondaj Kulesi. **Q / E**: kategori (İnşa Aracı eldeyken Q tarayıcıyı açmaz) · teker: kart · **T** (Shift+T geri) ya da Shift + teker: çeşit. Son seçtiğin kategori, her kategorideki kart ve her kartın çeşidi hatırlanır: aracı yeniden alınca kaldığın yerden devam edersin; kurduktan sonra aynı parça seçili kalır (modülleri / duvarları art arda ekle). Sığınak modülünün kendi tavan lambası var. Her kartta resim, bedel, GÖVDE ve sade bir **NE İŞE YARAR** satırı; malzeme yetmiyorsa kırmızı ve eksiği yazar; duruma göre bir karta **ÖNERİLEN** rozeti ve nedeni (ör. "Rakip mekik geliyor") · R: 45° döndür (Top, Uçaksavar, Delici Top ve Taret kendiliğinden düşman gezegenine / en yakın tehdide döner) · sağ tık basılı + fare: serbest döndür · sol tık: kur. Hologram (aletin ucundaki yansıtıcıdan bir tarama ışınıyla) **camgöbeği-beyaz**: kurulabilir; **turuncu**: burada düzeltilebilir (eğim, engebe, çok yakın); **kırmızı**: engelli; nedeni nişangâhın altında ("Sadece kendi gezegenine kurulur": Silahlık, Top, Delici Top · "Sadece düşman gezegenine kurulur": Sondaj Kulesi · Uçaksavar, Otomatik Kazıcı ve mekikler iki gezegene de). Zemine izdüşürülen ayak izi: köşe parantezleri, ölçüler (m), çevrede gezegene sabit bir ızgara, yükseklik eş-eğrileri ve tarama halkası; döndürürken açı göstergesi. Yoldaki yapının zemini kırmızı parlar; kurulamayan tıklamada hologram sarsılır. Kurunca hologram yere çöker, yapı ışıltılı bir hacimde katman katman "basılır" (kıvılcım, toz halkası, ses). Toplarda varsayılan atışın yayı ve düşeceği yer de görünür. |
| Topta (F ile geç) | Fare: nişan · teker: barut · sol tık: ateş · F: in. Yörünge ve düşeceği yer önizlenir. |
| Uçaksavarda (F ile geç) | Fare: nişan · sol tık basılı: ateş · F: in. Gelen düşman mermisi için öndelik (sarı halka) gösterilir. |
| Mekikte (F ile bin) | Yerde: Boşluk / W kalk, fare etrafa bakar. Uçarken: fare burnu yönlendirir · W/S itki / fren-geri · A/D dön · Q/E yana kay · Boşluk/Ctrl yukarı/aşağı · Shift takviye · sağ tık etrafa bak · V dış kamera · L ışıklar · R gösterge radarı (400 m › 100 m › ufuk) · F in (yalnız yerde ya da 3 m altında yavaşken). |
| Sol tık · Sağ tık | Kullan · ikincil işlev. Kazı aracında ters mod (kaz ↔ yükselt), silahta nişan. |
| R | Kazı aracında mod değiştir (Kaz › Yükselt › Düzle). Silahta şarjör doldur. |
| Fare tekerleği | Kazı aracında fırça boyutu · İnşa Aracı'nda kart · silah elde: iki silah arasında geç |
| T · B / orta tık | Tüfek: mermi türü (Standart · Delici) · tek / 3'lü atış |
| L | Kask feneri |
| F | Etkileşim |
| Esc | Devam · Ayarlar · Çıkış |
| F11 | Tam ekran / pencere |

- **Malzeme:** sağ üstte görünür (kazınca "+NN", büyük harcamada sayaç geri sayar ve "−NN m³"). Kazmak malzeme kazandırır; yükseltmek ve düzlemek malzeme harcar.
- **Arayüz:** tek bir tasarım dili (`scripts/ui/ui_style.gd`: giysinin beyazı ve turuncusu, bilek ekranının koyu camı; köşesi kesik cam paneller, kenarlı yazı, pencere yüksekliğiyle ölçeklenir). Sol altta **CAN** (20 bölmeli giysi bütünlüğü çubuğu, hasar izi, düşükken kırmızı nabız ve ekran kenarı; jetpack doluyken gizli yakıt çizgisi), sağ altta elindeki alet (şarjör / yedek, atış modu, mermi türü, doldurma), sağ üstte malzeme, altında üretim hapları ve öldürme akışı. Üst ortada **alan**: iki çekirdek çubuğu (sana uzaklıklarıyla), nerede olduğun (YURT / RAKİP / UZAY ve gezegenin adı), maç süresi ve sıradaki çıkarma; altında pusula şeridi (öbür gezegen, çıkarma kapsülü, rakip mekiği, torpidolar, radar temasları) ve uyarılar. Etkileşimde tuş kapağı; yerdeki silahı alırken F basılı halkası tuşun çevresinde dolar.
- **Hızlı çubuk (altta ortada):** [Q tarama] [1 Matkap] [2 İnşa] [3 silah] [4 silah] … [G bomba]; silah ürettikçe uzar. Üç silaha kadar geniş yuvalar; daha fazlasında dar yuvalar (yalnız resim, altında mermi), elindeki silahın adı ve modu yuvasının üstünde yazar. Her yuva bilek ekranı gibi küçük bir cam panel: silahın resmi, kısa adı, şarjör (büyük) / yedek, ince şarjör çubuğu (azalınca turuncu, bitmek üzereyken kırmızı), atış modu (TEK / SERİ / ÜÇLÜ), doldururken "DOLDURUYOR", yedek bitince mermi başına malzeme; İtici'de kapasitör şarjları, Raylı Tüfek'te şarj / soğuma; Matkap'ta mod ve fırça, İnşa'da seçili yapı ve bedeli; Q'da tarayıcının dolumu, G'de bomba sayısı. Elindeki yuva yükselir, üstünde turuncu şerit; boş yuva sönük, "boş". Ağır silahta küçük bir ağırlık simgesi, yerden alınmış ama üretilmemiş silahta "GANİMET".
- **Ağır silahlar yavaşlatır** (elindeyken): Roketatar %86, Keskin Nişancı ve Raylı Tüfek %90, Kinetik İtici %93, Pompalı %97, Tüfek %100, Hafif Makineli %105 hız.
- **Silah düşürme:** ölen bir bot tüfeğini, ölen oyuncu elindeki silahı düşürür (bir kopyası: şarjöründeki mermi + biraz yedek). Kendi ürettiğin silahlar kaybolmaz: yeniden doğunca yine yanındadır, en son elinde tuttuğun silah eline geri gelir. Yerden aldığın ama üretmediğin silah **ganimettir**: ölünce gider. Yerdeki silahlar ~60 s kalır (son saniyelerde yanıp söner), dünyada en çok 10 tane olur; zemine oturur, altı kazılınca düşer, patlama savurur.
- **Mermi:** şarjör + yedek. Yedek bitince doldururken eksik mermiler malzemeyle otomatik alınır; fiyatı sağ alttaki silah panelinde yazar.
- **Silahlık:** 400 m³ (İnşa Aracı'nın ilk kartı), 420 gövde, vurulup yok edilebilir; içinde ışıklı silah rafları, tezgâh ve üretim kolu. Üretim: Tüfek 150, Pompalı 200, Keskin Nişancı 350, Kinetik İtici 300, Roketatar 450, Delici Raylı Tüfek 550, Hafif Makineli 180 m³; 5 el bombası 60 m³ (en çok 15 taşınır, G). Her silah tam şarjör ve biraz yedekle gelir, sonrası eskisi gibi malzemeyle alınır. Bir silahlıkta aynı anda tek üretim; üretim sürerken yok olursa bedel geri gelir. Üretilenler ölünce kaybolmaz; yeni maçta yine yalnız kazı ve inşa araçlarıyla başlarsın. Çok oyunculuda herkes kendisi için üretir.
- **Kinetik İtici:** 2 şarjlı kapasitör (birini doldurmak 4,5 s), atış başına 10 m³. 34°'lik koni, 16 m (sağ tık: dar ve uzun odak). Dibindeki (~4 m) botları uzaya fırlatır, 4–11 m arası büyük yaylarla savurur, daha uzaktakileri sendeletir; oyuncuları yere serip savurur, mekiği iter, mermileri / torpidoları / el bombalarını saptırır. Koninin değdiği yerde zemini **söküp atar** (bir kepçe / hendek): kopan toprak ve yüzeydeki kayalar uçarak saçılır, sekip yere düşer.
- **Hafif Makineli:** 180 m³, 6 s üretim. Uzi benzeri kısa, kutu gövdeli silah: saniyede ~15 mermi, mermi başına 17,5 (12 m'ye kadar tam, 30 m'de %40'a düşer): yakında tüfekten hızlı öldürür, 20 m'den sonra zayıflar. Uzun seride saçılma hızla büyür, geri tepme hafif ama çabuk tırmanır. Şarjör 32 (kabzanın içinden), ~1,6 s doldurma, hızlı nişan, az yavaşlatır. B / orta tık: TEK ↔ SERİ. Her 3. mermi iz bırakır, kovanlar sağdan fırlar. Mermisi 0,06 m³.
- **Delici Raylı Tüfek:** 550 m³, 11 s üretim. Basılı tutunca şarj olur (yükselen vınlama, bobinler ve raylar arası kanal parlar, silah titrer), bırakınca dümdüz, mor-camgöbeği bir ışın atar: **toprağı deler** (tam şarjda 18 m toprak, şarjla orantılı), 120 m boyunca yolundaki her botu, oyuncuyu, yapıyı ve torpidoyu vurur (kendi tarafın hariç). Hasar: tam şarjda ilk hedefe 110 (kafaya ×1,5), sonraki her hedefte %35, her metre toprakta %4 azalır. Tünelde saklanan düşmanı yüzeyden ya da başka bir tünelden vurmanın yolu: dürbünde (2,5×) şarj ederken 30 m içindeki düşmanlar toprağın içinden pembe görünür, köşeli çerçevenin altında "12 m · toprak 4 m" (yeşil: bu şarj oraya ulaşır, turuncu: ulaşmaz); dürbünde sağda nişan hattındaki toprak ve şarjın erişimi. Işın toprağa girdiği ve çıktığı yerde parlayan izler bırakır, çıkışta toz ve taş fışkırır, ~1 s süren bir burgu izi kalır; geçtiği toprakta ince bir delik açar. Tam şarjlı atıştan sonra ~1,5 s soğur. Şarjör 4, mermisi 6 m³. Boşlukta yalnız giysiden gelen boğuk darbe.
- **Keskin Nişancı:** 2400 m/s (tüfeğin ~3 katı), mermi yine yerçekimiyle düşer. Gövdeye ~82, kafaya öldürür. Kalçadan isabetsiz; dürbünde durgun, çömelince daha da durgun, nefes tutunca neredeyse kıpırtısız (~4 s, sonra nefes nefese). Mermisi 0,6 m³. Dürbündeyken lens parlaması görünür: uzun süre nişan aldığın bot fark edip harekete geçer.
- **Silah hissi (tüm silahlar):** her silahın öğrenilebilir bir geri tepme deseni var (seri atışta hafif yukarı tırmanır, yana belli bir yöne kayar); ilk atış daha isabetli; çömelmek isabeti artırıp geri tepmeyi azaltır, kayarken ateş koşarkenden isabetlidir. Kafa vuruşu ayrı bir "ding" ve altın işaret, öldürme büyük işaret + kenarlarda kısa bir parlama ve sağ üstte **öldürme akışı** ("Sen ➜ Rakip — Kazıcı (Keskin, kafadan)"). Hasar sayıları Esc › Ayarlar › **Hasar sayıları** (varsayılan kapalı). Vurulan astronottan kıvılcım, kaçan hava buharı ve giysi parçaları fışkırır; kafa vuruşu vizörü çatlatır; öldürücü atış gövdeyi mermi yönünde savurur. Boşlukta (iki gezegen arası) kendi silahın yalnız giysiden gelen boğuk bir darbe gibi duyulur.
- **Vurulunca:** kırmızı yön okları, ağır darbede kısa bir boğukluk, can %35'in altındayken kalp atışı; yakınından geçen başka oyuncu mermileri vızıldar / çatlar.
- **Can:** 100. Malzeme kalır. Ölünce **10 saniyede** yeniden doğarsın, bir **iniş gemisiyle**:
  - **Taşıyıcılar:** her tarafın ana gemisi kendi üssünün ~110 m üstünde yavaş bir tur atıyor. ~60 m boyunda; jetpack'le ulaşılmaz, çarpışması yok, vurulmaz. Yurt'unki beyaz-turuncu, Rakip'inki koyu gri ve kırmızı ışıklı. Yerden bakınca alt yüzü görünür: açık gri kaplama, pencere sıraları, omurgada kıça doğru akan seyir ışıkları, hangar kapıları, sarı-siyah çerçeveli kenet yuvaları ve mavi motor alevleri. Yanıp sönen işaret lambaları öbür gezegenden de görünür.
  - **0–4 s:** eskisi gibi yere yığılırsın. Ortada "YENİDEN DOĞUŞ · 9" geri sayımı ve "Taşıyıcı iniş gemisi hazırlıyor…" yazar.
  - **4 s:** kısa bir kararmayla görüş, Taşıyıcı'nın altında asılı **İniş Gemisi**'nin kabinine geçer. Arkadaki koltukta oturursun; fare ile etrafa bakılır; ön camdan ve soldaki pencere şeridinden dışarı görünür. Kabinde sıcak tavan lambaları, yerde mavi yol ışıkları, kapının üstünde atlama lambası (uçarken kırmızı, rampa inince yeşil) var. Burundaki konsolda üç ekran (NAV: iniş noktası ve uzaklık · İRTİFA: irtifa ve dikey hız · İNİŞE: kalan süre ve iniş adımları), kapının önündeki duvar ekranında geri sayım ve KAPI KİLİTLİ / AÇIK yazar. Gemi kenetlerden düşer, ana motorlar yanar, burnu aşağıda dalar; yolun ~%60'ından sonra düzlenir, kaldırma jetleriyle frenler. İniş ışıkları yanar, altında toz halkası kalkar. Kabin hafifçe titrer (salınma, ateşleme ve inişte sertçe). İçeride motorlar gövdeden boğuk bir uğultu olarak duyulur.
  - **~9,1 s:** gemi üssün yanına konar (toz, gümleme). Sağdaki rampa-kapı yere iner, kapı üstündeki ışık kırmızıdan yeşile döner. Görüş ayağa kalkıp rampadan dışarı yürür.
  - **10 s:** rampanın dibinde, öbür gezegene bakarak kontrolü alırsın: can dolu, silahların yanında (en son tuttuğun elinde). Cesedin düştüğün yerde kalır. Gemi biraz bekler, kapanır, kalkıp Taşıyıcı'ya döner.
  - **İniş yeri:** doğuş noktan. Orası kazılmış (eski yüzeyin 1,4 m'den fazla altında), engebeli ya da bir yapı, mekik, kapsül veya başka bir gemi tarafından tutulmuşsa, 21 m'ye kadar en yakın düzgün zemine iner. Bir şey ters giderse (iniş yeri bulunamazsa, gemi kaybolursa, maç gemi gelmeden biterse) eskisi gibi 10 s'de doğuş noktanda doğarsın.
  - **Botlar:** rakip botlar (ve dost botlar) da 10 s'de doğar. Kendi Taşıyıcılarından gelen gemiyle üslerinin yanına inerler. Aynı anlarda ölenler (2 s arayla) aynı gemiyle gelir (en çok 6). Botlar gemide görünmez, rampa inince birer birer dışarı çıkar.
  - **Eğitim Alanı'nda** gemi yoktur: eski hızlı doğuş (~4 s). Taşıyıcılar yine gökte durur.
- **Top:** 600 m³, her mermi 40 m³. Mermi ~10–20 saniye uçar (küçük hedef: kolay ıskalanır), düştüğü yerde ~5,5 m yarıçaplı, ~7,5 m derin krater açar (aynı çukura ~4 isabet çekirdeğe ulaşır); çekirdek ~28 m derinde ve 320 can. Tüm patlamalar (top, el bombası, roket, torpido…) aynı ölçekle büyük krater açar (balance.gd CRATER_SCALE). Toplar vurulup yok edilebilir.
- **Mekik:** 4,6 m, yan yana iki koltuk (pilot solda), kabarcık kanopi. Uçuş yardımlı: bıraktığın hızı tutar,
  tuşları bırakınca yavaşça durup havada asılı kalır, gezegen yakınında kendini düzler. Seyir ~22 m/s, takviye
  ~35 m/s: karşıya ~20–30 saniye. Yere yaklaşınca alçalma hızı kendiliğinden kısılır; yavaş ve alçakken
  Ctrl ile (ya da hiç dokunmadan, yere çok yakınken) bacaklarına oturur. Yakıt yok. Gövde 180: vurulur, çarpınca
  hasar alır; yok olursa pilot dışarı fırlar ve yaralanır. Göstergeler kokpitteki ekranda (hız, dikey hız,
  irtifa, YURT / RAKİP uzaklığı, gövde).
- **Silahlı Mekik:** 600 m³, gövde 240, biraz daha yavaş ve ağır döner. Burnun altında çift döner top (sol tık:
  namlular dönünce saniyede 14 mermi; mermi yok, ısınır — kokpit ekranında TOP ISISI, %100'de kilitlenir, %30'a
  soğuyunca açılır) ve 4'lü roket salvosu (sağ tık; roket başına 4 m³, sonra ~4,5 sn dolum). Nişangâhta ön-nişan
  noktası öndeki en yakın düşmana göre kayar. Serbest bakış Alt (ya da orta tık) ile.
- **Uçaksavar:** 300 m³, her mermi 2 m³; düşman gezegenine de kurulur (oradaki kuleni / mekiğini havadan korur). Hızlı, yakınından geçerken havada patlayan (krater açmayan) mermiler atar; yakınında patlarsa gelen top mermisini havada düşürür. Rakip de kurar: mekiğini havada görürse 1–2 saniye sonra ateş açar (üstte kırmızı "RAKİP SENİ GÖRDÜ"). Düz uçarsan isabet alır, manevra yaparsan ıskalar.
- **Sondaj Kulesi:** 750 m³ (eski torpido atarın 500'ü + bir torpido 250), 300 gövde, **yalnız düşman gezegenine** kurulur. Üç ayaklı çelik bir kule: tepede makara ve fener, arkada vinç motoru (fan, egzoz, tambur), iki çalışma lambası ve ön ayakta küçük bir durum ekranı. Kurulunca ~6 saniye hazırlanır: vinç torpidoyu burnu aşağıda indirir, matkap döner, değdiği yerde kıvılcım, toz ve yakında yer sarsıntısı. Sonra torpido oradan dosdoğru çekirdeğe kazar (atılan torpido gibi: 60 can, rakip kazıp vurarak durdurabilir, çekirdeğe ulaşınca 110 hasar). Kule bir torpido içindir, sonra yapı olarak durur (ekranda torpidonun derinliği ve sonucu); hazırlanırken yıkılırsa torpido inmez. Rakip muhafızlar düşman gezegenindeki yapılarına yürüyüp ateş eder; hâlâ hazırlanan bir kuleye 6 bota kadar (kazıcılar da) gider, diğer yapılara 3.
- **Otomatik Kazıcı:** 350 m³, 220 gövde, **iki gezegene de** kurulur. Dört ayaklı bir sondaj platformu: kuyunun üstünde direk ve tahrik kafası, iç içe geçen teleskopik tij ucunda dönen kesici kafa, kuyudan hazneye toprak taşıyan bant, dolup boşalan hazne, toz bulutu, lambalar ve önde "ÜRETİM x m³/dk · DERİNLİK y m" ekranı. Kurulunca kendi kuyusunu gerçekten kazar (~2,5 m geniş, 12 m'ye kadar, ~2,5 dakikada) ve onu kuranı besler: üstte 3 m³/s, derinleştikçe azalır, dibe varınca "KURUDU" (0,5 m³/s). Haznesi her 10 m³'te boşalır ("+10 m³"); ~2,6 dakikada bedelini çıkarır. Düşman gezegeninde %25 daha verimli ama korunması zor. Yok edilince patlar, kuyu kalır.
- **Çekirdek:** üstte iki çubuk (YURT ÇEKİRDEĞİ · RAKİP ÇEKİRDEĞİ). Yakına düşen patlamalar ve kazı aracıyla doğrudan kazmak hasar verir.

### Kolay inşa (kılavuz, geri al, sök, işaret)

- **İlk kez** İnşa Aracı'nı aldığında solda küçük bir kılavuz çıkar: Q / E kategori · Teker yapı seç · T tür · R döndür · Sol tık kur · Sağ tık + fare serbest döndür. Her adımı bir kez yapınca yanına yeşil tik gelir; hepsi bitince kendiliğinden kapanır. **H**: kılavuzu yeniden aç / kapa (Eğitim Alanı'nda H eğitim panelidir).
- **Z: geri al** — kurduktan sonraki 10 sn içinde son yapıyı **tam iade** ile geri alırsın (alt ortada "Z Geri al: Taret · 7 sn").
- **X basılı tut: sök** — İnşa Aracı elindeyken kendi yapına nişan al: "Sök: Taret — %50 iade (+150 m³)"; X'i ~1 sn basılı tutunca yapı yere çökerek sökülür ve bedelinin yarısı geri gelir. Kullanımdaki (içinde biri olan, üretim yapan) yapı sökülmez.
- **Orta tık / B: işaret** — nişan aldığın yere "BURAYA KUR: <yapı>" işareti bırakır (ışık sütunu, yer halkası, kim bıraktı, uzaklık); 20 sn kalır, çok oyunculuda arkadaşın da görür. (Orta tık artık döndürmez; döndürme R.)
- Kurulamadığında neden ve **nasıl düzeltileceği** yazar: "Çok eğimli — daha düz bir yer seç", "Tavan alçak: biraz daha kaz", "Malzeme: 120 m³ eksik — kazmaya devam", "Başka bir yapıya çok yakın — biraz öteye nişan al".

### Üs kurma (yeraltı, sığınak, taret)

- **Yeraltına kurmak:** kazdığın tünele, çukura ya da mağaraya (üstünde toprak olan her yer) de kurabilirsin. Hologram boşluğun **tabanına** oturur (duvara ya da tavana nişan alsan da). Yapının boyu sığmalı: sığmıyorsa "**Tavan çok alçak — biraz daha kaz**", ayak izi duvara giriyorsa "**Yer dar — biraz daha kaz**", taban çok engebeliyse "Zemin düz değil". Yeraltında hologramın etrafında gereken boşluk kutu olarak görünür. Yeraltına kurulabilenler: Sığınak Modülü, Takviyeli Duvar, Zırhlı Kapı, Otomatik Taret, Çekirdek Kalkanı, Radar Kulesi, Işık Direği, Silahlık, Otomatik Kazıcı. Top, Uçaksavar, Delici Top, mekikler ve Sondaj Kulesi açık gökyüzü ister ("Yeraltına kurulamaz — açık gökyüzü gerekir").
- **Toprak korur:** patlamalar bir yapıya ancak arada toprak yoksa tam vurur. Patlamayla yapı arasındaki toprak hasarı keser (2 m toprak tamamen durdurur); patlamanın açacağı çukurun kendisi sayılmaz. Yani derindeki bir sığınağa top mermisi ancak kraterler ona ulaşınca işler; Delici Top tam bunun için. Botlar ve oyuncular bundan etkilenmez (çukurdaki düşmana el bombası yine işler).
- **Sığınak Modülü** (Üs, 220 m³, 900 gövde): 4 × 4 × 2,8 m betonarme oda (içi 3,4 m), çelik köşe kolonları, ön ve arkada 1,6 × 2,2 m kapı boşluğu, içeride sıcak bir tavan lambası, kablo kanalı, havalandırma ve dolap. Patlama hasarı × 0,35. İçine yürüyerek girilir. Yeni modülü eskisinin kapısına yaklaştırınca **kapıdan kapıya yapışır** (koridor). Yüzeyde yan duvarlarına kum torbaları yığılır; kurulunca içinde kalan toprağı temizler.
- **Takviyeli Duvar** (Savunma, 40 m³, 380 gövde): 3 m eninde, 2,5 m boyunda beton çekirdekli, çelik kaplamalı siper; göğüs hizasında dar bir mazgal. Başka duvarın ucuna düz ya da köşe yaparak, sığınağın kapısını kapatacak ya da yüzünü yana uzatacak şekilde yapışır. Patlama × 0,5.
- **Zırhlı Kapı** (Savunma, 90 m³, 480 gövde): sığınak kapısına (yapışır) ya da ~2 m'lik bir tünele. **Bizimkilere** (sen, arkadaşın, dost botlar) 3 m'de kendiliğinden açılır, düşmana açılmaz: kırmak zorundalar. Üstünde yeşil (açık), turuncu (hareket), kırmızı (kapalı) lambalar. Patlama × 0,5.
- **Otomatik Taret** (Savunma, 300 m³, 260 gövde): 35 m içinde **gördüğü** düşmanı (botlar, çıkarma kapsülleri ve ekipleri, Karşı Karşıya'da öbür oyuncu) kendisi bulur, döner ve çift makineliyle 6'lık seriler atar (mermi başına 7 hasar, iz mermili). Dostlara (sen, arkadaşın, dost botlar) asla ateş etmez; ateş hattında dost varsa bekler. Her seri sahibinin malzemesinden 0,6 m³ yer; malzeme yoksa çok yavaş ateş eder. Sığınağın içine de kurulur.
- **Çekirdek Kalkanı** (Üs, 600 m³, 520 gövde, takım başına bir tane): yalnız **kendi çekirdeğinin 8 m yakınına** kurulur (çekirdeğe kadar kaz). Ayakta olduğu sürece çekirdeğin aldığı hasar **%40'a** iner; çekirdeğin çevresinde altıgen desenli bir enerji kabuğu parlar, çekirdek vurulunca titrer. Düşman önce kalkanı kırmalı.
- **Radar Kulesi** (Üs, 260 m³, 220 gövde): 60 m içindeki düşmanları — **yeraltında kazanları bile** — tespit eder; yeni bir yeraltı teması olunca "**Yeraltında düşman kazısı tespit edildi**". Ekranında temas sayısı.
- **Işık Direği** (Üs, 15 m³): tünelleri ve sığınakları sıcak beyaz, yumuşak bir ışıkla aydınlatır (göz almaz).

## Kod düzeni

| Klasör | İçerik |
|---|---|
| `scripts/game.gd` | Autoload `Game`: girdi haritası, `Game.material`, mermi yedeği (`take_ammo`), toplam yerçekimi (`gravity_at`, `dominant_body`), hasar yardımcıları (grup `"damageable"`: `damage_target`, `area_damage`) |
| `scripts/main.gd` | Dünyayı kurar: yıldızlı gök, sabit güneş, iki gezegen, oyuncu, ses, HUD, duraklatma menüsü |
| `scripts/planet/` | Voxel gezegen: Surface Nets, LOD octree, GPU/CPU yoğunluk. Ön ayarlar `bodies.gd` içinde (`home`, `rival`); her maçın rastgele gezegenleri `random_world.gd` (renk aileleri, kabartma aralıkları, adlar; tek tohum, her makinede aynı sonuç); gezegen boyu ve aradaki mesafe tek yerde: `PLANET_RADIUS`, `PLANET_DISTANCE`. API: `apply_brush`, `crater`, `density_at`, `raycast_density`, `brush_applied` sinyali |
| `scripts/player/` | Oyuncu, kazı aracı, ortak kazma çekirdeği `dig.gd`, kollar (viewmodel), astronot gövdesi ve ragdoll, `stance.gd` (çömelme, kayma, kayarken kendi bacaklarını görme) |
| `scripts/items/` | Tüfek, pompalı, `sniper.gd` + `sniper_scope.gd` (keskin nişancı ve dürbün katmanı), `railgun.gd` + `rail_beam.gd` + `rail_scope.gd` (Delici Raylı Tüfek: şarj, toprağı delen ışın, görüntü / ses, toprak ölçümü, dürbün ve röntgen), `smg.gd` (Hafif Makineli), `gun_feel.gd` (tüm silahların ortak hissi: geri tepme deseni, silah ataleti, kafa bölgesi, isabet tepkisi, öldürme akışı), mermi efektleri, isabet hissi, `explosion.gd`, `ballistics.gd` (yörünge tahmini, iki gezegenin toplam yerçekimi) |
| `scripts/war/` | Savaş: `balance.gd` (tüm denge sabitleri), `core.gd` çekirdek, `cannon.gd` top, `shell.gd` top mermisi, `flak.gd` + `flak_round.gd` uçaksavar, `build_tool.gd` inşa aracı (nereye kurulacağı: `balance.gd` `BUILD_SITE`; zeminin ayak izi boyunca ne kadar değişebileceği: `STEP_TOL`), `foundation.gd` yapıların temeli (eğimde ve kazılmış zeminde gerçek zemine inen beton etek ve çelik kazıklar), `base_kit.gd` üs kurma kuralları (yeraltına kurma, boşluk / tavan ölçümü, patlamaya karşı toprak koruması, modüllerin birbirine yapışması, yapay zekâ için `suggest_spot` / `spawn` / `carve_for`) + `base_piece.gd` (üs parçalarının ortak sözleşmesi) ve parçalar: `bunker_module.gd` Sığınak Modülü, `armor_wall.gd` Takviyeli Duvar, `blast_door.gd` Zırhlı Kapı, `sentry_turret.gd` Otomatik Taret, `core_shield.gd` Çekirdek Kalkanı, `radar_tower.gd` Radar Kulesi (`contacts_for(team)`), `light_post.gd` Işık Direği, `torpedo_rig.gd` Sondaj Kulesi + `torpedo.gd` sondaj torpidosu, `auto_miner.gd` Otomatik Kazıcı, `armory.gd` silahlık + `craft.gd` (tarifler, bedeller) + `craft_menu.gd` (üretim paneli; ÜRETİM · CEPHANELİK sekmeleri) + `loadout_panel.gd` (Cephanelik: yanındaki silahlar, salt okunur; `Game.carried_guns()`), `weapon_drop.gd` yerdeki silahlar (ölünce düşen, F basılı al; çok oyunculu olayları), `rival_team.gd` rakip takım (ortak malzeme, roller; "Skiff raids" mekik baskınlarının zamanlaması / mürettebatı / mekik türü; "Digging tactics and the rival's base" lağımcı, karşı tünel, hendek, pusu, sığınak, kazı payı, üs parçaları) + `ai_rival.gd` tek bot (görev ve çatışma yapay zekâsı; "Ally bots" bölümü aynı botu `team = "home"` ile dost yapar; "Digging tactics" botun kazı görevleri, siper / kaçış çukuru, kapı ve duvar engeli; "Reactions and body language" görme anı, işaretleme, el işaretleri, korkma, boşta yaşam, dostların tepkileri, duyma / susturucu) + `bot_cues.gd` (botun başının üstündeki "!" ve konuşma satırları, satır listesi; vücut pozları `scripts/player/astronaut.gd` "Body language"), `ally_team.gd` tek oyunculu dost botlar (Muhafız, Kazıcı; F komutu, malzeme payı), `war.gd` + `war_hud.gd` maç, zafer / yenilgi, `respawn_ship.gd` iniş gemisiyle yeniden doğuş (Taşıyıcılar, gemi gönderme, iniş yeri, oyuncunun yolculuğu, botları gemiye bindirme; çok oyunculu olayları `events()`) + `dropship.gd` İniş Gemisi (uçuş, iniş, rampa, kabin görüşü, ses) + `carrier.gd` Taşıyıcı (gökteki yavaş tur) + `respawn_ship_build.gd` ikisinin prosedürel modelleri |
| `scripts/craft/` | Mekik: `skiff.gd` (uçuş, iniş, koltuk, hasar; inşa aracı sözleşmesi `BUILD_COST`, `footprint()`, `place()`; takım boyası; sonda **yapay zekâ pilotu**: `ai_board`, `ai_exit`, `ai_fly_to`, `ai_hold`, `ai_arrived`, `ai_under_fire`: oyuncunun girdileriyle uçar, iniş yeri arar, kaçamak yapar), `skiff_build.gd` (prosedürel model), `skiff_shaders.gd`, `skiff_dash.gd` (kokpit ekranı), `skiff_overlay.gd` (nişan halkası), `skiff_audio.gd`, `skiff_wreck.gd` (enkaz), `armed_skiff.gd` (Silahlı Mekik: döner top, roketler, nişangâh; sonda yapay zekâ nişancısı: saldırı geçişleri). Baskın zamanlaması ve mürettebat: `rival_team.gd` "Skiff raids", sabitler `balance.gd` "AI pilot and skiff raids" |
| `scripts/ui/` · `scripts/save/` · `scripts/audio/` | HUD (`hud.gd`; `quickbar.gd` alttaki hızlı çubuk: Matkap, İnşa, yanındaki silahlar, tarayıcı, bomba; `overlay_guard.gd`: maç bitince, menü ya da panel açıkken nişangâhları, isabet işaretlerini ve dürbünü gizler, `Game.match_over`), ana menü (`main_menu.gd`, `scenes/menu.tscn`), menüler ve ayarlar, ses |
| `scripts/net/` | Çok oyunculu: autoload `Net` (`net.gd`: oturum, el sıkışma, taraflar), `net_relay.gd` (WebRTC sinyal istemcisi), `net_rooms.gd` (açık odalar), `mp_config.gd` (sunucu, anahtar, oda kodu), `net_terrain.gd` (arazi işlemleri, sağlama toplamı, anlık görüntü), `net_players.gd` + `remote_avatar.gd` (oyuncular), `net_world.gd` (yapılar, mermiler, çekirdekler, mekikler, isabet bildirimleri), `net_bots.gd` + `net_bot.gd` (botlar), `net_passenger.gd` (mekik yolcu koltuğu), `net_overlay.gd` (sohbet, ping), `snap_buffer.gd` (ara değerleme) |
| `tests/` | Yalnızca gezegen ölçüm araçları. Kullanıcı istemedikçe çalıştırılmaz. |

## Yedek

Pivot öncesi projenin tam yedeği (eski oyun: ana gemi, mekik, EVA, hikâye, canlılar…):
`C:\Users\erdem\AppData\Local\UzaySiniri\backups\space_2026-10-04_before_pivot`
