@echo off
setlocal

:: --- Verifica se o GitHub CLI (gh) está instalado ---
gh --version >nul 2>nul
if %errorlevel% neq 0 (
    echo ❌ Erro: O GitHub CLI ('gh') nao foi encontrado.
    echo.
    echo    Por favor, instale-o e faca o login seguindo as instrucoes em:
    echo    https://cli.github.com/
    echo.
    echo    Depois de instalar, FECHE e REABRA este terminal e tente novamente.
    exit /b 1
)

:: --- Script para automatizar o build e release do APK no GitHub ---

:: 1. Variáveis de Configuração
set REPO=thiagosoriedem/controle_amil
set DEFAULT_APK_PATH=build\app\outputs\flutter-apk\app-release.apk

echo.
echo 🚀 Iniciando o processo de release...
echo.

:: 2. Obter nome e versão do app do pubspec.yaml
for /f "tokens=2 delims=: " %%n in ('findstr /R /C:"^name:" pubspec.yaml') do set APP_NAME=%%n
for /f "tokens=2 delims=: " %%v in ('findstr /R /C:"^version:" pubspec.yaml') do set VERSION=%%v

:: Cria uma tag e um nome de arquivo "limpo" (substituindo '+' por '_')
set TAG=v%VERSION%
set CLEAN_VERSION=%VERSION:+=_%
set FINAL_APK_NAME=%APP_NAME%-%CLEAN_VERSION%.apk
set FINAL_APK_PATH=build\app\outputs\flutter-apk\%FINAL_APK_NAME%

echo ℹ️  Nome do App: %APP_NAME%
echo ℹ️  Versao detectada: %VERSION%
echo ℹ️  Tag a ser criada: %TAG%
echo ℹ️  Nome do APK final: %FINAL_APK_NAME%
echo.

:: 3. Limpar, obter dependências e construir o APK de release
echo 🧹 Limpando builds antigos...
call flutter clean

echo 📥 Obtendo dependencias...
call flutter pub get

echo  Construindo o APK de release...
call flutter build apk --release

:: 4. Verificar se o APK foi gerado e renomeá-lo
if not exist "%DEFAULT_APK_PATH%" (
    echo ❌ Erro: O arquivo APK padrao nao foi encontrado em %DEFAULT_APK_PATH%
    exit /b 1
)

echo 🔄 Renomeando APK para %FINAL_APK_NAME%...
move "%DEFAULT_APK_PATH%" "%FINAL_APK_PATH%"

echo ✅ APK construido e renomeado com sucesso em: %FINAL_APK_PATH%
echo.

:: 5. Criar a tag Git, enviá-la e então criar a release
echo 🏷️  Criando e enviando a tag %TAG% para o GitHub...
git tag "%TAG%"
git push origin "%TAG%"

echo 📤 Criando a release no GitHub e fazendo o upload do APK...
gh release create "%TAG%" "%FINAL_APK_PATH%" --repo "%REPO%" --title "Release %VERSION%" --generate-notes

echo.
echo 🎉 Sucesso! Release %TAG% criada e APK enviado para o repositorio %REPO%.
echo.

endlocal