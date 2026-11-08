# Independent 2.2.5 review fixes

These changes address the twelve reproduced findings from the independent review of
`88c9156e948ed9ddedee90023e157e04f32fcece`. They are local changes on
`codex/toolkit-225-review-fixes`; nothing has been pushed, published or deployed.

| Finding | Change | Regression evidence |
| --- | --- | --- |
| Fresh password directories inherited readable permissions | Migration creates both private directories before locking them. Every password-store save establishes a protected Windows ACL before writing, and stops if protection fails. | Fresh migration, ACL-before-encryption ordering, failed ACL leaves no password file. Windows ACL operations are mocked. |
| Legacy NvrFix sent passwords over HTTP | NvrHealth uses HTTPS for authentication and password-bearing requests, keeps HTTPS for subsequent requests, and refuses downgrade after TLS/timeout failures. Plain HTTP remains available only after an explicit connection refusal, with a warning. | HTTPS write and authenticated verification; TLS failure sends no HTTP retry. |
| Undo skipped a password changed just before interruption | Camera and recorder Undo reconcile attempted writes, including those whose verification result was never journaled, and resolve the working credential before restoring it. | Real FixSite processes are killed after a mock camera and recorder accept their passwords; real Undo restores both original passwords. |
| Recording repair could report success when verification failed | Every originally disabled track/device must appear enabled in the final readback. An empty or incomplete response fails verification. | Failed PUT followed by unreadable track list returns failure. |
| Live recorder retarget left camera associations stale | Preserve the original recorder identity and resolve camera associations from the verified recorder location before operations and when saving the site list. | Real FixSite moves a recorder to an alternate free address, changes the camera and channel passwords, and saves the verified address. |
| Full NVR serial containing `/` was rejected | Preserve complete serials in validation, matching and relay extraction; escape serials only when building local filenames. | Waiting list, inbox drop and matching with a complete NVR serial; relay lookup and extraction. |
| Multiple reset attachments were delivered to the wrong device | Each attachment has its own serial mapping and delivery receipt. Unidentifiable multiple attachments stay unmatched for manual handling. | Two devices on different PCs receive different bytes; retry/other-PC receipt checks; ambiguous files and expiry. |
| Update recovery required an intact main library | Load an independent recovery helper before ToolkitCore. Stage, hash and flush sibling temporary files, then atomically replace live files and journals. Stop startup if recovery fails. | Truncated core restored through the real launcher; failed recovery stops loading; interrupted copy preserves the live file. |
| No-git manifest included runtime customer data | Use the checked-in `tools/shipped-files.txt` inventory for source exports, rejecting missing or invalid inventory entries. | Export containing a customer backup produces a manifest containing only its listed release file. |
| Three test helpers nested JSON arrays on PowerShell 5.1 | Parse into a variable and enumerate its rows explicitly. | Run each real helper under the 5.1 array-emission rule, checking that fields from different rows cannot satisfy one filter. |
| SiteCheck assertions did not affect the suite exit code | Return the assertion failure count from the suite. | Inject a wrong parser into the real suite and check that its process exit matches its failures. |
| Offline site scan names collided after sanitizing | Queue filenames include the site's hash. Older filenames are removed only after the new scan is saved or sent, matching the site's JSON identity. | Two actual offline uploader runs preserve separate queues for `A B` and `A_B`. |

## Validation

Run from the repository root:

```powershell
pwsh -NoProfile -File tools/Run-AllTests.ps1 -Portable
node appsscript/tests/hikrelay.test.js
```

The portable runner explicitly skips Test-FixIt, Test-Toolkit and Test-NvrHealth,
which require a Windows desktop. Without `-Portable`, the runner still selects
every suite. The HikReset browser fixture is served over loopback HTTP so a
browser policy blocking `file://` URLs does not disable its portal checks.

Windows testing was skipped at the user's request. Linux tests simulate Windows
ACL/DPAPI operations and the PowerShell 5.1 JSON array rule; they do not validate
actual Windows ACL behavior. No real cameras, deployed relay, or site network
were changed or tested.

The rebuilt `version.json` must name the local code commit containing its exact
75 release files. Those commit URLs become available only after the branch is
pushed. This work does not publish an update or deploy the Apps Script relay.
