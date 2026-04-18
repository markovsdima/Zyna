# Zyna — VoiceOver & Accessibility

Zyna supports VoiceOver — Apple's screen reader for blind and
low-vision users. This file is for developers adding new UI:
how the system works, how to wire up new screens, and what
breaks if you forget.

If you've never used VoiceOver: enable it in
**Settings → Accessibility → VoiceOver** (or Cmd+F5 in the
simulator). Swipe right for next element, double-tap to
activate. Try it on the Rooms screen — that's the easiest place
to see what "good" feels like.

---

## How it works (the short version)

VoiceOver doesn't see the screen the way you do. It reads an
**accessibility tree** — a parallel structure where each thing
the user can interact with is a node with a label, a role
("button", "header"), and an action ("activate to open").

**You as a developer:**
- Mark interactive things with `isAccessibilityElement = true`
- Give them `accessibilityLabel = "what it is"` and
  `accessibilityTraits = .button` (or `.header`, etc.)
- Make sure double-tap actually does something —
  `accessibilityActivate()` must fire your handler

**The catch with Texture:** the framework wraps cells and
manages views in ways that drop your accessibility settings or
hide your elements from VoiceOver. We have a small set of
helpers in this folder that paper over those issues. As long as
you use them (`ZynaCellNode`, `AccessibleButtonNode`), it
mostly Just Works.

---

## Adding accessibility to a new cell

Inherit from `ZynaCellNode` instead of `ASCellNode`. In `init()`
after `super.init()`:

```swift
isAccessibilityElement = true
accessibilityTraits = .button
accessibilityLabel = "Chat with \(name), \(unreadCount) unread"
```

That's it. `ZynaCellNode` handles the rest (forwarding to the
wrapping `_ASTableViewCell`, perf gating, etc.).

For VoiceOver actions (Reply/Forward/Delete-style things) set
the provider:
```swift
cell.accessibilityActionsProvider = { [weak self] in
    return [
        UIAccessibilityCustomAction(name: "Reply") { ... },
        UIAccessibilityCustomAction(name: "Delete") { ... },
    ]
}
```

User reaches them via the rotor → "Actions" → swipe down.

## Adding accessibility to a glass overlay screen

When you have a glass bar floating over a table/list:

1. Create a screen node (e.g. `MyScreenNode: ScreenNode`) with
   `weak var glassBar: ASDisplayNode?` and a content view ref
2. Override `accessibilityElements` to return `[glassBar.view, content]`
   — bar first, otherwise touch hits fall through to the content
   underneath the transparent glass
3. In each bar button: use `AccessibleButtonNode` and set
   `isAccessibilityElement = true`, `accessibilityLabel`,
   `accessibilityTraits = .button`

See [ChatNode](Zyna/Chat/Nodes/ChatNode.swift) and
[RoomsScreenNode](Zyna/Screens/Rooms/RoomsController.swift) for
worked examples.

## Activating things from VoiceOver

VoiceOver's double-tap calls `accessibilityActivate()`. UIControl
subclasses handle it for free; ASButtonNode doesn't.

- For buttons → use `AccessibleButtonNode` (it forwards
  double-tap to `sendActions(.touchUpInside)`)
- For tappable nodes → override `accessibilityActivate() -> Bool`
  on the node, fire your callback, return `true`
- For cells with a primary action (image opens viewer, voice
  plays) → override `accessibilityActivate()` on the cell and
  call the existing tap handler

## Debugging

- **Accessibility Inspector** (Xcode → Open Developer Tool):
  point at any element to see its label/traits/frame. Run the
  audit tab to find missing labels and other issues.
- **Real VoiceOver** is more honest than the inspector — toggle
  it on a real device and try the actual flows.
- **Focus tracking**: observe
  `UIAccessibility.elementFocusedNotification` in a temporary
  helper to log what VoiceOver focuses on swipe vs. touch.
  Useful when the tree looks right but reality doesn't match.

---

# Reference: the surprises that bit us

Below is the technical detail of why our helpers exist. Read
when changing the helpers themselves or debugging deep weirdness.

## ASCellNode accessibility doesn't reach `_ASTableViewCell`

Texture wraps every `ASCellNode` in `_ASTableViewCell`
(UITableViewCell subclass). It mirrors **only**
`isAccessibilityElement` and `accessibilityElementsHidden` from
the node onto the wrapper — not label, value, traits, hint, or
custom actions. Result: the wrapper becomes the accessibility
element, but with empty data, and your label is invisible.

This is an unfixed Texture bug,
[issue #1997](https://github.com/TextureGroup/Texture/issues/1997).

`ZynaCellNode.layout()` works around it by setting
`cell.isAccessibilityElement = false` and
`cell.accessibilityElements = [view]` — making the wrapper a
transparent container that exposes the node's view as the
element. VoiceOver then queries the node directly, and overrides
on the node (`accessibilityActivate`, `accessibilityCustomActions`)
fire as expected.

Done in `layout()`, not `didLoad`/`didEnterHierarchy`, because
the cell wrapper isn't in the superview chain until the node is
actually placed in the table — which happens at layout time.

Gated on `UIAccessibility.isVoiceOverRunning` so non-VoiceOver
users pay nothing.

## Touch exploration falls through transparent overlays

VoiceOver has two navigation modes:
- **Swipe** — walks the accessibility tree top-down
- **Touch** (single-finger drag) — calls `accessibilityHitTest`
  at the touched point

Texture builds the accessibility tree by iterating
`view.subviews` **in array order** — `subviews[0]` is the bottom
of the z-stack. In our chat: `tableNode` is added first, so
`accessibilityHitTest` finds the table at any point and returns
a cell from underneath the glass bar. The bar gets skipped.

Fix: override `accessibilityElements` on the parent node to
return glass bars **before** the table.

## `ASButtonNode` ignores VoiceOver double-tap

`ASButtonNode` is `ASControlNode`, not `UIControl` — its default
`accessibilityActivate()` does nothing. Focus works, double-tap
is silent.

`AccessibleButtonNode` overrides `accessibilityActivate()` to
call `sendActions(forControlEvents: .touchUpInside)`, which
fires registered targets. Use it everywhere instead of plain
`ASButtonNode`.

## Texture needs explicit `isAccessibilityElement = true`

`ASButtonNode`, `ASTextNode`, etc. don't default to
`isAccessibilityElement = true`. Without it, Texture's
`CollectAccessibilityElementsForView` skips the node entirely.
Always set it alongside the label.

## Where each piece of accessibility lives

| Component | Location |
|---|---|
| Glass bar buttons | `init()` of the bar |
| Glass bar title (`PresenceTitleNode`, `GlassTopBarTitleView`) | Inside the title node, updated when content changes |
| Chat input buttons | `setupNodes()` of `ChatInputNode` |
| All cells | `init()` for label/traits, `ZynaCellNode.layout()` for forwarding |
| Tab bar items | `init()` + `isSelected` setter for the trait |
| Screen change announcements | Push/pop completion blocks in `ZynaNavigationController` |
