#!/bin/sh

# Function to flash a display using Lunar
flash_display() {
    local serial=$1
    
    # Get initial brightness with a small delay to ensure stable reading
    sleep 0.2
    original_brightness=$(lunar displays "$serial" brightness --read | grep 'brightness:' | awk '{print $2}')
    
    # Validate captured brightness
    if [ -z "$original_brightness" ] || ! [ "$original_brightness" -eq "$original_brightness" ] 2>/dev/null; then
        original_brightness=50
        echo "Warning: Could not get original brightness, will restore to 50%"
    fi
    
    # Flash sequence with forced synchronization
    lunar displays "$serial" brightness 0 >/dev/null 2>&1
    sleep 0.7
    lunar displays "$serial" brightness 100 >/dev/null 2>&1
    sleep 0.7
    lunar displays "$serial" brightness 0 >/dev/null 2>&1
    sleep 0.7
    lunar displays "$serial" brightness 100 >/dev/null 2>&1
    sleep 0.7
    
    # Restore with verification
    lunar displays "$serial" brightness "$original_brightness" >/dev/null 2>&1
    sleep 0.5
    
    # Verify final state
    current_brightness=$(lunar displays "$serial" brightness --read | grep 'brightness:' | awk '{print $2}')
    if [ "$current_brightness" != "$original_brightness" ]; then
        lunar displays "$serial" brightness "$original_brightness" >/dev/null 2>&1
    fi
}

echo "Display Mapping Guide:"
echo "====================="

# Store display info in temporary files
lunar displays > /tmp/lunar_displays.txt

# First, list all displays
while IFS= read -r line; do
    case "$line" in
        [0-9]*)
            current_display="${line#*: }"
            echo "\nDisplay: $current_display"
            ;;
        *"EDID Name:"*)
            edid_name="${line#*EDID Name: }"
            edid_name="$(echo "$edid_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            echo "EDID Name: $edid_name"
            ;;
        *"Serial:"*)
            serial="${line#*Serial: }"
            serial="$(echo "$serial" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            echo "Serial: $serial"
            echo "---------------------"
            ;;
    esac
done < /tmp/lunar_displays.txt

echo "\nIdentification Phase:"
echo "====================="

# Arrays to store display info
rm -f /tmp/displays.txt /tmp/edids.txt /tmp/serials.txt
display_count=0

while IFS= read -r line; do
    case "$line" in
        [0-9]*)
            current_display="${line#*: }"
            display_count=$((display_count + 1))
            echo "$current_display" >> /tmp/displays.txt
            ;;
        *"EDID Name:"*)
            edid_name="${line#*EDID Name: }"
            edid_name="$(echo "$edid_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            echo "$edid_name" >> /tmp/edids.txt
            ;;
        *"Serial:"*)
            serial="${line#*Serial: }"
            serial="$(echo "$serial" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            echo "$serial" >> /tmp/serials.txt
            ;;
    esac
done < /tmp/lunar_displays.txt

# Process each display for identification
i=1
while [ $i -le $display_count ]; do
    edid=$(sed -n "${i}p" /tmp/edids.txt)
    serial=$(sed -n "${i}p" /tmp/serials.txt)
    
    echo "\nIdentify monitor:"
    echo "EDID Name: $edid"
    echo "Serial: $serial"
    printf "Flash this display? (Y/n): "
    read -n 1 answer
    echo # New line after keypress
    
    case "$answer" in
        [Yy]|"")
            echo "Flashing display... (watch for the screen that flashes)"
            flash_display "$serial"
            ;;
        *)
            echo "Skipped identification"
            ;;
    esac
    
    i=$((i + 1))
done

# Cleanup
rm -f /tmp/lunar_displays.txt /tmp/displays.txt /tmp/edids.txt /tmp/serials.txt
