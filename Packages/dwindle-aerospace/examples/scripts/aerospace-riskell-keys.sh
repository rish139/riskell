#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title AeroSpace: riskell keys
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName AeroSpace
# @raycast.icon ⌨️
# @raycast.description Puts AeroSpace in the riskell mode again, the keys riskell acts on. riskell does this itself when it starts; this is for after the plain keys script, without restarting riskell.

AS=$(command -v aerospace || echo /opt/homebrew/bin/aerospace)
"$AS" mode riskell && echo "AeroSpace is on the riskell keys"
