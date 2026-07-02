# Somnia

Личный браузер на **WebKit + Swift (SwiftUI)**, объединённый с **Obsidian**. Помимо обычного веб-сёрфинга: заметки (markdown + граф связей), рабочие пространства (группы вкладок), закладки, кастомизация и оптимизация при большом числе вкладок.

Дизайн-эталон: `../Minimalist Browser Design/Somnia.dc.html` (рабочий React-прототип — палитры Aurora/Slate, токены).

---

## Быстрый старт

```bash
cd SomniaApp
./build.sh            # собирает Somnia.app (swiftc напрямую)
open Somnia.app
./test.sh            # юнит-тесты чистой логики (resolve/wikiLinks/markdown/…)
```

Пересборка во время разработки:
```bash
pkill -f "Somnia.app/Contents/MacOS/Somnia"; ./build.sh && open Somnia.app
```

### ⚠️ Важно про тулчейн
- В системе **только Command Line Tools**, полного Xcode нет.
- **SwiftPM (`swift build`) НЕ работает** — манифест не линкуется (ManifestAPI в CLT). `Package.swift` оставлен для справки, но сборка идёт через **`build.sh`** (вызывает `xcrun swiftc` напрямую → `.app`-бандл).
- Был баг CLT: дубль modulemap (`module.modulemap` + `bridging.modulemap`, оба объявляли `SwiftBridging`) — падал даже `import SwiftUI`. **Фикс уже применён** (старый переименован в `.bak`). Если ошибка «redefinition of module 'SwiftBridging'» вернётся после обновления CLT:
  ```bash
  sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.bak}
  ```
  (только в реальном терминале — `sudo` нужен пароль).

---

## Архитектура

**Гибрид:** нативный SwiftUI-каркас (окно, сайдбар, тулбар, редактор заметок) + WKWebView для веб-страниц и графа заметок. Веб-tech-шов локализован в графе (см. `GraphWebView`).

**Почему так:** «блюр основного фона при открытии Notes» из макета в вебе невозможен (CSS `backdrop-filter` не видит содержимое нативного WKWebView под собой). Решается нативно — `NSVisualEffectView` с `blendingMode = .withinWindow` поверх WKWebView.

### Структура исходников (`Sources/Somnia/`)

| Файл | Ответственность |
|------|-----------------|
| `App.swift` | `@main`, `WindowGroup` (`.hiddenTitleBar`), внедрение `BrowserState` / `Theme` / `NotesStore` как `environmentObject`. **Меню macOS** (`.commands`): File/View/History/Tabs со стандартными шорткатами. |
| `Theme.swift` | Дизайн-токены: палитры Aurora/Slate × light/dark, accent, density. **Опц. оверрайды цветов** `bgHex/surfaceHex/textHex` поверх пресетов (деривация вторичных токенов), `binding(for:)`, `Color.hexString`, `Theme.current`. `Color(hex:)`/`Color(rgba:)`. `PanelBackground`, `AuroraGlow`. Грузит/пишет `settings.json`. |
| `Models.swift` | `Tab`, `Space`, **`BrowserState`** — ядро браузера: вкладки, спейсы, закладки, навигация, политика оптимизации вкладок, персист сессии. |
| `Web.swift` | `WebViewPool` (1 WKWebView на вкладку, lazy + sleep/remove с `interactionState`), `WebHostView`, `WebArea` (NSViewRepresentable), `VisualEffect` (нативный блюр), `TabNavDelegate`. |
| `Notes.swift` | `Note`, **`NotesStore`** (vault, CRUD, парсинг `[[wiki-links]]`, бэклинки, дедуп заголовков, graphJSON), `GraphWebView` + встроенный `graph.html`. |
| `Markdown.swift` | `MarkdownView` — нативный блок-рендер md + кликабельные `[[ссылки]]` через схему `somnia://note/<title>`. |
| `Reader.swift` | `ReaderMode` — компактный readability-экстрактор (встроенный JS) + сборка тематического HTML; режим чтения веб-статей. |
| `Palette.swift` | `CommandPalette` (⌘K) — поиск по вебу / вкладкам / закладкам / заметкам. |
| `Store.swift` | JSON-хранилище (`session.json`, `settings.json`), Codable-DTO (`PersistedSession`, `Bookmark`, …), `vaultDir` (Application Support) + `migrateLegacyVault`. |
| `Features.swift` | `SearchEngine` (Google/DDG/Bing/Brave), `HistoryStore` (журнал посещений), `FaviconStore` (кэш фавиконов), `DownloadsModel`/`DownloadItem` (прогресс загрузок), `ContentBlocker` (`WKContentRuleList` — трекеры/реклама). |
| `UI.swift` | Вся SwiftUI-вёрстка: `RootView`, `SidebarView`, `AddressBar`, `TabRow`, `SpaceSwitcher`, `SpaceHeader`, `BookmarksSection`, `ToolbarView`, `HomeView`, `NotesPanel`, `NoteEditorView`, `CustomizePanel`. |

