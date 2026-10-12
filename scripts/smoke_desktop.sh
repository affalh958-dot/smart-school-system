#!/bin/bash
# اختبار تشغيل برنامج سطح المكتب فعلياً (بلا واجهة رسومية) والتقاط لقطة شاشة.
export PATH=$PATH:/home/openhands/tools/flutter/bin
BIN=/workspace/project/app/build/linux/x64/debug/bundle/school_app
pkill -f "Xvfb :99" 2>/dev/null
sleep 1
Xvfb :99 -screen 0 1400x900x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
sleep 2
DISPLAY=:99 "$BIN" > /tmp/app_run.log 2>&1 &
APP_PID=$!
sleep 12
DISPLAY=:99 import -window root /tmp/school_app_shot.png 2>/dev/null || DISPLAY=:99 xwd -root -out /tmp/school_app_shot.xwd 2>/dev/null
kill $APP_PID 2>/dev/null
echo "=== app log (tail) ==="
tail -30 /tmp/app_run.log
echo "=== screenshot ==="
ls -la /tmp/school_app_shot.* 2>/dev/null
