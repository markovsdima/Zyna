# Rich Text Composer

The message composer supports bold, italic, underline, strikethrough, inline
monospace, explicit links, and removing formatting. It uses Texture's
`ASEditableTextNode` with UIKit editing, selection, and undo.

## Data Flow

1. [ComposerTextNode](Composer/ComposerTextNode.swift) owns the editing behavior.
   Its attributed text carries semantic styles alongside display attributes.
2. [ComposerText](../Messaging/ComposerText.swift) snapshots that text into a
   plain `body` and optional `formattedBody`. Serialization merges adjacent
   spans with the same style and link, regardless of font or color differences.
3. [ChatInputNode](Nodes/ChatInputNode.swift) trims outer whitespace when sending
   and passes the snapshot to [ChatViewModel](ChatViewModel.swift). The view
   model routes it to a new message, reply, or pending edit.
4. The [outgoing layer](OUTGOING_LAYER.md) persists both representations before
   transport. Text envelopes retain HTML for retries; pending edits retain
   `pendingEditBody` and `pendingEditFormattedBody` together. Local presentation
   uses the same pair while waiting for acceptance and sync.
5. [DirectRawTextSender](../Services/DirectRawTextSender.swift) builds Matrix
   content, adding reply fallbacks and Zyna metadata as needed. Edits put the
   replacement in `m.new_content`. Incoming HTML is read only when its format is
   `org.matrix.custom.html`.

The editor emits `<strong>`, `<em>`, `<u>`, `<del>`, `<code>`, `<a>`, and `<br>`.
An unformatted snapshot has no `formattedBody`; transport may still add HTML
for a reply or Zyna metadata. Text forwarding preserves accepted Matrix HTML,
and [ZynaHTMLCodec](../Messaging/ZynaHTMLCodec.swift) replaces the old Zyna
carrier attributes when applying the new forwarding metadata.

## Editor Contracts

- **Style is semantic.** `.zynaComposerStyle` stores `RichTextStyle` as an
  `NSNumber`; `.link` stores the destination separately. TextKit can replace a
  font with Apple Color Emoji or a CJK fallback. Reading style from that font
  would lose authoring intent. Font traits are only an import fallback for
  foreign attributed text that has no semantic attribute.
- **Texture keeps its text-view delegate.** Use `ASEditableTextNodeDelegate`
  for insertion and selection callbacks. Update both the node's cached
  `typingAttributes` and the underlying text view: Texture reapplies its cache
  after selection changes, and UIKit can change its own attributes in between.
- **Insertion follows the caret.** At a space or newline boundary, only styles
  shared by both sides continue. This ends formatting after a styled word while
  preserving an outer style inside a longer formatted phrase. A link continues
  across that boundary only when both destinations match.
- **Glass changes appearance only.** `updateForeground` updates stored text,
  typing attributes, and link appearance without resetting style or selection.
- **Undo retains attributed text.** Formatting registers the replaced range
  with UIKit's undo manager. Insertion-style updates are skipped during undo
  and redo. Setting a new editor document clears the previous undo history.
  Formatting actions are unavailable while marked text is being composed.

Opening an edit and sending it unchanged compares canonical composer snapshots,
not raw incoming HTML or font runs. This avoids false edits caused by equivalent
markup or fallback fonts. Link editing also checks a semantic snapshot before
applying its result, so a glass color change does not invalidate the operation.

## Clipboard

[ComposerClipboard](Composer/ComposerClipboard.swift) publishes ready bytes in
one `UIPasteboard.setItems` call. Formatted selections contain:

- Versioned `com.app.zyna.composer-text` JSON for Zyna-to-Zyna transfer.
- UTF-8 HTML for other applications, without a fixed font or foreground color.
- UTF-8 plain text as a fallback.

The custom type conforms to `public.data`, preventing its JSON from being
treated as text by other applications. UIKit supplies standard conversions,
including RTF; Zyna does not export a separate RTF representation. Publishing
ready data avoids a loader that needs the producer to remain running. Do not
add a second asynchronous clipboard write: replacing the item can invalidate
providers that a paste is already reading.

