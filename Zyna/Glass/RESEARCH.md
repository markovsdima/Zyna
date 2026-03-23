# Glass Effect: Исследование и Архитектура

> Исследование проведено 22 марта 2026. iOS 26.3, iPhone 16 pro max.

## Цель

Производительно передавать пиксели фона за view в Metal shader для кастомного эффекта стекла (refraction, chromatic aberration, и т.д.). Не использовать системный Liquid Glass — нужен полный контроль над шейдером.

---

## Часть 1: Что сломалось на iOS 26

### CABackdropLayer и windowServerAware

До iOS 26 работала схема:
1. Создаём view с `layerClass = CABackdropLayer`
2. Ставим `layer.setValue(true, forKey: "windowServerAware")`
3. Слой посылает запрос через Mach IPC в **backboardd** (render server iOS)
4. Render server композитит всё что ниже этого слоя и возвращает IOSurface
5. `drawHierarchy` на этом view рисует содержимое backdrop'а в наш CGContext
6. Через ZeroCopyBridge (CVPixelBuffer + IOSurface) данные попадают в MTLTexture без копирования

**На iOS 26 Apple полностью убрал `windowServerAware`.** Свойство исчезло из runtime — нет ни в properties, ни в methods. Не переименовано, а удалено.

### Почему убрали

Apple переделал пайплайн под Liquid Glass. Вместо roundtrip'а "дай пиксели → я применю фильтр" теперь используется единый `glassBackground` CAFilter, который **применяется самим композитором** в один проход. Композитор сам делает refraction + blur + vibrancy, не отдавая пиксели обратно в процесс приложения. Быстрее и безопаснее (нет утечки пикселей между процессами).

---

## Часть 2: Runtime-исследование iOS 26.3

### Probe 1-2: CABackdropLayer

**Дамп runtime** показал 25 properties и 61 method. Ключевые находки:

- `windowServerAware` — **полностью отсутствует**
- `enabled` — новое свойство, по умолчанию `true`, но `contents` всегда `nil`
- `captureOnly` — есть, работает, но не даёт содержимого
- `groupNamespace = "owningContext"` — backdrop скопирован к CAContext окна
- `scale = 0.25` — Apple внутренне использует 1/4 разрешения для backdrop
- `_mt_applyMaterialDescription:removingIfIdentity:` — новый путь активации через MaterialKit
- `rasterizationPrefersWindowServerAwareBackdrops` — существует на CALayer, но установка в `true` не помогает

**Brute-force 30+ ключей-кандидатов** на замену `windowServerAware` — ни один не активировал capture. `contents` остаётся `nil` во всех комбинациях фильтров и настроек.

### Probe 3: UIVisualEffectView

Структура на iOS 26 **не изменилась**:
- `subviews[0]` = `_UIVisualEffectBackdropView`, layer = `UICABackdropLayer`
- `subviews[1]` = `_UIVisualEffectSubview` (tint overlay)
- Фильтры: `gaussianBlur` + `colorSaturate`

Но `drawHierarchy` на UIVisualEffectView **возвращает `false`** и даёт чёрное изображение (0/100 non-black пикселей). Apple заблокировал этот путь.

### Probe 4: CAFilter

Все фильтры существуют и создаются через `+[CAFilter filterWithType:]`:

| Фильтр | Статус |
|--------|--------|
| `glassBackground` | ✅ Существует (новый, iOS 26) |
| `liquidGlass` | ✅ Существует (новый) |
| `glass` | ✅ Существует |
| `refraction` | ✅ Существует |
| `backdrop` | ✅ Существует |
| `materialBackground` | ✅ Существует |

Но применение любого из них к CABackdropLayer не активирует capture. Эти фильтры работают только на стороне композитора.

### Probe 5: CAContext

- `CAContext.currentContext` → `nil`
- Через `window.layer` можно получить CAContext: `contextId = 0xc9157caf`
- Есть `renderContext`, `createImageSlot:hasAlpha:`, но доступ к render surface заблокирован

### Probe 6: Альтернативные методы захвата

| Метод | Результат |
|-------|-----------|
| `window.drawHierarchy` | ✅ **Работает!** 22/100 non-black, `true` |
| `hostView.drawHierarchy` | ✅ 11/100 non-black |
| `layer.render(in:)` | Частично, 5/100 non-black |
| `CARenderer` | ❌ No-op, 0.00ms, пустые пиксели |
| `UIScreen.snapshotView` | ❌ Чёрный |
| `window.snapshotView` | ❌ Чёрный |

**CARenderer оказался пустышкой** — 0.00ms это no-op, он ничего не рендерит на iOS 26.

### Probe 7: drawHierarchy в CVPixelBuffer

`drawHierarchy` **не пишет в pushed CGContext** (через `UIGraphicsPushContext`). Работает только с `UIGraphicsBeginImageContextWithOptions`. Это означает zero-copy через CVPixelBuffer невозможен — нужен промежуточный CGImage.

