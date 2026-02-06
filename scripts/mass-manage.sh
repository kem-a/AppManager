#!/bin/bash
# Mass install/uninstall apps using app-manager

VERSION="1.0.0"
AUTHOR="kem-a"
SCRIPT_NAME=$(basename "$0")

# Default values
ACTION=""
APPS_DIR=""

show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION
Author: $AUTHOR

Mass install or uninstall apps using app-manager.

Usage: $SCRIPT_NAME -i|-u <path> [options]

Actions:
  -i, --install     Install all apps from the specified directory
  -u, --uninstall   Uninstall all apps from the specified directory
                    (AppManager will be skipped)

Options:
  -h, --help        Show this help message and exit
  -v, --version     Show version information

Examples:
  $SCRIPT_NAME -i ~/Temp              Install all apps from ~/Temp
  $SCRIPT_NAME --install ~/Downloads  Install all apps from ~/Downloads
  $SCRIPT_NAME -u ~/Applications      Uninstall all apps from ~/Applications
  $SCRIPT_NAME --uninstall ~/Apps     Uninstall all apps from ~/Apps
EOF
}

show_version() {
    echo "$SCRIPT_NAME v$VERSION"
    echo "Author: $AUTHOR"
}

install_apps() {
    local dir="$1"
    
    echo "Scanning $dir for apps to install..."
    echo ""

    local count=0
    for app in "$dir"/*; do
        if [ -f "$app" ]; then
            appname=$(basename "$app")
            echo "Installing: $appname"
            app-manager install "$app"
            ((count++))
        fi
    done

    echo ""
    echo "Done! Installed $count app(s)."
}

uninstall_apps() {
    local dir="$1"
    
    echo "Scanning $dir for apps to uninstall..."
    echo "AppManager will be skipped."
    echo ""
    
    # Count apps to be uninstalled (excluding AppManager)
    local app_count=0
    for app in "$dir"/*; do
        if [ -f "$app" ]; then
            appname=$(basename "$app")
            if [[ "${appname,,}" != *"appmanager"* ]]; then
                ((app_count++))
            fi
        fi
    done
    
    if [ "$app_count" -eq 0 ]; then
        echo "No apps found to uninstall."
        exit 0
    fi
    
    # Warning prompt
    echo "WARNING: This will uninstall $app_count app(s) from $dir"
    read -p "Are you sure you want to continue? [y/N]: " confirm
    
    if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    echo ""

    local count=0
    for app in "$dir"/*; do
        if [ -f "$app" ]; then
            appname=$(basename "$app")
            
            # Skip AppManager (case-insensitive match)
            if [[ "${appname,,}" == *"appmanager"* ]]; then
                echo "Skipping: $appname"
                continue
            fi
            
            echo "Uninstalling: $appname"
            app-manager uninstall "$app"
            ((count++))
        fi
    done

    echo ""
    echo "Done! Uninstalled $count app(s)."
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -i|--install)
            ACTION="install"
            shift
            if [[ -n "$1" && ! "$1" =~ ^- ]]; then
                APPS_DIR="$1"
                shift
            fi
            ;;
        -u|--uninstall)
            ACTION="uninstall"
            shift
            if [[ -n "$1" && ! "$1" =~ ^- ]]; then
                APPS_DIR="$1"
                shift
            fi
            ;;
        *)
            if [[ -z "$APPS_DIR" && ! "$1" =~ ^- ]]; then
                APPS_DIR="$1"
            else
                echo "Error: Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$ACTION" ]; then
    echo "Error: No action specified. Use -i for install or -u for uninstall."
    echo "Use --help for usage information."
    exit 1
fi

if [ -z "$APPS_DIR" ]; then
    echo "Error: No directory path specified."
    echo "Use --help for usage information."
    exit 1
fi

# Expand tilde in path
APPS_DIR="${APPS_DIR/#\~/$HOME}"

if [ ! -d "$APPS_DIR" ]; then
    echo "Error: Directory $APPS_DIR does not exist"
    exit 1
fi

# Execute the action
case "$ACTION" in
    install)
        install_apps "$APPS_DIR"
        ;;
    uninstall)
        uninstall_apps "$APPS_DIR"
        ;;
esac
