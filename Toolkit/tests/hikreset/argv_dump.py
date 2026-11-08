# argv_dump.py - test helper (2.2.5 fix 8): writes the arguments it was started with (after the output path) as JSON, one list element per argument.
# Used to check that Join-HikArgs + Start-Process hand the browser exactly the arguments Get-HikBrowserArgs built (Windows and Linux).
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(sys.argv[2:], f)