### Probe 8: createIOSurfaceWithFrame:

Приватный API на UIWindow. **Лучший метод:**

```swift
let sel = Selector(("createIOSurfaceWithFrame:"))
typealias Func = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
let fn = unsafeBitCast(window.method(for: sel), to: Func.self)
let unmanaged = fn(window, sel, frame)
// → IOSurfaceRef → device.makeTexture(iosurface:) → zero-copy MTLTexture
```

**Бенчмарк (10 итераций):**

| Регион | Время (avg) |
|--------|-------------|
| Glass rect 392×120 | **1.93ms** |
| Full window 440×956 | **3.63ms** |
| Small rect 50×50 | **0.88ms** |
| Full pipeline (IOSurface + MTLTexture) | **1.78ms** |
| Full cycle (hide→capture→show) | **0.81ms** |

Pixel format: `bgr10a2Unorm` (10-bit цвет, 2-bit alpha). Текстура создаётся через `device.makeTexture(descriptor:iosurface:plane:)` — zero-copy, IOSurface и MTLTexture делят одну память.

---

## Часть 3: Проблема self-capture

`createIOSurfaceWithFrame:` читает из **committed render tree** окна. Если glass view находится в том же окне, он захватывает сам себя → feedback loop → сходится в серый.

### Что пробовали

