## Navigation

Zyna uses custom navigation primitives instead of `UINavigationController` and `UITabBarController`.

Core pieces:

- `ZynaNavigationController`
  owns a plain view-controller stack, custom push/pop animations, interactive back-swipe, and tab-bar visibility sync.
- `ZynaTabBarController`
  owns the root tabs and swaps child controller views directly instead of relying on UIKit tab-controller behavior.
- `CrossStackTransitionCoordinator`
  handles transitions that cross tab boundaries but should still look like one continuous navigation push.

### Routing boundary

`MainCoordinator` is the routing boundary for cross-stack flows.

That means feature coordinators should ask for a route outcome:

- `routeToChat(room:)`
- `routeToChatAndCall(room:)`
- other future route-style entry points

They should not decide on their own whether to:

- switch tabs
- pop another stack
- run a cross-stack handoff

Those choices belong at the root coordinator level.

### Intra-stack navigation

Normal screen-to-screen navigation inside one tab should go through `ZynaNavigationController`.

Important properties:

- push/pop animations are custom and run in lockstep with glass capture
- `hidesBottomBarWhenPushed` is forwarded manually to `ZynaTabBarController`
- `UIViewController.navigationController` does not apply here; screens should use `zynaNavigationController`

### Chat routes and resident content

`ChatRouteViewController` is the stable stack entry for a room. Its child
`ChatViewController` owns the expensive content and can be recreated. Use
`chatRoomIdentifier` to find routes and `materializedChat()` when an action
needs their content; do not cast navigation stack entries to a chat controller.

Opening another chat from a person card or the forwarding picker preserves
the Back route. Opening a room already in the stack returns to that entry.
Forwarding installs its preview after the picker closes and any pop finishes.
Cross-tab routing still belongs to `MainCoordinator`.

The navigation controller keeps the nearest two chat contents resident.
Older entries retain session state: a message anchor and its viewport
distance, formatted input and selection, reply/edit/forward targets,
attachment drafts, and the search query/current result. They release their
SDK listeners, message window and Texture collection. Attachment payloads
belong to the draft and remain retained; this is a bound on chat contents,
not on the total bytes of all drafts or non-chat screens.

Hidden resident chats coalesce presentation refreshes until they become
visible. Departure resolves the visible-message debounce and flushes the
pending read receipt. That request retains only its SDK timeline until it
finishes, so unloading the chat cannot discard an already viewed target.
Restoring an older chat reads a bounded window around its event
off-main, falling back near the saved timestamp if the event has disappeared.
Factories are scoped to the account session. Routes are not persisted across
app restarts. A Back history menu can later use these stable entries.

Interactive cancellation preserves residency and route state. Stack mutations
requested during a transition wait for its completion. Deep pops materialize
the destination before the transition; afterward the preceding chat is warmed.

### Cross-tab navigation

Cross-tab flows should not chain a visible tab switch plus a visible push.

Instead:

1. Prepare the destination stack off the normal visible path.
2. Run a root-level transition through `CrossStackTransitionCoordinator`.
3. Leave the destination tab as the real final state after the handoff finishes.

Current production use:

- `Contacts -> Chat`
- `Calls history -> Chat + Call`

### Cross-stack transition rules

The working handoff is:

- source screen as a bitmap snapshot
- destination chat as a live view
- both mounted inside a temporary overlay that lives inside `tabBarController.view`

This matters because:

- mounting the live destination outside the tab bar controller breaks child VC hierarchy rules
- keeping the destination live avoids the "gray placeholder then content pops in later" problem
- keeping the source as a snapshot avoids mutating the source stack before the animation finishes

### Known constraints

- If a flow needs a seamless cross-stack transition, add it at the `MainCoordinator` level.
- Do not try to fake these flows with delayed `select tab -> push` sequences.
- Do not move child controller views outside their owning parent view hierarchy.
- If a transition needs glass to track moving chrome, prefer live destination views over early destination snapshots.
- Keep route naming honest: use `routeTo...` for root-level routing decisions and reserve plain `push/pop/show` for local stack actions.

### Current mental model

- one tab = one state container
- one navigation controller = one stack owner
- one cross-stack handoff = one temporary overlay orchestrated above both states
