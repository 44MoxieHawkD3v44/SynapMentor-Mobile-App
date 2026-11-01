# Android app: face verification fails because photos are too large

**For:** Flutter developer (SynapMentor Android app)
**Priority:** High. Android users cannot complete face verification.
**Date found:** 22 Oct 2026
**Backend changes needed:** None. This fix is entirely in the app.

---

## The issue

On **Face Verification**, the user completes the face challenge, but the submit fails with the generic error:

> **Verification submission failed. Please try again.**

Every retry fails the same way. The same flow works in the web app.

**Cause:** the app sends the face photos at the camera's full resolution, which makes the upload far larger than the server can process.

Measured on a real Android submit (22 Oct 2026):

| | Android app now | Required |
|---|---|---|
| Total photo data in one submit | **~5.4 MB** | **≤ 2.5 MB** |
| Average size per photo | **~270 KB** | **~50–120 KB** |

## What needs to be solved

1. **Capture at a lower camera resolution.** Use medium (about 480p) for the face screens instead of high or max.
2. **Shrink every photo to at most 640 pixels wide** before upload:
   - Keep the aspect ratio.
   - Don't enlarge photos that are already smaller.
   - Save them as JPEG at quality 80–85.
3. **Keep the whole submit at 2.5 MB or less:**
   - Send between 5 and 20 photos.
   - Each photo must be 500 KB or less.
   - If more than 20 frames are captured, send 20 evenly spaced ones.
4. **Do the shrinking in the background** so the camera screen doesn't freeze.
5. **Apply it to every screen that uploads face photos:**
   - Seeker face verification
   - Solver face verification
   - Session lobby face check (seeker and solver)
   - Face re-check (seeker and solver)
6. **Keep the error messages generic.** Don't show photo-size or other technical errors to the user. Keep the existing "Verification submission failed. Please try again." message.
7. **On retry, start a new face challenge.** Don't resubmit the old one.

## What does not change

- **Request format:** the same endpoints and field names.
- **Server rules:** 5–20 photos, JPEG only, each photo ≤ 500 KB.
- **Error messages:** the existing generic messages stay.

## Done when

- Face verification succeeds on a phone with a high-resolution front camera (1080p or better), for both seeker and solver.
- Each photo is **≤ 640px wide**, and the whole submit is **≤ 2.5 MB**.
- The session lobby face check also passes on the same phone.
