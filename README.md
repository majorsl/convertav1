# converthevc
 A script that will convert a variety of video formats to AV1 MKV files. Call the script with a trailing directory path and it will process the items in that location.

 The script supports NVENC and VAAPI but your hardwave needs to explictly support AV1 encoding, if not, the script falls back to software encoding which will take an unreasonable amount of time and likely max your CPU.  This is not advised.

*Process*

When processing files, the changes are written to a temp file. Upon success, the original file is removed and replaced with the updated .mkv version.

The script will pause if another instances of itself is running. If the script pauses, the script is probably running from another call. It will wait until that completes before processing files. This is for automations where the script may be called multiple times from another script or binary and will keep the processor from getting overwhlmed with conversions.

Generally, if it is a video file and supported by ffmpeg a conversion will be attempted. Known formats/file types I've encountered so far that were successful: 3gp asf avc avi flv h264 mkv m4v mov mp4 mpg mpeg webm wmv

When complete it will give a summary of its work.

📋 Totals:
 - ✅ Converted successfully: 8
 - 🔁 Skipped (already AV1): 136
 - ❌ Failed conversions: 0
 - 📈 Increased file size: 0
 - 💾 Total space saved: 1.45 GB

*Requires ffmpeg.

Note: the script skips files encoded with HEVC since those are already highly compressed and the video quality would likely suffer with conversion, plus the space savings gained would be minor.
