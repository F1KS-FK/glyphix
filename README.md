<p align="center"><img src="app/assets/logo_tile.png" width="140" alt="Glyphix"></p>

<h1 align="center">Glyphix</h1>
<p align="center">Паки иконок для панели задач, ярлыков и плиток Start11 в Windows — в один клик.<br>
<i>One-click icon packs for the Windows taskbar, shortcuts and Start11 tiles.</i></p>

<p align="center"><img src="packs/shadow/preview.png" alt="Shadow"></p>

## Что это

Как паки иконок на Android, только для Windows 10/11. Выбираешь пак — Glyphix сам находит твои приложения
(закреплённые на панели задач, ярлыки на рабочем столе и в «Пуске», плитки **Start11**) и ставит им иконки из пака.

- **Один клик:** «Применить» — и всё. «Откатить всё» возвращает исходные иконки и плитки.
- **11 стилей по 249 иконок:** Shadow, Azure, White, Black, Neon, Pixel, Gold, Holo, Glass, System, Sticker — мессенджеры, браузеры, игры и лаунчеры
  (Steam, Roblox, Minecraft, Epic, Riot, Battle.net, CS2, Dota 2…), музыка, системные приложения, работа и творчество.
- **Плитки Start11:** если установлен Start11, плитки ставятся автоматически (с подписью или без).
- **Автоиконки:** приложениям, для которых в паке нет иконки, Glyphix сам перекрашивает их родную иконку в стиль пака (локально, без сети; нужен `auto.json` в паке). Для каждого приложения можно выбрать «Авто / Родная / Не трогать»; общий выключатель — галочка внизу окна.
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

## Паки

| | |
|---|---|
| **Shadow** | **Azure** |
| <img src="packs/shadow/preview.png" width="420"> | <img src="packs/azure/preview.png" width="420"> |
| **White** | **Black** |
| <img src="packs/white/preview.png" width="420"> | <img src="packs/black/preview.png" width="420"> |
| **Neon** | **Pixel** |
| <img src="packs/neon/preview.png" width="420"> | <img src="packs/pixel/preview.png" width="420"> |
| **Gold** | **Holo** |
| <img src="packs/gold/preview.png" width="420"> | <img src="packs/holo/preview.png" width="420"> |
| **Glass** | **System** |
| <img src="packs/glass/preview.png" width="420"> | <img src="packs/system/preview.png" width="420"> |
| **Sticker** | |
| <img src="packs/sticker/preview.png" width="420"> | |

Нет иконки для твоего приложения? Открой issue с названием приложения.

## Ограничения

- Приложения из Microsoft Store (UWP) на панели задач этим способом не меняются (в Start11 — меняются).
- Общие для всех пользователей ярлыки меняются с галочкой «Также общие ярлыки» (попросит права администратора).
- Discord, Chrome и др. при обновлении могут пересоздать свои ярлыки — просто нажми «Применить» ещё раз.

## Автор

by **F1KS** · Telegram [@Im_Flawless](https://t.me/Im_Flawless)

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
