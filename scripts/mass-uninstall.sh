#!/bin/bash
# Mass uninstall all apps from ~/Applications except AppManager

APPS_DIR="$HOME/Applications"

if [ ! -d "$APPS_DIR" ]; then
    echo "Error: Directory $APPS_DIR does not exist"
    exit 1
fi

echo "Scanning $APPS_DIR for apps to uninstall..."
echo "AppManager will be skipped."
echo ""

count=0
for app in "$APPS_DIR"/*; do
    if [ -f "$app" ]; then
        appname=$(basename "$app")
        
        # Skip AppManager (case-insensitive match)
        if [[ "${appname,,}" == *"appmanager"* ]]; then
            echo "Skipping: $appname"
            continue
        fi
        
        echo "Uninstalling: $appname"
        # Pass the full path, not just the filename
        app-manager --uninstall "$app"
        ((count++))
    fi
done

echo ""
echo "Done! Uninstalled $count app(s)."
