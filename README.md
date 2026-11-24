<p align="center"><img src="app/assets/logo_tile.png" width="140" alt="Glyphix"></p>

<h1 align="center">Glyphix</h1>
<p align="center">Паки иконок для панели задач, ярлыков и плиток Start11 в Windows — в один клик.<br>
<i>One-click icon packs for the Windows taskbar, shortcuts and Start11 tiles.</i></p>

<p align="center"><img src="packs/shadow/preview.png" alt="Shadow"></p>

## Что это

Как паки иконок на Android, только для Windows 10/11. Выбираешь пак — Glyphix сам находит твои приложения
(закреплённые на панели задач, ярлыки на рабочем столе и в «Пуске», плитки **Start11**) и ставит им иконки из пака.

- **Один клик:** «Применить» — и всё. «Откатить всё» возвращает исходные иконки и плитки.
- **11 стилей, 49 вариантов цвета, 261 иконка:** Shadow, Glow, Mono, Neon, Pixel, Metal, Glass, System, Holo, Sticker и Brand (каждая иконка в цвете своего бренда) — мессенджеры, браузеры, игры и лаунчеры
  (Steam, Roblox, Minecraft, Epic, Riot, Battle.net, CS2, Dota 2…), VPN-клиенты (Clash Verge, Hiddify, Happ, v2RayTun, NekoBox, Throne…), музыка, системные приложения, работа и творчество.
  Цвета перекрашиваются прямо на твоём ПК — качается только основа стиля.
- **Выбор по приложениям:** для каждого приложения — «Ставить / Не трогать / Вернуть родную» отдельно для иконки и плитки, иконка из другого стиля, откат выбранных.
- **Избранное:** отмечай понравившиеся стили звёздочкой.
- **Плитки Start11:** если установлен Start11, плитки ставятся автоматически (с подписью или без).
- **Автоиконки:** приложениям, для которых в паке нет иконки, Glyphix сам перекрашивает их родную иконку в стиль пака (локально, без сети; нужен `auto.json` в паке). Общий выключатель — галочка внизу окна.
- **Обновления без архивов:** «Обновить паки» докачивает новое из этого репозитория.
- **Ничего в фоне:** нет автозапуска, служб и задач планировщика.
- **Безопасно:** при обновлении скачиваются только картинки (`.png`/`.ico`) и описания паков (`.json`),
  каждый файл сверяется по SHA-256. Код открыт.

## Установка

