---
title: Attachments
description: "Attachment metadata, resolved paths, and optional model-friendly conversion for CAF audio and GIF images."
---

`imsg` reports attachment metadata only. It never copies, modifies, or uploads the underlying files. Optional conversion exposes cached, model-friendly variants for CAF audio and GIF images.

## Reading attachments

```bash
imsg history --chat-id 42 --attachments --json
imsg watch   --chat-id 42 --attachments --json
```

Every message JSON object contains an `attachments` array. CLI `history` and
`watch` JSON preserve their historical behavior of populating attachment
metadata even without `--attachments`; that flag controls human-readable
display. RPC read methods populate the array only when their documented
`attachments` flag is true. Otherwise it is empty. Per-attachment fields:

| Field | Type | Notes |
|-------|------|-------|
| `filename` | string | Stored filename inside Messages' attachments dir. |
| `transfer_name` | string | Original filename as sent. |
| `uti` | string | Apple Uniform Type Identifier. |
| `mime_type` | string | Best-effort MIME from UTI. |
| `total_bytes` | int | Size in bytes. |
| `is_sticker` | bool | True for sticker-pack attachments. |
| `missing` | bool | True when the file couldn't be located on disk. |
| `original_path` | string | Resolved absolute path under `~/Library/Messages/Attachments/`. |
| `converted_path` | string | Set only with `--convert-attachments`; see below. |
| `converted_mime_type` | string | Set only with `--convert-attachments`. |

When an attachment is referenced in `chat.db` but the underlying file has been pruned (Messages can age out big files), `missing` is `true` and `original_path` may be empty.

## Converted variants

```bash
imsg history --chat-id 42 --attachments --convert-attachments --json
imsg watch   --chat-id 42 --attachments --convert-attachments --json
```

This adds `converted_path` and `converted_mime_type` to attachments where conversion is supported:

- **CAF audio → M4A.** Messages' on-device voice memos are stored as CAF; most LLMs and downstream tools want M4A.
- **GIF image → first-frame PNG.** Useful when a static thumbnail is enough for downstream models.

Originals are never modified. Converted files live alongside in a cache directory and are reused on subsequent reads.

`--convert-attachments` requires `ffmpeg` on `PATH`. If `ffmpeg` is missing, the command still succeeds — `converted_path` is simply omitted from the output and the original metadata is unchanged.

`brew install ffmpeg` to enable.

## Sending attachments

```bash
imsg send --to "+14155551212" --file ~/Desktop/photo.jpg
imsg send --to "Jane Appleseed" --file ~/Desktop/voice.m4a
imsg send --chat-id 42 --file ~/Desktop/note.pdf
```

`--file` accepts any regular file. Audio files (`.m4a`, `.caf`, `.aiff`, …) ride the same code path as images and documents.

Before invoking AppleScript, `imsg` stages the file under `~/Library/Messages/Attachments/imsg/`. Messages reads attachments from inside its own attachments directory more reliably than from `~/Desktop` or `~/Downloads`, particularly under newer macOS sandboxing.

The staged copies live under `imsg/`, distinct from Messages' own subdirectories, and are not pruned automatically. Clear them periodically if disk space matters.

For bridge-backed threaded replies, use `send-rich --file` or
`send-attachment --reply-to`:

```bash
imsg send-rich --chat 'iMessage;-;+15551234567' \
  --reply-to <messageGuid> --text "here it is" --file ~/Desktop/photo.jpg
imsg send-attachment --chat 'iMessage;-;+15551234567' \
  --reply-to <messageGuid> --file ~/Desktop/photo.jpg
```

## Why not just copy or upload?

The CLI's contract is "read what's there, send what you give it." Anything beyond that — bulk archival, cloud upload, format conversion at rest — is left to callers, who know their retention and privacy requirements. The conversion feature is the one exception, and only because some receive-side formats (CAF, animated GIF) are awkward for downstream tools to handle.

If you want a full archive workflow, pipe `--attachments --json` through your own scripts and copy the files out of `~/Library/Messages/Attachments/` yourself.
