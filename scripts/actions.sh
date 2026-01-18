#!/bin/bash

light_on()
{
    if [ -n "${led_on}" ]; then
        echo "Led on" >> "$log/$multi_instanz.log"
        curl --connect-timeout 2  -H "Content-Type: application/json" -X POST "$led_on"
        sleep "$led_on_delay"
    fi
}

light_off()
{
    if [ "$gif_enable" = "0" ]; then
        if [ -n "${led_off}" ]; then
            sleep "$led_off_delay"
            curl --connect-timeout 2  -H "Content-Type: application/json" -X POST "$led_off"
            echo "LED off" >> "$log/$multi_instanz.log"
        fi
    fi
}

take_picture()
{
    if curl --output /dev/null --silent --fail -r 0-0  "$item"; then
        echo "Webcam$array link is working" >> "$log/$multi_instanz.log"

        rm "$DIR_TEL/picture/cam_new$array.jpg"
        curl -m 20 -o "$DIR_TEL/picture/cam_new$array.jpg" "$item"

        if identify -format '%f' "$DIR_TEL/picture/cam_new$array.jpg"; then
            echo "Jpeg$array file is okay" >> "$log/$multi_instanz.log"
            if [ ! -z "${rotate[$array]}" ]; then
                convert -quiet -rotate "${rotate[$array]}" "$DIR_TEL/picture/cam_new$array.jpg" "$DIR_TEL/picture/cam_new$array.jpg"
            fi
            if [ ! -z "${horizontally[$array]}" ]; then
                if [ "${horizontally[$array]}" = "1" ]; then
                    convert -quiet -flop "$DIR_TEL/picture/cam_new$array.jpg" "$DIR_TEL/picture/cam_new$array.jpg"
                fi
            fi
            if [ ! -z "${vertically[$array]}"  ]; then
                if [ "${vertically[$array]}" = "1" ]; then
                    convert -quiet -flip "$DIR_TEL/picture/cam_new$array.jpg" "$DIR_TEL/picture/cam_new$array.jpg"
                fi
            fi
        else
            echo "JPEG$array picture has an error" >> "$log/$multi_instanz.log"
            rm "$DIR_TEL/picture/cam_new$array.jpg"
            cp "$DIR_TEL/picture/cam_error.jpg" "$DIR_TEL/picture/cam_new$array.jpg"
        fi
    else
        echo "Webcam$array link has an error" >> "$log/$multi_instanz.log"
        cp "$DIR_TEL/picture/no_cam.jpg" "$DIR_TEL/picture/cam_new$array.jpg"
    fi
}

