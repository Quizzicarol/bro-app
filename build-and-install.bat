@echo off
echo ================================
echo COMPILAR E INSTALAR APP
echo ================================
echo.

cd c:\Users\produ\Documents\GitHub\paga_conta_clean

echo [1/3] Limpando build anterior...
call flutter clean

echo.
echo [2/3] Baixando dependencias...
call flutter pub get

echo.
echo [3/3] Compilando APK Release...
call flutter build apk --release

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ❌ ERRO NA COMPILACAO!
    pause
    exit /b 1
)

echo.
echo ================================
echo ✅ APK COMPILADO COM SUCESSO!
echo ================================
echo.
echo Instalando no dispositivo...
cd C:\Users\produ\AppData\Local\Android\Sdk\platform-tools
.\adb.exe install -r C:\Users\produ\Documents\GitHub\paga_conta_clean\build\app\outputs\flutter-apk\app-release.apk

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ❌ ERRO NA INSTALACAO!
    pause
    exit /b 1
)

echo.
echo ================================
echo ✅ APP INSTALADO COM SUCESSO!
echo ================================
echo.
echo Abra o app no celular e teste o modo provedor:
echo 1. Toque no card laranja "Modo Provedor - Ganhe 3%%"
echo 2. Leia a tela educacional
echo 3. Clique em "Começar Agora"
echo 4. Escolha um tier e deposite garantia
echo.
pause