### Где лежат данные
**Всё** — в `~/Library/Application Support/Somnia/` (`Store.dir`), чтобы `.app` был самодостаточным и переносимым (копия на другой машине сохраняет заметки/сессию):
- `Vault/<UUID>.md` — **заметки** (YAML-frontmatter `id/title/tags/created/updated` + тело markdown). Раньше vault был «прибит» к дереву исходников через `#filePath`; теперь он в Application Support, а `Store.migrateLegacyVault` при первом запуске **разово копирует** заметки из старого `SomniaApp/Vault`, если тот есть (импорт не повторяется после правок/удалений).
- `session.json` — вкладки, спейсы, закладки, активная вкладка, бюджет, состояние сайдбара.
- `settings.json` — тема (appearance/direction/accent/density + кастомные цвета + `homeBgImage` + `searchEngine`).
- `history.json` — журнал посещений (http(s), деду́п по URL, лимит 3000; питает ⌘K и автодополнение адреса; чистится в Customize).
- `favicons/<host>.png` — кэш фавиконов (качаются с самого сайта, не через сторонний favicon-сервис).
- `backgrounds/` — копии выбранных картинок фона главной (`Store.backgroundsDir`, имена `<uuid>.<ext>`).
- `notes-config.json` — выбранный источник заметок (`source`: local/obsidian) и путь к внешнему Obsidian-vault (`vaultPath`).
- `graph.html` — рендерер графа (генерится из `GraphWebView.graphHTML`).

**Внешний Obsidian-vault (read-only)** — любой каталог, выбранный пользователем (в т.ч. в облаке), читается рекурсивно, не модифицируется.

---

## Ключевые механики