create_variables()
{
    # Add heater_generic chamber to Moonraker query
    print=$(curl -H "X-Api-Key: $api_key" -s "http://127.0.0.1:$port/printer/objects/query?print_stats&virtual_sdcard&display_status&gcode_move&extruder=target,temperature&heater_bed=target,temperature&heater_generic%20chamber=temperature,target")

    # Filename from print_stats
    print_filename=$(echo "$print" | grep -oP '(?<="filename": ")[^"]*')
    filename=$(echo $print_filename | sed -f $DIR_TEL/scripts/url_escape.sed)

    if [ -z "$filename" ]; then
        file=""
    else
        file=$(curl -H "X-Api-Key: $api_key" -s "http://127.0.0.1:$port/server/files/metadata?filename=$filename")
    fi

    # Print durations
    print_duration=$(echo "$print" | grep -oP '(?<="print_duration": )[^,]*')
    total_duration=$(echo "$print" | grep -oP '(?<="total_duration": )[^,]*')

    # Get progress directly from virtual_sdcard
    progress_raw=$(echo "$print" | grep -oP '"virtual_sdcard":\s*{[^}]*"progress":\s*([0-9.]+)' | grep -oP '([0-9.]+)$')
    if [ -z "$progress_raw" ] || [ "$progress_raw" = "null" ]; then
        progress_raw="0"
    fi
    if ! [[ "$progress_raw" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        progress_raw="0"
    fi
    progress=$progress_raw

    # Printer state
    print_state_read1=$(echo "$print" | grep -oP '(?<="state": ")[^"]*')

    # Extruder temperatures
    extruder=$(echo "$print" | grep -oP '(?<="extruder": {)[^}]*')
    extruder_target=$(echo "$extruder" | grep -oP '(?<="target": )[^,]*')
    extruder_temp1=$(echo "$extruder" | grep -oP '(?<="temperature": )[^,]*')
    extruder_temp=$(printf %.2f $extruder_temp1)

    # Heater bed temperatures
    heater_bed=$(echo "$print" | grep -oP '(?<="heater_bed": {)[^}]*')
    bed_target=$(echo "$heater_bed" | grep -oP '(?<="target": )[^,]*')
    bed_temp1=$(echo "$heater_bed" | grep -oP '(?<="temperature": )[^,]*')
    if [ "$bed_temp1" != "null" ]; then
        bed_temp=$(printf %.2f $bed_temp1)
    fi

    # Chamber temperatures
    chamber_block=$(echo "$print" | grep -oP '(?<="heater_generic chamber": {)[^}]*')
    if [ -n "$chamber_block" ]; then
        chamber_temp1=$(echo "$chamber_block" | grep -oP '(?<="temperature": )[^,]*')
        if [ "$chamber_temp1" != "null" ] && [ -n "$chamber_temp1" ]; then
            chamber_temp=$(printf %.2f $chamber_temp1)
        else
            chamber_temp="N/A"
        fi
        chamber_target=$(echo "$chamber_block" | grep -oP '(?<="target": )[^,]*')
        if [ "$chamber_target" = "null" ] || [ -z "$chamber_target" ]; then
            chamber_target="N/A"
        fi
    else
        chamber_temp="N/A"
        chamber_target="N/A"
    fi

    # Z Height from gcode_position (always available)
    z_current="N/A"
    gcode_position=$(echo "$print" | grep -oP '(?<="gcode_position": )[^"]*')
    if [ -n "$gcode_position" ]; then
        gcode_position="${gcode_position// /}"
        IFS=',' read -r -a array <<< "$gcode_position"
        z_current=$(echo "${array[2]}")
    fi

    # Layer info from print_stats (reliable source)
    current_layer="N/A"
    layers="N/A"
    current_layer_raw=$(echo "$print" | grep -oP '"current_layer":\s*([0-9]+)' | head -1 | cut -d: -f2)
    total_layer_raw=$(echo "$print" | grep -oP '"total_layer":\s*([0-9]+)' | head -1 | cut -d: -f2)

    if [ -n "$current_layer_raw" ] && [ "$current_layer_raw" != "null" ]; then
        current_layer=$current_layer_raw
    fi
    if [ -n "$total_layer_raw" ] && [ "$total_layer_raw" != "null" ]; then
        layers=$total_layer_raw
    fi

    # Remaining time calculations
    if [ "$print_duration" = "0.0" ] || [ "$(echo "$progress <= 0.001" | bc -l)" -eq 1 ]; then
        math2="0"
        math4="0"
        math8="0"
    else
        math1=$(echo "scale=10; $print_duration / $progress" | bc -l)
        math2=$(echo "scale=0; $math1 - $print_duration" | bc -l)

        math3=$(echo "scale=10; $total_duration / $progress" | bc -l)
        math4=$(echo "scale=0; $math3 - $print_duration" | bc -l)

        math5=$(echo "scale=10; ($total_duration + $print_duration) / 2" | bc -l)
        math6=$(echo "scale=10; $math5 / $progress" | bc -l)
        math8=$(echo "scale=0; $math6 - $math5" | bc -l)
    fi

    remaining=$(printf "%.0f" $math2)
    print_remaining=$(printf '%02d:%02d:%02d' $(($remaining/3600)) $(($remaining%3600/60)) $(($remaining%60)))

    remaining1=$(printf "%.0f" $math4)
    total_remaining=$(printf '%02d:%02d:%02d' $(($remaining1/3600)) $(($remaining1%3600/60)) $(($remaining1%60)))

    remaining2=$(printf "%.0f" $math8)
    calculate_remaining=$(printf '%02d:%02d:%02d' $(($remaining2/3600)) $(($remaining2%3600/60)) $(($remaining2%60)))

    # Format current times
    current=$(printf "%.0f" $print_duration)
    print_current=$(printf '%02d:%02d:%02d' $(($current/3600)) $(($current%3600/60)) $(($current%60)))

    current1=$(printf "%.0f" $total_duration)
    total_current=$(printf '%02d:%02d:%02d' $(($current1/3600)) $(($current1%3600/60)) $(($current1%60)))

    # Format progress percentage
    print_progress1=$(echo "scale=1; $progress * 100" | bc -l 2>/dev/null)
    if [ -z "$print_progress1" ]; then
        print_progress1="0.0"
    fi
    print_progress=$(printf "%.1f" $print_progress1)%
}
