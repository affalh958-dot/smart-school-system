#!/bin/bash
# تشغيل شاشة سطح المكتب الافتراضية + جسر VNC→Web لعرض التطبيق الأصلي في المتصفح.
pkill -f "Xvfb :99" 2>/dev/null
pkill x11vnc 2>/dev/null
pkill websockify 2>/dev/null
sleep 1
Xvfb :99 -screen 0 1400x900x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
sleep 2
DISPLAY=:99 x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -quiet > /tmp/x11vnc.log 2>&1 &
sleep 2
websockify --web=/usr/share/novnc 12000 localhost:5900 > /tmp/websockify.log 2>&1 &
sleep 3
echo "== procs =="
ps aux | grep -E "Xvfb :99|x11vnc|websockify" | grep -v grep | awk '{print $11,$12,$13,$14}'
echo "== http check =="
timeout 5 curl -sI http://localhost:12000/vnc.html | head -1