- **Оптимизация вкладок** (`BrowserState` + `WebViewPool`): ленивое создание WKWebView при первой активации; бюджет `maxLiveTabs` (по умолч. 6, настраивается); усыпление LRU при превышении и по простою (таймер, `idleLimit` **15 мин**) через `sleep()` с сохранением `interactionState`; пробуждение восстанавливает историю+скролл без cold-reload. Спящие вкладки помечены «луной». **Вкладки с активным аудио/видео не усыпляются** (async JS-проба `WebViewPool.isPlayingMedia` по `<video>/<audio>`; кэш `Tab.isPlayingMedia` обновляется свипом раз в 30с; бюджет предпочитает «молчащие» жертвы, но при превышении может усыпить и играющую).
- **Полноэкранный режим**: `cfg.preferences.isElementFullscreenEnabled` — fullscreen-кнопка на YouTube/Netflix работает.
- **Спейсы**: переключатель-точки + «+», переименование (двойной клик / меню «⋯»), удаление.
- **Закладки**: звёздочка в тулбаре / кнопка в сайдбаре; секция BOOKMARKS; клик открывает новой вкладкой. **Спейс закладок**: пилюля в `SpaceSwitcher` (флаг `bookmarksSpaceActive`) → `BookmarksPage` (сетка карточек) в `ContentArea`; производный от `bookmarks`, не в persisted `spaces`; флаг сбрасывается во всех путях смены вкладки/спейса + `closeTab`/`toggleReader`.
- **Заметки**: редактор (заголовок/теги/тело) ↔ предпросмотр (✎/👁); LINKS/BACKLINKS кликабельны; граф (Editor/Graph) — двусторонний мост Swift↔web (клик по узлу открывает заметку). Открытие Notes создаёт новый документ; пустые «Untitled» авто-чистятся; защита от дублей заголовков. **Граф: зум колёсиком (к курсору) + панорама** перетаскиванием пустого места (драг узла сохранён) — в `graph.html`.
- **Два источника заметок** (`NotesStore`, `enum VaultSource { local, obsidian }`): **Local** = внутренний `SomniaApp/Vault` (read-write, как раньше) и **Obsidian** = внешний vault пользователя (**read-only**, рекурсивная загрузка, идентичность по имени файла — так резолвятся `[[ссылки]]`, `id` = детерминированный `stableID` из относительного пути). Подключение — Customize → «Choose vault…» (`NSOpenPanel`), путь в `notes-config.json`. Переключение Local/Obsidian — сегмент в шапке Notes (+ бейдж «read-only», кнопка Refresh, рескан при открытии). В read-only ВСЕ мутирующие операции (`write/delete/scheduleSave/pruneEmpties/dedupeTitle/seed/create-on-link`) — no-op: ни один файл Obsidian не меняется. Облако (iCloud/Dropbox): читается как обычная папка; online-only файлы — `startDownloadingUbiquitousItem` + пропуск без падения.
- **Cmd+клик по ссылке** → новая вкладка **в фоне** (текущая остаётся активной); фоновая вкладка создаётся спящей и грузится лениво при первой активации. Реализация: `TabNavDelegate.decidePolicyFor` (ловит `.command` + `.linkActivated`, `.cancel` + `BrowserState.openInBackgroundTab`). Ссылки `target="_blank"`/`window.open` → новая **активная** вкладка через `WKUIDelegate.createWebViewWith` (раньше молча игнорировались).
- **Надёжный персист текущего URL**: `TabNavDelegate` наблюдает `WKWebView.url`/`.title` через KVO (`NSKeyValueObservation`) → SPA-навигации (History API `pushState` — YouTube и пр.), не вызывающие `didFinish`, теперь обновляют `Tab` и триггерят `scheduleSave`. Наблюдатели ставятся в `WebViewPool.webView(for:)` (`del.observe(wv)`), снимаются в `teardown` (`invalidate()`). Чинит баг «после перезапуска открываются старые ссылки».
- **Главный экран** (`HomeView`, при вкладке без URL): блоки — живые **часы** (Timer 1с), строка поиска, **мини-граф заметок** (`GraphWebView`, клик по узлу → заметка; expand-кнопка → `openNotesGraph()` открывает Notes на сегменте Graph через флаг `notesInitialGraph`). **Фон-картинка**: если задана (Customize → Home background) — рисуется `scaledToFill` под лёгким авто-scrim (`palette.bg` @0.30, читаемость часов/панелей) **через `.background(...)` контента — картинка не диктует размер, окно диктует размер картинки**, `NSImage` кэшируется в `@State` (не перечитывается на тик часов).
- **Горячие клавиши + меню macOS** (`App.swift`, `.commands`): File — New Tab ⌘T, Open File… ⌘O, Close Tab ⌘W; View — Reload ⌘R, Reader Mode ⌘⇧R, Open Location ⌘L, Customize ⌘,; History — Back ⌘[, Forward ⌘]; Tabs — Quick Open ⌘K, Next/Prev ⌘⇧]/⌘⇧[, Select Tab ⌘1–9 (⌘9 = последняя). Команды дёргают `BrowserState.current` / `Theme.current`. ⌘L фокусит адрес через `addressFocusPulse` (AddressBar ловит `.onChange`).
- **⌘K**: палитра команд/поиска (теперь пункт меню Tabs; старый скрытый-Button удалён).
- **Свайп назад 2 пальцами**: нативный жест WebKit (`allowsBackForwardNavigationGestures` в `Web.swift`).
- **Читалка файлов**: ⌘O (`NSOpenPanel`, pdf/html) и drag-drop файла в окно → новая вкладка с `file://` (`WebViewPool` грузит через `loadFileURL`). PDF — встроенный вьюер WKWebView. Также **локальный путь / `file://`-URL в адресной строке** открывается как файл (`BrowserState.resolve` распознаёт `file://`, абсолютные и `~`-пути до эвристики поиска — так пути с пробелами тоже открываются).
- **Reader Mode** (`Reader.swift`, ⌘⇧R / кнопка `doc.plaintext` в тулбаре): JS-экстрактор статьи → тематический HTML → `loadHTMLString`; round-trip через `interactionState` (`readerSnapshots`). Навигация (`go`/`goBack`/`goForward`/`reload`) сбрасывает reader-состояние (`exitReaderState`). *v1-лимит:* усыплённая reader-вкладка просыпается деградированно — восстанавливается повторным ⌘⇧R.
- **Тулбар** (`ToolbarView`): без заголовка страницы; кнопка **копировать URL** (`doc.on.doc` → ✓ на 1с, `NSPasteboard`). Адрес виден/редактируем в `AddressBar` сайдбара.
- **Кастомизация** (панель Customize): тема Light/Dark, лейаут Aurora/Slate, **цвета Background/Panel/Text/Accent через `ColorPicker` (полная палитра)** поверх пресетов + Reset, density, Tab budget, **прозрачность панелей** (слайдер `Transparency`, `Theme.surfaceOpacity` 0.3–1.0 множит альфу `surface/surface2` через `Palette.scalingSurface`; 1.0 = пресет, persist `settings.json`), **Home background** (Choose image… / Remove — `Theme.setHomeBackground/clearHomeBackground`; файл копируется в `Store.backgroundsDir`, в `settings.json` — только имя `homeBgImage`).
- **Сайдбар**: сворачивается слайдом до 64px (favicon-only) — drag-ручка на правом крае (двойной клик = тоггл), состояние персистится. Контент **плавно кросс-фейдит** при сворачивании (`.transition(.opacity)` на ветках collapsed/expanded под общей `.animation`).
- **Иконка**: `somnia_icon.png` → `AppIcon.icns` (build.sh авто-генерит при изменении png).

---

## Состояние и дальнейшие ветки

Реализовано: браузер (вкладки/спейсы/закладки/оптимизация), персист, Obsidian-ядро (заметки + граф + предпросмотр), ⌘K-поиск, кастомизация, дизайн-правки, иконка, меню macOS со стандартными шорткатами, кастомные цвета темы (ColorPicker), читалка локальных PDF/HTML + Reader Mode, медиа-аware усыпление (15 мин, не трогает играющие вкладки), полноэкранный стриминг, граф с зумом/панорамой, блочный главный экран (часы/поиск/мини-граф), спейс закладок, копирование URL, плавное сворачивание сайдбара, **vault в папке проекта + подключение внешнего Obsidian-vault (read-only, рекурсивно, переключение Local/Obsidian)**, **Cmd+клик → фоновая вкладка (+ `target="_blank"` → активная)**, **надёжный персист текущего URL через KVO (фикс стейл-ссылок после рестарта, в т.ч. SPA)**, **картинка-фон главной (Customize → Home background, с авто-scrim)**.

**Добавлено в 0.2** (эта итерация): настраиваемый поисковик (Google/DuckDuckGo/Bing/Brave, Customize); **история** посещений (`history.json`, дедуп, в ⌘K и автодополнении адреса); **автодополнение адресной строки** (история + закладки + открытые вкладки, выпадающий список); **Find on Page (⌘F)** — нативный `WKWebView.find`, бар с ↑/↓; **фавиконы** сайтов вместо буквенных плиток (кэш на диск, без стороннего сервиса); **менеджер загрузок** с прогресс-барами (поповер в тулбаре, reveal в Finder); **vault перенесён в Application Support** (переносимость `.app`, разовая миграция из старого пути); **граф больше не жжёт CPU в покое** (RAF паркуется, когда раскладка устаканилась / панель скрыта); юнит-тесты чистой логики (`test.sh`).

**Добавлено в 0.3** (приватность + Reader): **блокировщик трекеров/рекламы** (`WKContentRuleList`, встроенный блоклист ~21 домен, тумблер в Customize, применяется к живым вкладкам налету); **приватные вкладки** (⌘⇧N / кнопка «eye.slash» — ephemeral `WKWebsiteDataStore`, без истории, без дискового кэша фавиконов, не сохраняются в сессию, индикатор в списке); **Reader Mode лучше извлекает** (учёт link-density, приоритет `<article>`/`<main>`, больше чистки шума, сохранение картинок) и **корректно восстанавливается после усыпления** (кэш reader-HTML + перезагрузка в `wake()` — v1-лимит закрыт).

Возможные следующие шаги:
- React/d3-граф вместо canvas (полноценная d3-симуляция, кластеры) — базовый зум/панорама уже есть.
- Drag-reorder вкладок и перенос между спейсами.
- Полноэкранный граф заметок + фильтр по тегам.
- Кросс-рестартный `interactionState` спящих вкладок (сейчас восстанавливаются по URL).
- **Inline-кликабельные `[[ссылки]]` + автодополнение при наборе `[[` в редакторе заметок** — требует замены `TextEditor` на обёртку над `NSTextView` (доступ к позиции каретки/атрибутам); лучше делать с живым GUI, отдельной итерацией.
- **Read-write для внешнего Obsidian-vault** — сейчас строго read-only; включение требует UX-предупреждений (мутация чужих файлов), обсудить отдельно.
- PDFKit-вьюер (тамбнейлы/поиск/счётчик страниц) вместо встроенного WKWebView PDF.
- Полноценная Mozilla Readability вместо компактного экстрактора (если нужно ещё выше качество извлечения; ~100 КБ JS — взвесить против «0 зависимостей»).

---

## Заметки для будущего меня
- Каждая правка UI = `./build.sh && open Somnia.app` (предварительно `pkill`). Сборка чистая = всё ок (Edit/Write упадут, если правка не применилась).
- GUI нельзя проверить из CLI — проверяю компиляцию сборкой и состояние через файлы в `~/Library/Application Support/Somnia/`.
- `BrowserState.current` (static weak) — чтобы `TabNavDelegate` дёргал `scheduleSave()` на обновление заголовков; **меню macOS тоже ходит через `BrowserState.current` / `Theme.current`** (static weak), отдельного DI в `.commands` нет.
- Кастомные цвета: nil-оверрайды = пресет 1:1 (обратная совместимость старых `settings.json`); при любом оверрайде вторичные токены (`dim/faint/border/edge/node`) деривируются из Background/Panel/Text.
- Reader: входит через `toggleReader`, состояние в `readerSnapshots[tabID]`; любая навигация чистит его через `exitReaderState`, закрытие вкладки/спейса — тоже. Спецификация/план/леджер реализации — `docs/superpowers/`.
- Двусторонний мост графа: Swift → `evaluateJavaScript("setGraph(...)")`, web → `messageHandlers.somnia.postMessage({id})`.
