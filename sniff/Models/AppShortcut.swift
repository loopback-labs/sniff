import Foundation


/// Display catalog of Sniff's global hotkeys, for the Shortcuts tab in Settings.
///
/// Mirrors the bindings registered in `AppCoordinator.setupKeyboardShortcuts()` (plus the
/// always-on toggle bound in `init`) — update both together.
struct AppShortcut: Identifiable {
  let keys: String
  let title: String
  let detail: String

  var id: String { keys + title }

  struct Group: Identifiable {
    let name: String
    let shortcuts: [AppShortcut]
    var id: String { name }
  }

  static let all: [Group] = [
    Group(name: "Session", shortcuts: [
      AppShortcut(keys: "⌘⇧W", title: "Start / stop Sniff", detail: "Begins capture and shows the overlays."),
      AppShortcut(keys: "⌘⇧R", title: "Quit Sniff", detail: "Stops capture and exits the app."),
    ]),
    Group(name: "Ask", shortcuts: [
      AppShortcut(keys: "⌘⇧Q", title: "Solve what's on screen", detail: "Sends a screenshot to the model."),
      AppShortcut(keys: "⌘⇧A", title: "Answer detected question", detail: "Answers the latest question heard in the call."),
      AppShortcut(keys: "⌘⇧S", title: "Say next", detail: "Suggests what to say next."),
      AppShortcut(keys: "⌘⇧F", title: "Follow-up questions", detail: "Proposes follow-ups to ask."),
      AppShortcut(keys: "⌘⇧E", title: "Recap", detail: "Summarises the conversation so far."),
      AppShortcut(keys: "⌘⇧K", title: "Focus ask composer", detail: "Type a question straight into the overlay."),
    ]),
    Group(name: "Overlays", shortcuts: [
      AppShortcut(keys: "⌘⇧I", title: "Toggle click-through", detail: "Forces the overlays to stay interactive."),
      AppShortcut(keys: "⌥←  ⌥→", title: "Previous / next answer", detail: "Steps through answer history."),
      AppShortcut(keys: "⌥↑  ⌥↓", title: "First / last answer", detail: "Jumps to either end of the history."),
    ]),
  ]
}