Texture creates the concrete text view internally. The clipboard hook installs
`copy:` and `cut:` overrides on that class and enables them only for composer
instances. Plain selections, marked text, and unrelated editors use native
actions. For a formatted cut, it writes once and calls
`replace(selectedTextRange, withText: "")`. This preserves a separate undo step;
`deleteBackward()` can group the cut with subsequent typing, while native Cut
would write to the clipboard again.

Message-menu and VoiceOver copy actions also use this exporter. Formatted
message text is parsed and serialized off the UI actor to remove reply fallbacks
and transport metadata. A generation counter and pasteboard `changeCount`
prevent this preparation from overwriting a newer copy.

[ComposerPasteLoader](Composer/ComposerPasteLoader.swift) tries representations
in this order, falling through when loading or decoding fails:

1. Zyna's versioned semantic payload.
2. RTF, then flat RTFD.
3. UIKit's `NSAttributedString` object loader, including HTML-only providers.

Notes can advertise rich formats while `loadObject` returns plain-looking text,
so concrete RTF data is requested first. `load` is explicitly `@concurrent` to
keep our decoding off the UI actor regardless of the target's Approachable
Concurrency setting; UIKit owns the fallback HTML import.

`ChatInputNode` handles a local attributed object directly. Plain-only providers
use UIKit's default paste path and inherit the current insertion style. Rich
imports are sanitized directly as attributed text: keep supported styles and
validated explicit links, replace foreign appearance with composer attributes,
and drop attachment runs. Image paste has a separate attachment flow.

## Whitespace and Links

Attributed-text import normalizes CRLF and CR to LF and retains other text
whitespace without an HTML round trip. Copy preserves edge whitespace; sending
trims it. Serialization uses nonbreaking spaces and `<br>` where HTML would
otherwise collapse text.
[MatrixRichTextParser](../Messaging/MatrixRichText.swift) restores exact body
whitespace only when every UTF-16 position matches the known substitutions,
keeping style and link ranges aligned. It never substitutes a different body
for an HTML label merely because their lengths match.

[ComposerLinkPrompt](Composer/ComposerLinkPrompt.swift) uses a placeholder for
the scheme, so pasting a complete URL does not duplicate `https://`. Bare hosts,
including `example.com:8443/path` and `localhost:8080`, receive `https://`.
Explicit `http://` and `https://` are preserved. `RichTextURLPolicy` accepts only
HTTP(S) destinations with a host. Automatically detected message links do not
become authored links when reopening the message in the composer.

## Scope and Verification

The composer edits inline formatting. It imports preformatted blocks as inline
monospace; it does not preserve editable block structure such as headings,
lists, or quotes. Media captions still use plain strings, including text passed
from this composer into an attachment preview. Foreign clipboard formats can
only preserve style information present in the imported representation.

Automated coverage lives in [ComposerTextTests](../../ZynaTests/ComposerTextTests.swift),
[MatrixRichTextTests](../../ZynaTests/MatrixRichTextTests.swift), and
[ZynaHTMLCodecTests](../../ZynaTests/ZynaHTMLCodecTests.swift). It covers real
editor and clipboard actions, fallback fonts, undo grouping, paste fallbacks,
whitespace, link normalization, wire content, and persistence. These tests do
not establish clipboard compatibility with every application or OS version.

After changing editor or clipboard behavior, check on a device:

1. Format mixed Latin/Cyrillic text, emoji, and CJK; toggle styles and type at
   word boundaries. Scroll to change the glass foreground, then keep typing.
2. Cut formatted text, type something else, and undo twice; redo both edits.
3. Paste rich text from Notes, copy from both the composer and a message menu,
   and paste into Notes and back. Include an app switch before pasting.
4. Paste a complete URL into the link prompt; also try a bare host with a port.
5. Send, reply, forward, and edit formatted text. Sending an unchanged edit
   should not produce an edit; removing formatting should persist. Exercise
   offline sending and retry to check the stored HTML path.
