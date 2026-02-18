@echo off
cd /d %~dp0
call flutter build apk --release --dart-define-from-file=env.json
echo APK built!
pause
