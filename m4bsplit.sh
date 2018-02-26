#!/bin/bash
# Author : <Ivan Zderadicka> ivan@zderadicka.eu
# License: MIT


VERSION="0.2.2"
BITRATE=32
CUTOFF=12000
SEGMENT_TIME=1800
COMMON_PARAMS="-nostdin -v error"

print_help () {
	cat << EOF
Splits large audiobook files into smaller parts which are then encoded with Opus codec.
Split points are either chapters defined in the audiobook or fixed size pieces.
Requires ffmpeg adn ffprobe version v >= 2.8.11
Supports input formats m4a, m4b, mp3, aax (mka should also work but not tested)

Usage: split_audiobook.sh [options] <audiobook>...

-h, --help			Shows this help
-v, --version		Prints version and exits
-r, --replace		Replace existing output directory
-q <quality>		
--quality <quality>	 Quality of the output - top (64kbps 48kHz), high (48kbps, 48kHz), 
						normal (32kbps, 24kHz), low (24kbps, 16kHz) [default: normal]
-l <secs>
--length <secs>		Lenght of piece in seconds (in case chapters are not defined) [default: $SEGMENT_TIME]
--activation_bytes <xxxxxxxx> 	Activation bytes required for aax format

EOF
}

for opt in "$@"; do
	case $opt in
		-h|--help)
			print_help
			exit
			;;
		-v|--version)
			echo Version: $VERSION
			exit
			;;
		-r|--replace)
			REPLACE_DIR=1
			;;
		-q|--quality)
			case $2 in
				high)
					BITRATE=48
					CUTOFF=20000
					;;
				top)
					BITRATE=64
					CUTOFF=20000
					;;
				low) 
					BITRATE=24
					CUTOFF=8000
					;;
				normal)
					;;
				*)
					echo Invalid quality param $2 >&2
					exit 1
					;;
			esac
			shift
			;;
		--activation_bytes)
			ACTIVATION_BYTES=$2
			shift
			;;
		-l|--length)
			SEGMENT_TIME=$2
			shift
			;;
		*)
			break
			;;
	esac
	shift
done

# For Opus
#ACODEC_PARAMS="-acodec libopus -b:a ${BITRATE}k -vbr on -compression_level 10 -application audio -cutoff $CUTOFF"

# Form MP3 (https://trac.ffmpeg.org/wiki/Encode/MP3)
ACODEC_PARAMS="-acodec libmp3lame -q:a 5"

temp_file=$(mktemp) || exit 1
trap "rm -f -- $temp_file" EXIT
trap "exit 2" SIGINT

wait_proc() {
	while (( $(jobs -pr | wc -l ) >= $(nproc) )); do
		sleep 1
	done
}

while [[ $# -gt 0 ]]; do
	echo Processing file $1
	if [[ ! -f "$1" ]]; then
		echo File $1 does not exists >&2
		shift
		continue
	fi
	ext=${1##*.}
	if [[ $ext = "aax" && ${#ACTIVATION_BYTES} != 8 ]]; then 
		echo "Activation bytes (4 bytes = 8 chars in hexa) are needed for aax file" >&2
		shift
		continue
	fi 
	
	if [[ -n "$ACTIVATION_BYTES" ]]; then 
		COMMON_PARAMS="-activation_bytes $ACTIVATION_BYTES $COMMON_PARAMS"
	fi

	ffprobe -v error -print_format compact=nokey=1 -show_chapters "$1" > $temp_file
	dirname=${1%.*}
	if [[ -n "$REPLACE_DIR" && -e "$dirname" ]]; then
		rm -r "$dirname"
	fi
	
	mkdir "$dirname"
	if [[ $? != 0 ]]; then
		echo "Directory $dirname exists or cannot be created" >&2
		shift
		continue
	fi
	num_chapters=$(wc -l < $temp_file)
	if [[ $num_chapters -gt 1 ]]; then
		count=0
		while IFS=\| read -r _ id _ _ start _ end chapter; do
			((count++))
			echo Processing chapter $count of $num_chapters
			{
			ffmpeg $COMMON_PARAMS -i "$1" -ss "$start" -to "$end" -vn $ACODEC_PARAMS\
			-metadata title="$chapter"\
			-metadata track="$count/$num_chapters"\
			"$dirname/Chapter `printf %02d $count`.mp3"
			if [[ $? -ne 0 ]]; then
				echo Error processing chapter $count of $num_chapters >&2
			else
				echo Finished chapter $count of $num_chapters
			fi
			 } &
		wait_proc

		done < $temp_file
	else
		echo "No chapters found"
		echo "Splitting file into pieces of $SEGMENT_TIME secs"
		# this works fine however title and track tags cannot be sent for each part 
		# ffmpeg $COMMON_PARAMS -i "$1"  -vn $ACODEC_PARAMS -f segment -segment_time $SEGMENT_TIME\
		# -reset_timestamps 1  "$dirname/%03d.opus"

		if [[ $ext = "m4b" ]]; then
			ext=m4a
		fi
		ffmpeg $COMMON_PARAMS -stats -i "$1"  -vn -acodec copy -f segment -segment_time $SEGMENT_TIME\
		-reset_timestamps 1  "$dirname/%03d.$ext"
		count=0
		num_files=$(ls -1q "$dirname" | wc -l)
		echo Done with file split - number of parts is $num_files
		for f in "$dirname/"*; do
			((count++))
			echo Processing part $count of $num_files
			{
			ffmpeg $COMMON_PARAMS -i "$f" $ACODEC_PARAMS -metadata track=$count/$num_files\
			 -metadata title="Part $(($count - 1))" "${f%.*}.opus"

			if [[ $? = 0 ]]; then
			 	rm "$f"
				echo Finished part $count of $num_files 
			else
				echo Error converting file $f >&2
			fi
			} &
			wait_proc
		done

	fi
		# try extract cover art
		ffmpeg $COMMON_PARAMS -i "$1" "$dirname/cover.jpg"
		

	shift
done
wait
exit

