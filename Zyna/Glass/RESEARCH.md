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

### Эволюция

Первоначально использовалась two-window архитектура (overlay `PassthroughWindow` + `createIOSurfaceWithFrame:`) для обхода self-capture. Позже упрощена до **single-window + `layer.render()`**: рендерим только `sourceView` (без glass UI), что автоматически исключает self-capture без второго окна.

### Компоненты

```
GlassAnchor (UIView)                — невидимый маркер, указывает sourceView для захвата
    ↓ didMoveToWindow
GlassService (singleton)            — capture + render loop, single window
    ├─ CaptureCache                 — double-buffered MTLBuffer-backed CGContext (zero-copy CPU→GPU)
    ├─ GlassRenderer (CAMetalLayer) — MPS blur + Metal fragment shader
    └─ DisplayLinkDriver            — 120fps tick
```

### Flow

1. Разработчик добавляет `GlassAnchor` как subview, устанавливает `sourceView`
2. `didMoveToWindow()` → `GlassService.shared.register(anchor:)`
3. GlassService создаёт GlassRenderer в main window
4. Каждый tick (120fps, event-driven):
   - Опрос frame через `presentation layer → convert(bounds, to: window)`
   - `sourceView.layer.render(in: ctx)` — рендер только контента, не glass UI
   - CGContext пишет напрямую в MTLBuffer (zero-copy CPU→GPU, без memcpy)
   - Double-buffered: CPU пишет slot A, GPU читает slot B, flip
   - MPS Gaussian blur + Metal fragment shader (refraction, chromatic aberration, tint)
5. Anchor убран → `GlassRegistration.deinit` → deregister → cleanup

### Capture: layer.render() оптимизации

- **Zero-copy CPU→GPU**: CGContext рендерит в MTLBuffer(.shared), buffer.makeTexture() даёт GPU view на ту же память — без memcpy
- **Double-buffered**: два слота, CPU и GPU никогда не работают с одним буфером
- **@2x capture** вместо @3x — за blur разница невидна, -44% пикселей
- **Sublayer culling**: только intersecting + visible (isHidden, opacity) sublayers
- **memset вместо ctx.clear()**: прямое обнуление буфера, минуя CG pipeline
- **Fallback** на texture.replace() для Intel simulator (buffer-backed textures не поддерживаются)

### Каждая glass зона = отдельный pipeline

Nav bar и input bar — два независимых capture+render. Это быстрее fullscreen: capture масштабируется с пикселями, а два маленьких региона (~416K px) дешевле одного fullscreen (~1.34M px). Sublayer culling тоже эффективнее на маленьких регионах.

### Trigger-система (event-driven capture)

Стекло не захватывает каждый кадр. Capture только когда контент изменился:

1. **`setNeedsCapture()`** — one-shot (скролл, layout, новое сообщение)
2. **`captureFor(duration:)`** — burst на N секунд (context menu shrink/dismiss)
3. **`anchor.isAnimating`** — автоматически (navigation push/pop, keyboard). Сравнивает `presentationFrame != modelFrame`
4. **`GlassCaptureSource`** — протокол для анимированных ячеек (Lottie, GIF). Проверяет `needsGlassCapture && intersects(glassRect)`

Idle = **~0% CPU**: display link останавливается после 3 idle тиков. Watchdog timer (20 Hz, ~16μs/сек) проверяет `isAnimating` на якорях — при обнаружении анимации (navigation gesture и т.д.) перезапускает display link. Явные триггеры (`setNeedsCapture`, `captureFor`) тоже будят display link напрямую.

### Производительность

```
iPhone 16 Pro Max, iOS 26.3, 120fps:
capture=~1.5ms  render=~0.3ms  total=~1.8ms (типичный)
capture=~2.5ms  render=~1.0ms  total=~3.5ms (worst case)
```

Budget 8.33ms — запас ~60%. До оптимизаций (IOSurface + overlay) было total=~6.2ms.

### API

