#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title AeroSpace: plain keys
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName AeroSpace
# @raycast.icon ⌨️
# @raycast.description Reloads the AeroSpace config and puts it in its main mode, the keys that work without riskell. Use it if riskell has died and the move arrows or ctrl-alt-r do nothing.

AS=$(command -v aerospace || echo /opt/homebrew/bin/aerospace)
"$AS" reload-config --no-gui >/dev/null 2>&1
"$AS" mode main && echo "AeroSpace is on the plain keys"
