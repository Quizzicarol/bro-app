@echo off
echo ============================================
echo DEBUG: Ordens nao aparecem no modo provedor
echo ============================================
echo.

echo [1/3] Instalando APK atualizado...
cd C:\Users\produ\AppData\Local\Android\Sdk\platform-tools
.\adb.exe install -r C:\Users\produ\Documents\GitHub\paga_conta_clean\build\app\outputs\flutter-apk\app-release.apk

echo.
echo [2/3] Forçando stop do app...
.\adb.exe shell am force-stop com.pagaconta.paga_conta_clean

echo.
echo [3/3] Iniciando app...
.\adb.exe shell am start -n com.pagaconta.paga_conta_clean/.MainActivity

echo.
echo ============================================
echo App iniciado! Agora monitore os logs:
echo ============================================
echo.
echo Pressione CTRL+C para parar o monitoramento
echo.

.\adb.exe logcat -c
.\adb.exe logcat | findstr /C:"OrderProvider" /C:"getAvailableOrders" /C:"Modo teste" /C:"ordens disponíveis"