```swift
// 3 строки — стекло готово:
let glass = GlassAnchor()
glass.cornerRadius = 20
glass.sourceView = contentView  // что захватывать
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

## Часть 6: Глубокое исследование альтернативных путей (24 марта 2026)

Систематическое исследование всех возможных способов получить пиксели фона для Metal шейдера. 11 фаз экспериментов на устройстве (iPhone 16 Pro Max, iOS 26.3).

### Rendering pipeline iOS

```
App Process                     backboardd                        GPU / Display
═══════════                     ══════════                        ═══════════
UIView / CALayer
    ↓ CATransaction.commit()
CA::Render::Encoder             CA::Render::Decoder
    ↓ Mach IPC                      ↓
com.apple.CARenderServer ──────→ Compositor (Metal)
  (IOSurface ports,                 ↓
   layer tree diffs)            Display IOSurface ──────────────→ IOMobileFramebuffer → Screen
```

Единственная точка выхода пикселей из render server в app process: `UIWindow.createIOSurfaceWithFrame:` (one-shot snapshot из пула IOSurface'ов).

### CA::Render протокол

**C++ символы полностью stripped на iOS.** Ни один из 25 mangled symbols (`CA::Render::Encoder`, `Decoder`, `Filter::encode`, `Object::decode` и др.) не доступен через dlsym. Apple стрипнул их начиная с iOS (на macOS были экспортированы).

C-функции найдены:
- `CARenderServerGetPort` → возвращает Mach port (≈30K-86K)
- `CARenderServerGetServerPort` → 0 (недоступен)
- `CARenderServerRenderLayer` → **crash** (неизвестная сигнатура)
- `CARenderServerRenderDisplayClientList` → **crash** (неизвестная сигнатура)
- `CARenderServerRenderDisplay` → 0 пикселей (sandbox)
- `CARenderServerCaptureDisplayClientList` → nil

### CAFilter — закрытая система

42 типа фильтров на iOS 26. Новые: `glassBackground`, `glassForeground`, `liquidGlass`, `refraction`, `glass`, `chromaticAberration`, `chromaticAberrationMap`, `displacementMap`, `variableBlur`.

**Type indices (через ivar `_type`):**

  Фильтр              | _type      

|---------------------|-------------|
| colorMatrix         | 113 (0x71)  |
| colorSaturate       | 117 (0x75)  |
| chromaticAberration | 96 (0x60)   |
| displacementMap     | 202 (0xCA)  |
| gaussianBlur        | 280 (0x118) |
| glassBackground     | 283 (0x11B) |
| liquidGlass         | 867 (0x363) |
| refraction          | 868 (0x364) |
| glass               | 869 (0x365) |

CAFilter принимает ЛЮБОЙ ключ через `setValue:forKey:` → хранит в `_attr` dict. Нельзя определить реальные параметры — render server игнорирует неизвестные ключи.

`CA_copyRenderValue` (не `copyRenderValue:`) возвращает `CA::Render::Object*` — бинарное дерево вложенных объектов:
- `displacementMap` содержит `glassBackground` содержит `chromaticAberration` → `vibrantColorMatrix`

**Расширение невозможно.** Нет `registerFilter`, нет plugin mechanism, нет loadable modules. Таблица фильтров скомпилирована в QuartzCore.framework.

### CAPortalLayer — compositor не применяет фильтры

`_UIPortalView` с `layer.filters = [gaussianBlur(20)]`:
- `drawHierarchy`: 0% non-black
- `layer.render`: 0% non-black
- IOSurface через createIOSurfaceWithFrame: **100% non-black**, но blur НЕ применён (0% diff с/без фильтра)
- Blur radius sweep (0→50): 0% diff на каждом шаге

**Compositor обрабатывает CAPortalLayer как redirect, пропуская все filters/backgroundFilters.**

### _UIReplicantView и CASlotProxy

`UIScreen._snapshotExcludingWindows:withRect:` → `_UIReplicantView`:
- `layer.contents` = `CASlotProxy` (не IOSurface). CFTypeID=1 (не IOSurface TypeID)
- CASlotProxy: 1 ivar (`_proxy` void*), 3 метода (`initWithName:`, `CA_copyRenderValue`, `dealloc`)
- `_UIReplicantLayer._slotId` → `_UISlotId` (opaque ObjC object)
- Пиксели живут в backboardd. Proxy = token, не данные.

Pipeline _snapshotExcludingWindows → replicant → temp window → IOSurface **работает** (101/100 non-black), но **10.5ms** — медленнее createIOSurfaceWithFrame (6.7ms).

### IOSurface global scan

`IOSurfaceLookup(id)` **работает из sandbox** — возвращает IOSurface по глобальному ID, same backing memory.

Scan IDs 1..2000: найдено **3 surface'а** (все 1320×471, вероятно системный UI). Display framebuffer **не доступен**. Ни одного screen-sized (1320×2868). Ни одного live (seed/pixels не меняются).

IOSurface из `createIOSurfaceWithFrame:` — **static snapshot**, не обновляется render server'ом. Seed=1 неизменен. Render server использует пул IOSurface'ов (IDs переиспользуются после release).

### Context ID capture

`+[UIWindow createIOSurfaceWithContextIds:count:frame:]` **работает**: 1.53ms, 100/100 non-black. Сопоставимо с `createIOSurfaceWithFrame:` (1.11ms). Все варианты доступны:
- `+createIOSurfaceWithContextIds:count:frame:outTransform:`
- `+createIOSurfaceWithContextIds:count:frame:usePurpleGfx:outTransform:`
- `+createIOSurfaceOnScreen:withContextIds:count:frame:baseTransform:`

### ReplayKit

`RPScreenRecorder.startCapture`: first frame latency **6633ms** (consent dialog), **21 fps**, разрешение 884×1920 (уменьшенное). IOSurface-backed CVPixelBuffer → MTLTexture работает. Непригодно для 120fps.

Интересные SPI: `setWindowToRecord:`, `checkContextID:withHandler:`, `pauseInAppCapture`.

### Сводная таблица всех исследованных методов

 Метод                                      | Работает? | Скорость | Reusable? | Причина блокировки 
--------------------------------------------|-----------|----------|-----------|--------------------
 `createIOSurfaceWithFrame:`                | ✅        | ~1-5ms   | ❌ (пул)  | —                  
 `createIOSurfaceWithContextIds:`           | ✅        | ~1.5ms   | ❌ (пул)  | —                  
 `_snapshotExcludingWindows:`               | ✅        | ~10.5ms  | ❌        | View, не пиксели напрямую 
 `layer.render(in:)`                        | ✅        | ~5-7ms   | ✅        | Только свой layer tree 
 `RPScreenRecorder`                         | ✅        | 21fps    | ❌        | User consent, слишком медленно 
 `IOSurfaceLookup(id)`                      | ✅        | мгновенно| ❌        | Surfaces статические 
 `CARenderServerRenderDisplay`              | ❌        | —        | ✅        | Sandbox (0 пикселей) 
 `CARenderServerRenderLayer`                | ❌        | —        | ✅        | Crash (неизвестная сигнатура) 
 `CARenderServerRenderDisplayClientList`    | ❌        | —        | ✅        | Crash 
 `CARenderServerCaptureDisplayClientList`   | ❌        | —        | —         | nil 
 CAFilter на CAPortalLayer                  | ❌        | —        | —         | Compositor игнорирует 
 Custom CAFilter plugin                     | ❌        | —        | —         | Нет механизма расширения 
 CASlotProxy → IOSurface                    | ❌        | —        | —         | Opaque reference 
 IOMobileFramebuffer                        | ❌        | —        | —         | Sandbox + entitlement 
 CA::Render::Encoder                        | ❌        | —        | —         | Symbols stripped

### Вывод

**`layer.render()` + MTLBuffer-backed CGContext (zero-copy CPU→GPU) — текущий production путь.** Public API, App Store-safe, ~1.8ms total на 120fps.

`createIOSurfaceWithFrame:` работает быстрее для единичного snapshot, но требует overlay window (self-capture проблема) и является private API. `layer.render()` с sublayer culling + sourceView isolation решает self-capture без второго окна.

Архитектурная причина ограничений: Apple спроектировал render pipeline так, что пиксели никогда не передаются приложению в режиме реального времени. Каждый метод — one-shot snapshot. Reusable surface capture заблокирован sandbox'ом. Display framebuffer защищён на уровне ядра.

---

## Часть 7: Полезные ссылки и ресурсы

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
