#!/bin/bash

# Get the directory and filename
DIR=$(dirname "${@: -1}")
FILE=$(basename "${@: -1}")
# Default params
HEIGHT=1
OGG=0
MP4=0
WEBM=0

# Go into the directory so the container will work locally
cd $DIR

args=`getopt h:omw $*`
# you should not use `getopt abo: "$@"` since that would parse
# the arguments differently from what the set command below does.
if [ $? != 0 ]; then
  echo 'Usage: encode.sh [options] video_path'
  exit 2
fi
set -- $args
# You cannot use the set command with a backquoted getopt directly,
# since the exit code from getopt would be shadowed by those of set,
# which is zero by definition.
for i; do
  case "$i" in
    -h)
      HEIGHT="$2"; shift;
      shift;;
    -o)
      OGG=1;
      shift;;
    -m)
      MP4=1;
      shift;;
    -w)
      WEBM=1;
      shift;;
    --)
      shift; break;;
  esac
done

if [ "$OGG" = "$WEBM" ] && [ "$OGG" = "$MP4" ]; then
  OGG=1; WEBM=1; MP4=1;
fi

# Temporarily install the actual encode script
# Gets "mounted into" the container with FFMPEG and tackles all the real encoding
cat <<'EOF' > encode-inner.sh
IN=$5
OUT=$(echo $5 | sed 's/^\(.*\)\.[a-zA-Z0-9]*$/\1/')
echo "--- Encoding: $5"

# We need to detect whether the video is rotated or not in order to
# set the "scale" factor correctly, otherwise we can hit a fatal error
# However, ffmpeg will automatically apply the rotation for us, so we
# just need to ensure the scale is right, not also apply rotation.
ROTATION=$(ffprobe $IN 2>&1 | \grep rotate | awk '{print $3}')
if [ "$ROTATION" == "" ]; then
    # No rotation, use normal scale
    if [ "$1" = 1 ]; then
      VF="scale=-1:ih"
    else
      VF="scale=-1:$1"
      echo "--- No rotation detected"
    fi
else
    # Rotated video; we need to specify the scale the other way around
    # to avoid a fatal "width not divisible by 2 (405x720)" error
    # Instead we'll use 
    if [ "$1" = 1 ]; then
      VF="scale=iw:-1"
    else
      VF="scale=$1:-1"
    fi
    echo "--- Rotation detected; changed scale param"
fi

# Sometimes you need to force this if, for example, your video is sideways but doesn't contain that meta data
if [ "$FORCE" == "1" ]; then
    echo "!!! Forced scale + rotation"
    if [ "$1" -eq 1 ]; then
      VF="scale=-1:ih,transpose=2"
    else
      VF="scale=-1:$1,transpose=2"
    fi
fi

# Count cores, more than one? Use many!
# Uses one less than total (recomendation for webm)
# Doesn't apply to x264 where 0 == auto (webm doesn't support that)
CORES=$(grep -c ^processor /proc/cpuinfo)
if [ "$CORES" -gt "1" ]; then
  CORES="$(($CORES - 1))"
fi

if [ "$3" = 1 ]; then
  echo "--- Using $CORES threads for webm"
  
  echo "--- webm, First Pass"
  ffmpeg -i $IN \
      -hide_banner -loglevel error -stats \
      -codec:v libvpx -threads $CORES -slices 4 -quality good -cpu-used 0 -b:v 1000k -qmin 10 -qmax 42 -maxrate 1000k -bufsize 2000k -vf $VF \
      -an \
      -pass 1 \
      -f webm \
      -y /dev/null
  
  echo "--- webm, Second Pass"
  ffmpeg -i $IN \
      -hide_banner -loglevel error -stats \
      -codec:v libvpx -threads $CORES -slices 4 -quality good -cpu-used 0 -b:v 1000k -qmin 10 -qmax 42 -maxrate 1000k -bufsize 2000k -vf $VF \
      -codec:a libvorbis -b:a 128k \
      -pass 2 \
      -f webm \
      -y ${OUT}_encoded.webm
fi

if [ "$2" = 1 ]; then
  
  echo "--- x264, First Pass"
  ffmpeg -i $IN \
      -hide_banner -loglevel error -stats \
      -codec:v libx264 -threads 0 -profile:v main -preset slow -b:v 1000k -maxrate 1000k -bufsize 2000k -vf $VF \
      -an \
      -pass 1 \
      -f mp4 \
      -y /dev/null
  
  echo "--- x264, Second Pass"
  ffmpeg -i $IN \
      -hide_banner -loglevel error -stats \
      -codec:v libx264 -threads 0 -profile:v main -preset slow -b:v 1000k -maxrate 1000k -bufsize 2000k -vf $VF \
      -codec:a libfdk_aac -b:a 128k \
      -pass 2 \
      -f mp4 \
      -y ${OUT}_encoded.mp4
fi

if [ "$4" = 1 ]; then
  echo "--- OGV, Single Pass"
  ffmpeg -i $IN \
      -hide_banner -loglevel error -stats \
      -codec:v libtheora -threads $CORES -q:v 7 -vf $VF \
      -codec:a libvorbis -b:a 128k \
      -f ogv \
      -y ${OUT}_encoded.ogv
fi
EOF

# Run the container. Note that we set the workingdir to /tmp since there are a few cruft files
# the two stage encoding produces that we don't want to leave around in `pwd`
docker run -t --rm \
  -e "FORCE=$FORCE"\
  -v `pwd`:/app \
  -w /tmp \
  --entrypoint='bash' \
  jrottenberg/ffmpeg \
  /app/encode-inner.sh $HEIGHT $MP4 $WEBM $OGG /app/${FILE}

# Remove that temp script
rm -f encode-inner.sh
