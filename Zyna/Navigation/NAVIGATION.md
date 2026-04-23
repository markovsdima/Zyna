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
