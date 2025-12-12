@echo off
echo ========================================
echo   PAGA CONTA - Testes do Backend
echo ========================================
echo.

echo [Teste 1] Health Check...
curl -X GET http://localhost:3002/health
echo.
echo.

echo [Teste 2] Criar Ordem...
curl -X POST http://localhost:3002/orders/create ^
  -H "Content-Type: application/json" ^
  -d "{\"userId\":\"test123\",\"paymentHash\":\"abc\",\"paymentType\":\"electricity\",\"accountNumber\":\"12345\",\"billValue\":150,\"btcAmount\":0.00027}"
echo.
echo.

echo [Teste 3] Listar Ordens Disponiveis...
curl -X GET http://localhost:3002/orders/available
echo.
echo.

echo [Teste 4] Criar Invoice de Garantia...
curl -X POST http://localhost:3002/collateral/deposit ^
  -H "Content-Type: application/json" ^
  -d "{\"providerId\":\"provider1\",\"tierId\":\"basic\",\"amountBrl\":500,\"amountSats\":89820}"
echo.
echo.

echo ========================================
echo   Testes Concluidos!
echo ========================================
pause
