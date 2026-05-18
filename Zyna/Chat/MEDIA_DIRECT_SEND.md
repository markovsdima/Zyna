# Media Direct Send

This document describes Zyna's direct durable media-send architecture.

Media uses the same durable outgoing model as text: Zyna stores outgoing intent
and transaction ids, while Matrix Rust SDK owns E2EE media encryption, upload,
typed event construction, room-event encryption, transport, and server accept.

## Decision

Zyna does not build encrypted media event JSON by hand in Swift.

For encrypted rooms, Matrix media events need the correct encrypted `file` and
`thumbnail_file` fields, keys, IVs, hashes, mimetype behavior, thumbnail info,
caption fields, reply relations, voice/audio fields, dimensions, blurhash, and
foreign-client-compatible message shapes. That remains SDK/Ruma work.

Zyna owns:

- durable local outgoing records;
- app-owned local media copies;
- Matrix transaction ids;
- retry policy;
- event-id binding;
- sender-side UI state.

## Split Upload And Send

The Matrix Rust SDK fork exposes split upload/send helpers for composer media:

```swift
Room.uploadImageForEvent(...) -> uploadedImageJson
Room.sendUploadedImageWithTransactionIdReturningEventId(...) -> eventId

Room.uploadVideoForEvent(...) -> uploadedVideoJson
Room.sendUploadedVideoWithTransactionIdReturningEventId(...) -> eventId

Room.uploadFileForEvent(...) -> uploadedFileJson
Room.sendUploadedFileWithTransactionIdReturningEventId(...) -> eventId

Room.uploadVoiceForEvent(...) -> uploadedVoiceJson
Room.sendUploadedVoiceWithTransactionIdReturningEventId(...) -> eventId
```

The uploaded JSON is opaque to Swift. Zyna persists it and gives it back to the
SDK for event send. This lets retry resume from the send step after a successful
upload instead of uploading the same bytes again.

Known residual edge: if the app crashes after upload succeeds but before Zyna
saves the uploaded JSON, retry will upload again and may leave an orphan media
blob on the media repository. Once the uploaded JSON is saved, restart resumes
from event send and does not re-upload.

## Implemented Kinds

### Images

Main pieces:

- `DirectRawMediaSender`
- `PendingDirectImageService`
- `OutgoingImageOutboxService`
- `ChatViewModel.sendSingleImage`
- `ChatViewModel.sendImageBatch`

Zyna stores protected app-owned original and thumbnail files, dimensions,
mimetype, blurhash, caption metadata, and one transaction id per image item.
Single photos and grouped photos use the same image outbox.

Photo groups are not Matrix-native galleries. They are multiple normal image
events with Zyna media-group tags. This keeps other Matrix clients safe: they
see individual images and captions even if they do not understand the grouping.
Future Matrix gallery work is tracked in `MEDIA_GALLERY_MSC4274.md`.

### Videos

Main pieces:

- `PendingDirectVideoService`
- `OutgoingVideoOutboxService`
- `ChatViewModel.sendSingleVideo`

The video outbox persists the protected video file, thumbnail, dimensions,
duration, blurhash, mimetype, uploaded video JSON, transaction id, and returned
event id.

For encrypted video, the SDK fork avoids reading the original file into a Swift
or FFI-owned `Data` buffer before upload. The SDK encryption/upload layer still
buffers encrypted payload internally; true streaming upload is a separate SDK
project.

### Files

Main pieces:

- `PendingDirectFileService`
- `OutgoingFileOutboxService`
- `ChatViewModel.sendOutgoingFile`

Zyna stores a protected app-owned copy of the selected file and preserves the
user-visible filename separately. Binding must use transaction id and event id,
not filename equality: SDK/Matrix clients may normalize or change media names.

### Voice

Main pieces:

- `PendingDirectVoiceService`
- `OutgoingVoiceOutboxService`
- `ChatViewModel.sendOutgoingVoice`

Voice sends persist the recorded audio file, duration, waveform, mimetype,
voice marker metadata, uploaded voice JSON, transaction id, and returned event
id.

### Forwarded Media

Forwarded media uses by-reference resend instead of download and reupload.

Main pieces:

- `PendingForwardedMediaService`
- `OutgoingForwardedMediaOutboxService`
- `ChatViewModel.sendOutgoingForwardedMedia`
- `Room.sendMessageTypeWithTransactionIdReturningEventId`

Zyna stores the original `MediaSource` JSON and typed metadata, rebuilds a typed
SDK `MessageType`, sends it with a stable transaction id, and binds the returned
event id to the outgoing envelope.

For Zyna's all-E2EE product model, the intended happy path is encrypted source
media forwarded into an encrypted target room. The new room event is encrypted
for the target room, while the existing encrypted media blob and key metadata
are reused by reference.

Plain-source-to-encrypted-target forwarding is not equivalent to fresh E2EE
media upload: the event is encrypted, but the referenced media bytes may already
be plain on the media repository. Use download-and-reupload if that policy ever
needs to become strict.

TODO: If Zyna ever supports forwarding media from plain Matrix rooms or external
plain media sources into encrypted rooms, do not use by-reference forwarding as
the strict E2EE path. Download the bytes and reupload through SDK encrypted media
upload so the media blob itself is encrypted, not only the new room event.

## Validation

The direct media path has been manually validated for:

- online send;
- encrypted rooms;
- group rooms;
- receiving in Zyna and Element;
- captions and Zyna formatted attributes where supported;
- replies;
- photo groups;
- repeated sends;
- offline send and network restore;
- offline send, app kill, relaunch, and network restore;
- crash after upload;
- crash after send accepted;
- event-id binding after sync.

Useful log filters:

```text
DirectRawImageTx
DirectRawVideoTx
DirectRawFileTx
DirectRawVoiceTx
DirectForwardMediaTx
```

Crash hooks:

```text
ZYNA_DIRECT_RAW_IMAGE_CRASH_POINT=after-upload
ZYNA_DIRECT_RAW_IMAGE_CRASH_POINT=after-send-accepted

ZYNA_DIRECT_RAW_VIDEO_CRASH_POINT=after-upload
ZYNA_DIRECT_RAW_VIDEO_CRASH_POINT=after-send-accepted

ZYNA_DIRECT_RAW_FILE_CRASH_POINT=after-upload
ZYNA_DIRECT_RAW_FILE_CRASH_POINT=after-send-accepted

ZYNA_DIRECT_RAW_VOICE_CRASH_POINT=after-upload
ZYNA_DIRECT_RAW_VOICE_CRASH_POINT=after-send-accepted

ZYNA_DIRECT_RAW_FORWARDED_MEDIA_CRASH_POINT=after-send-accepted
ZYNA_DIRECT_RAW_*_CRASH_DELAY_MS=250
```

These hooks are test-only and must not stay enabled in shared schemes.
