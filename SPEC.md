# Post Sorter

Photograph a letter or bill and get what you need to do, by when, with a reminder.

## Problem

Paper post still carries deadlines: bills, renewals, parking fines, school forms, NHS appointments, council tax. People leave letters in a pile, miss the date and pay late fees or lose a cheaper renewal. Scanner apps capture the page and to-do apps hold the task, but nothing reads the letter and turns it into the action and deadline. Mail is sensitive, so sending it to a cloud service is a real objection.

## Features (1.0)

- Scan one or more pages with the system document camera (VisionKit VNDocumentCameraViewController), or import a photo or PDF
- Read the text on the phone with Vision text recognition (accurate level, language correction on)
- On iOS 26 with Apple Intelligence available, extract fields with the on-device Foundation Models framework using a @Generable struct: sender, document type (bill, renewal, fine, appointment, tax, school, bank, medical, other), one-line summary, the action to take, due date, amount and currency, reference number. Guard it with #if canImport(FoundationModels) and if #available(iOS 26, *), and check SystemLanguageModel.default.availability
- Fallback when the model is unavailable or fails: NSDataDetector dates plus regex for money amounts and reference numbers, choosing the most likely due date by nearby words such as 'by', 'before', 'due', 'payment date'. The app works fully without Apple Intelligence
- Review screen after every scan: every field editable, the due date with a date picker, the page images shown above; nothing is saved until the user taps Save
- Local notification reminders: on the due date morning and a configurable number of days before (default 3); optional Add to Calendar via EventKit write-only access
- Home screen: 'To do' grouped Overdue, This week, Later, with a swipe to mark done; 'Filed' archive of done and no-action letters; search across sender, summary, reference and the full recognised text
- Letter detail: page images full screen with zoom, the recognised text, share as PDF, mark done or undo
- Senders remembered: when a new letter matches a previous sender, prefill its type
- Everything stays on the phone: SwiftData store, images as files in the app container, no network calls except the optional feedback note from Settings; optional Face ID lock

## Non-goals

- No server, accounts, cloud OCR or third-party AI
- No in-app purchases in 1.0
- No widgets in 1.0 (would need an app group and a second bundle ID)
- No iCloud sync or household sharing in 1.0
- No paying bills or contacting senders

## Evidence of demand

