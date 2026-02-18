@echo off
echo ========================================
echo   BRO APP - Setup Backend
echo ========================================
echo.

echo [1/3] Instalando dependencias do Node.js...
cd backend
call npm install

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERRO] Falha ao instalar dependencias!
    echo Verifique se o Node.js esta instalado: node --version
    pause
    exit /b 1
)

echo.
echo [2/3] Verificando instalacao...
call npm list --depth=0

echo.
echo [3/3] Iniciando servidor...
echo.
echo ========================================
echo   Servidor rodando em http://localhost:3002
echo   Pressione Ctrl+C para parar
echo ========================================
echo.

call npm start
