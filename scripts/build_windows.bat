@echo off
REM بناء برنامج الحاسوب الحقيقي لويندوز (exe) — يُشغّل مرة واحدة على جهاز ويندوز.
REM المتطلبات: Flutter SDK + Visual Studio 2022 مع "Desktop development with C++".
setlocal
cd /d "%~dp0\.."

echo === 1/4  جلب الحزم ===
call flutter pub get || goto :err

echo === 2/4  تحليل الكود ===
call flutter analyze || goto :err

echo === 3/4  الاختبارات ===
call flutter test || goto :err

echo === 4/4  بناء نسخة الويندوز (Release) ===
call flutter build windows --release || goto :err

echo.
echo تم البناء بنجاح.
echo البرنامج هنا:  app\build\windows\x64\runner\Release\school_app.exe
echo انسخ مجلد Release كاملاً إلى أي جهاز ويندوز ليعمل البرنامج دون تثبيت.
goto :eof

:err
echo.
echo فشل البناء. تأكد من تثبيت Flutter وVisual Studio (C++ workload).
exit /b 1