**[Скачать GlyphixSetup.exe](https://github.com/F1KS-FK/glyphix/raw/main/GlyphixSetup.exe)** → запусти → «Установить». Права администратора не нужны: всё ставится в папку пользователя
(`%LOCALAPPDATA%\Glyphix`), ярлык **Glyphix** появится на рабочем столе и в «Пуске». Тот же файл обновляет и переустанавливает Glyphix.

> **Windows SmartScreen** может показать окно «Windows защитил ваш компьютер»: файл пока не подписан цифровой подписью (она платная).
> Нажми **«Подробнее» → «Выполнить в любом случае»**. Установщик не запускает PowerShell, скачивает только файлы из этого репозитория и проверяет каждый по SHA-256 (список — [`app/files.json`](app/files.json)).

**Альтернатива — через PowerShell.** Открой **PowerShell** (Win+X → «Терминал» / «Windows PowerShell») и вставь:

```powershell
irm https://raw.githubusercontent.com/F1KS-FK/glyphix/main/install.ps1 | iex
```

**Удаление:** «Параметры → Приложения → Glyphix → Удалить» (или в приложении «⋯» → «Удалить приложение»). Перед удалением иконки и плитки возвращаются к исходным.

## Стили

**Shadow** — Чёрные глифы с цветной аурой

<img src="variants/shadow-violet.jpg" width="200" title="Shadow Violet"> <img src="variants/shadow-blue.jpg" width="200" title="Shadow Blue"> <img src="variants/shadow-red.jpg" width="200" title="Shadow Red"> <img src="variants/shadow-green.jpg" width="200" title="Shadow Green"> <img src="variants/shadow-cyan.jpg" width="200" title="Shadow Cyan"> <img src="variants/shadow-gold.jpg" width="200" title="Shadow Gold">

**Glow** — Светящиеся цветные глифы

<img src="variants/glow-azure.jpg" width="200" title="Glow Azure"> <img src="variants/glow-violet.jpg" width="200" title="Glow Violet"> <img src="variants/glow-pink.jpg" width="200" title="Glow Pink"> <img src="variants/glow-green.jpg" width="200" title="Glow Green"> <img src="variants/glow-orange.jpg" width="200" title="Glow Orange"> <img src="variants/glow-white.jpg" width="200" title="Glow White">

**Mono** — Строгие однотонные иконки

<img src="variants/mono-white.jpg" width="200" title="Mono White"> <img src="variants/mono-black.jpg" width="200" title="Mono Black"> <img src="variants/mono-graphite.jpg" width="200" title="Mono Graphite"> <img src="variants/mono-cream.jpg" width="200" title="Mono Cream"> <img src="variants/mono-ice.jpg" width="200" title="Mono Ice"> <img src="variants/mono-crimson.jpg" width="200" title="Mono Crimson">

**Neon** — Неоновые рамки и свечение

<img src="variants/neon-synthwave.jpg" width="200" title="Neon Synthwave"> <img src="variants/neon-toxic.jpg" width="200" title="Neon Toxic green"> <img src="variants/neon-red.jpg" width="200" title="Neon Red"> <img src="variants/neon-sunset.jpg" width="200" title="Neon Sunset orange"> <img src="variants/neon-ultraviolet.jpg" width="200" title="Neon Ultraviolet">

**Pixel** — Пиксель-арт, как в старых играх

<img src="variants/pixel-blue.jpg" width="200" title="Pixel Blue"> <img src="variants/pixel-gameboy.jpg" width="200" title="Pixel Game Boy green"> <img src="variants/pixel-red.jpg" width="200" title="Pixel Red"> <img src="variants/pixel-purple.jpg" width="200" title="Pixel Purple"> <img src="variants/pixel-amber.jpg" width="200" title="Pixel Amber">

**Metal** — Золото, серебро и хром

<img src="variants/metal-gold.jpg" width="200" title="Metal Gold"> <img src="variants/metal-silver.jpg" width="200" title="Metal Silver"> <img src="variants/metal-rose.jpg" width="200" title="Metal Rose gold"> <img src="variants/metal-bronze.jpg" width="200" title="Metal Bronze"> <img src="variants/metal-chrome.jpg" width="200" title="Metal Dark chrome">

**Glass** — Прозрачное и матовое стекло

<img src="variants/glass-glass.jpg" width="200" title="Glass Glass"> <img src="variants/glass-clear.jpg" width="200" title="Glass Clear"> <img src="variants/glass-frosted.jpg" width="200" title="Glass Frosted"> <img src="variants/glass-blue.jpg" width="200" title="Glass Blue tint"> <img src="variants/glass-smoke.jpg" width="200" title="Glass Smoke"> <img src="variants/glass-pink.jpg" width="200" title="Glass Pink">

**System** — Интерфейс охотника, как в Solo Leveling

<img src="variants/system-blue.jpg" width="200" title="System Blue"> <img src="variants/system-monarch.jpg" width="200" title="System Monarch violet"> <img src="variants/system-gate.jpg" width="200" title="System Red gate"> <img src="variants/system-gold.jpg" width="200" title="System Gold">

**Holo** — Голографический перелив

<img src="variants/holo-holo.jpg" width="200" title="Holo Holo">

**Sticker** — Яркие стикеры с обводкой

<img src="variants/sticker-sticker.jpg" width="200" title="Sticker Sticker"> <img src="variants/sticker-pastel.jpg" width="200" title="Sticker Pastel">

**Brand** — Каждая иконка в цвете своего бренда

<img src="variants/brand-glow.jpg" width="200" title="Brand Glow Brand"> <img src="variants/brand-neon.jpg" width="200" title="Brand Neon Brand"> <img src="variants/brand-sticker.jpg" width="200" title="Brand Sticker Brand">

Нет иконки для твоего приложения? Открой issue с названием приложения.

## Ограничения

- Приложения из Microsoft Store (UWP) на панели задач этим способом не меняются (в Start11 — меняются).
- Общие для всех пользователей ярлыки меняются с галочкой «Также общие ярлыки» (попросит права администратора).
- Discord, Chrome и др. при обновлении могут пересоздать свои ярлыки — просто нажми «Применить» ещё раз.

## Автор

by **F1KS** · Telegram [@Im_Flawless](https://t.me/Im_Flawless) · Discord `f1ks_`

## Лицензия

- Код: **GPL-3.0** © 2026 F1KS — можно использовать и менять, но производные проекты остаются открытыми и указывают автора.
- Иконки: **CC BY-NC-SA 4.0** © 2026 F1KS — бесплатно, с указанием автора, без продажи. См. [packs/LICENSE.md](packs/LICENSE.md).
- Логотипы сторонних приложений — товарные знаки их владельцев; часть иконок основана на [Simple Icons](https://simpleicons.org) (CC0).
  Иконки — фан-перерисовка для личной кастомизации, проект не связан с правообладателями.

---

### English

**Glyphix** applies icon packs (11 styles: Shadow, Azure, White, Black, Neon, Pixel, Gold, Holo, Glass, System, Sticker — 249 icons each) to Windows 10/11 taskbar pins, shortcuts and
Start11 tiles in one click, with undo and in-app updates. No background processes. Install: [download GlyphixSetup.exe](https://github.com/F1KS-FK/glyphix/raw/main/GlyphixSetup.exe) and run it
(no admin rights; Windows SmartScreen may warn because the file is not code-signed: click "More info" -> "Run anyway"), or use PowerShell:
`irm https://raw.githubusercontent.com/F1KS-FK/glyphix/main/install.ps1 | iex`.
Code: GPL-3.0, icons: CC BY-NC-SA 4.0, © 2026 F1KS.