| Подход | Результат |
|--------|-----------|
| `layer.isHidden = true` без flush | ❌ Серый (uncommitted change не видна render server'у) |
| `layer.isHidden = true` + `CATransaction.flush()` | ❌ Серый (one-frame delay в render server) |
| `layer.opacity = 0` + flush | ❌ Серый |
| Overlay window | ✅ **Работает!** |

### Решение: Two-Window Architecture

Glass рендерится в отдельном `PassthroughWindow` (overlay), capture идёт из main window (которое никогда не содержит glass). Никакого self-capture.

---

## Часть 4: Финальная архитектура

### Компоненты

```
GlassAnchor (UIView)              — невидимый маркер в main window
    ↓ didMoveToWindow
GlassService (singleton)           — overlay window, capture, render loop
    ├─ PassthroughWindow           — hitTest→nil, canBecomeKey→false
    ├─ GlassRenderer (CAMetalLayer) — рисует по команде GlassService
    ├─ ScreenCaptureManager        — double-buffered IOSurface A/B
    └─ DisplayLinkDriver           — 120fps tick
```

### Flow

1. Разработчик добавляет `GlassAnchor` как subview
2. `didMoveToWindow()` → `GlassService.shared.register(anchor:)`
3. GlassService создаёт PassthroughWindow + GlassRenderer
4. Каждый tick (120fps):
   - Опрос frame через `presentation layer → convert(bounds, to: window)`
   - `createIOSurfaceWithFrame:` на source window
   - `device.makeTexture(iosurface:)` — zero-copy
   - Позиционирование renderer'а + Metal draw
5. Anchor убран → `GlassRegistration.deinit` → deregister → cleanup

### iOS version split

IOSurface + overlay — основной путь на всех iOS. CABackdropLayer (GlassView) сохранён для A/B тестирования.

### Trigger-система (event-driven capture)

Стекло не захватывает каждый кадр. Capture только когда контент изменился:

1. **`setNeedsCapture()`** — one-shot (скролл, layout, новое сообщение)
2. **`captureFor(duration:)`** — burst на N секунд (context menu shrink/dismiss)
3. **`anchor.isAnimating`** — автоматически (navigation push/pop, keyboard). Сравнивает `presentationFrame != modelFrame`
4. **`GlassCaptureSource`** — протокол для анимированных ячеек (Lottie, GIF). Проверяет `needsGlassCapture && intersects(glassRect)`

Idle = **0% CPU** (display link тикает но skip capture+render).

### Производительность (финальная)

```
fps=120  capture=~5.5ms  render=~0.4ms  total=~6.2ms
```

120Hz стабильно. Budget 8.33ms — запас ~25%.

Сравнение на SE 2020 (A13): IOSurface total=7.2ms vs CABackdropLayer total=7.9ms — IOSurface быстрее.

### API

```swift
// 3 строки — стекло готово:
let glass = GlassAnchor()
glass.cornerRadius = 20
someView.addSubview(glass)
// Убрать: glass.removeFromSuperview()
```

---

## Часть 5: Что ещё существует но не работает

### MaterialKit (_mt_ методы) — проверено, тупик

CABackdropLayer имеет все `_mt_` методы: `mt_applyMaterialDescription:removingIfIdentity:`, `_mt_configureFilterOfType:ifNecessaryWithFilterOrder:`, `_mt_setValue:forFilterOfType:valueKey:filterOrder:removingIfIdentity:` и другие. Все они отвечают `responds(to:) = true`.

**Эксперимент:** скопировали точную конфигурацию с живого UIVisualEffectView'шного backdrop layer'а (filters, все KVC-значения) на чистый CABackdropLayer → `contents = nil`. Активация capture не произошла.

Живой backdrop использует:
- `groupName = nil` (не UUID)
- `groupNamespace = "owningContext"`
- `scale = 0.25` (четверть разрешения)
- Фильтры: `luminanceCurveMap` + `colorSaturate` + `gaussianBlur`

**Вывод:** активация capture происходит не через properties/filters, а через внутреннюю регистрацию в render server (backboardd), которую выполняет UIVisualEffectView при инициализации. Эта регистрация недоступна третьим лицам. MaterialKit — путь стилизации, не активации.

Из MaterialKit классов найден только `MTVisualStyling` с методами `initWithCoreMaterialVisualStyling:`, `applyToView:withColorBlock:`, `_layerConfig`. `MTMaterialView` существует с фабриками `materialViewWithRecipe:configuration:`, но создаёт системные material'ы.

Остальные классы (`MTMaterialDescription`, `MTCoreMaterialDescription`, `_MTBackdropCompoundEffect`, `_MTBackdropEffect`) — **не существуют** на iOS 26.3.

### UICABackdropLayer vs CABackdropLayer

`UICABackdropLayer` — подкласс `CABackdropLayer`, добавляет только `setValue:forKeyPath:`. Hierarchy: `UICABackdropLayer → CABackdropLayer → CALayer → NSObject`. Используется внутри `_UIVisualEffectBackdropView`.

### createIOSurface (без frame)

Существует и работает. Возвращает IOSurface всего окна (1320×2868) за ~2.69ms. Но `createIOSurfaceWithFrame:` удобнее — сразу обрезает до нужного региона.

### CARenderServerRenderDisplay — sandbox-заблокирован

C-функция из QuartzCore, найдена через dlsym. Сигнатура из WebKit QuartzCoreSPI.h и coolstar/RecordMyScreen:

```c
void CARenderServerRenderDisplay(mach_port_t port, CFStringRef displayName, IOSurfaceRef surface, int x, int y);
// Использование: CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
```

Вызов проходит без краша (1.56ms), но **0 пикселей** — render server не пишет в наш surface. Sandbox ограничение. coolstar использовал на jailbreak.

Также найдены: `CARenderServerCaptureDisplay`, `CARenderServerRenderLayer`, `CARenderServerRenderDisplayExcludeList`, `CARenderServerCaptureDisplayExcludeList` — все существуют в QuartzCore.tbd, но заблокированы sandbox'ом.

### _UIVisualEffectViewBackdropCaptureGroup — недостаточно

Механизм регистрации backdrop'а в render server:

```
initWithName:scale:          — создать группу
addBackdrop:update:          — добавить backdrop view
setCaptureGroup:             — установить группу на _UIVisualEffectBackdropView
scale / setScale:            — контроль разрешения (0.125 у Apple)
updateAllBackdropViews       — обновить все backdrop'ы
```

**Эксперимент:** создали группу, создали `_UIVisualEffectBackdropView`, вызвали `setCaptureGroup:` + `addBackdrop:update:` + `applyRequestedFilterEffects` → `contents = nil`. Также пробовали добавить в ЖИВУЮ группу от UIVisualEffectView → `contents = nil`. CaptureGroup необходимое, но недостаточное условие. Активация происходит глубже (Mach IPC к render server при инициализации UIVisualEffectView).

### CAWindowServer — crash (sandbox)

Попытка получить `CAWindowServer.server` → crash при чтении displays. Sandbox полностью блокирует доступ к window server на iOS.

---

## Часть 6: Полезные ссылки и ресурсы

- [CAPluginLayer & CABackdropLayer — Aditya Vaidyam](https://aditya.vaidyam.me/blog/2018/02/17/)
- [The Secret Life of Core Animation — Aditya Vaidyam](https://medium.com/@avaidyam/the-secret-life-of-core-animation-e0966f942a71)
- [ShatteredGlass — AlexStrNik](https://github.com/AlexStrNik/ShatteredGlass) — reverse-engineered Liquid Glass
- [LiquidGlassKit — DnV1eX](https://github.com/DnV1eX/LiquidGlassKit) — подтверждает iOS 26.2 breakage
- [VariableBlurView — aheze](https://github.com/aheze/VariableBlurView) — CABackdropLayer трюки
- [iOS Rendering Docs — EthanArbuckle](https://github.com/EthanArbuckle/ios-rendering-docs) — архитектура render server
- [Reverse Engineering NSVisualEffectView — Oskar Groth](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview)
- [WebKit QuartzCoreSPI.h — CARenderServer signatures](https://www.mail-archive.com/webkit-changes@lists.webkit.org/msg104923.html)
- [coolstar/RecordMyScreen — CARenderServerRenderDisplay usage](https://github.com/coolstar/RecordMyScreen/blob/master/RecordMyScreen/CSScreenRecorder.m)
- [Bryce Bostwick — On-Device Render Debugging](https://bryce.co/on-device-render-debugging/)
