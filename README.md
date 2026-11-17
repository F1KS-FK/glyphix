<p align="center"><img src="app/assets/logo_tile.png" width="140" alt="Shadow Icons"></p>

<h1 align="center">Shadow Icons</h1>
<p align="center">Паки иконок для панели задач, рабочего стола и меню «Пуск» Windows — в один клик.<br>
<i>One-click icon packs for the Windows taskbar, desktop and Start menu.</i></p>

<p align="center"><img src="packs/shadow/preview.png" alt="Shadow pack preview"></p>

## Что это

Как паки иконок на Android, только для Windows 10/11. Выбираешь пак — приложение само находит твои ярлыки
(закреплённые на панели задач, на рабочем столе, в «Пуске») и ставит им иконки из пака.

- **Один клик:** «Применить» — и всё. «Откатить всё» возвращает исходные иконки.
- **Обновления без архивов:** «Обновить паки» скачивает новые иконки из этого репозитория.
- **Ничего в фоне:** нет автозапуска, служб и задач планировщика. Работает только когда ты его открыл.
- **Безопасно:** при обновлении скачиваются только картинки (`.png`/`.ico`) и описания паков (`.json`),
  каждый файл сверяется по SHA-256. Код открыт — можно проверить.

## Установка

Открой **PowerShell** (Win+X → «Терминал» или «Windows PowerShell») и вставь:

```powershell
irm https://raw.githubusercontent.com/F1KS-FK/shadow-icons/main/install.ps1 | iex
```

Появится ярлык **Shadow Icons** на рабочем столе и в «Пуске». Удалить: в приложении «⋯» → «Удалить приложение»
(перед этим иконки вернутся к исходным).

## Паки

| Пак | Описание |
|---|---|
| **Shadow** | Чёрные иконки с сине-фиолетовой аурой: Telegram, Discord, Chrome, Firefox, Gemini, Яндекс Музыка, PulseSync, EdrawMind, AniLibrix/AniLibria, spacedesk, Pionex, Калькулятор, Диспетчер задач, Проводник |

**Start11:** если установлен Start11, приложение само ставит плитки 512×512 из пака (галочка «Плитки Start11», есть вариант без подписи). Старые картинки плиток сохраняются и возвращаются кнопкой «Откатить всё».

## Ограничения

- Приложения из Microsoft Store (UWP) этим способом не меняются.
- Общие для всех пользователей ярлыки меняются только с галочкой «Также общие ярлыки» (попросит права администратора).
- Некоторые приложения (Discord, Chrome) при обновлении пересоздают свои ярлыки — просто нажми «Применить» ещё раз.

## Лицензия

- Код: **GPL-3.0** © 2026 F1KS — можно использовать и менять, но производные проекты должны оставаться открытыми
  и указывать автора.
- Иконки: **CC BY-NC-SA 4.0** © 2026 F1KS — бесплатно, с указанием автора, без продажи. См. [packs/LICENSE.md](packs/LICENSE.md).
- Логотипы сторонних приложений — товарные знаки их владельцев; иконки — фан-перерисовка для личной кастомизации.

---

### English

**Shadow Icons** applies icon packs to your Windows 10/11 shortcuts (taskbar pins, desktop, Start menu) in one click,
with undo and in-app pack updates from this repo. No background processes. Install:
`irm https://raw.githubusercontent.com/F1KS-FK/shadow-icons/main/install.ps1 | iex`.
Code: GPL-3.0, icons: CC BY-NC-SA 4.0, © 2026 F1KS.
