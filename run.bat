@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title Crawler de vagas - Coleta, deduplicacao e catalogo

echo ============================================================
echo CRAWLER DE VAGAS
echo Sequencia: coleta ^> deduplicacao ^> catalogo
echo ============================================================
echo.

set "BASH_EXE="

if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\usr\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\usr\bin\bash.exe"

if not defined BASH_EXE (
    for /f "delims=" %%I in ('where bash.exe 2^>nul') do if not defined BASH_EXE set "BASH_EXE=%%I"
)

if not defined BASH_EXE (
    echo ERRO: Git Bash nao foi encontrado.
    echo Instale o Git for Windows: https://git-scm.com/downloads/win
    echo.
    pause
    exit /b 1
)

echo [CONFIGURACAO] Git Bash: "%BASH_EXE%"
echo [CONFIGURACAO] Diretorio: "%CD%"
echo.

echo ============================================================
echo [1/3] COLETA DE VAGAS - crawler.sh
echo ============================================================
"%BASH_EXE%" --noprofile --norc -c "bash ./crawler.sh"
set "CRAWLER_EXIT=%ERRORLEVEL%"

if not "%CRAWLER_EXIT%"=="0" if not "%CRAWLER_EXIT%"=="2" (
    echo.
    echo ERRO: crawler.sh terminou com codigo %CRAWLER_EXIT%.
    echo As etapas seguintes nao serao executadas.
    goto :failure
)

if "%CRAWLER_EXIT%"=="2" (
    echo.
    echo AVISO: a coleta terminou parcialmente.
    echo Os resultados obtidos serao consolidados; time.txt foi preservado pelo crawler.
)

echo.
echo ============================================================
echo [2/3] DEDUPLICACAO - dedup.sh
echo ============================================================
"%BASH_EXE%" --noprofile --norc -c "bash ./dedup.sh"
set "DEDUP_EXIT=%ERRORLEVEL%"

if not "%DEDUP_EXIT%"=="0" (
    echo.
    echo ERRO: dedup.sh terminou com codigo %DEDUP_EXIT%.
    echo catalog.sh nao sera executado.
    goto :failure
)

echo.
echo ============================================================
echo [3/3] CATALOGO DE TITULOS - catalog.sh
echo ============================================================
"%BASH_EXE%" --noprofile --norc -c "bash ./catalog.sh"
set "CATALOG_EXIT=%ERRORLEVEL%"

if not "%CATALOG_EXIT%"=="0" (
    echo.
    echo ERRO: catalog.sh terminou com codigo %CATALOG_EXIT%.
    goto :failure
)

echo.
echo ============================================================
if "%CRAWLER_EXIT%"=="2" (
    echo FLUXO CONCLUIDO COM COLETA PARCIAL.
    echo Deduplicacao e catalogo foram atualizados.
    set "FINAL_EXIT=2"
) else (
    echo FLUXO CONCLUIDO COM SUCESSO.
    set "FINAL_EXIT=0"
)
echo.
echo Arquivos:
echo   jobs.json
echo   catalog.json
echo.
echo Pressione qualquer tecla para fechar esta janela.
pause >nul
exit /b %FINAL_EXIT%

:failure
echo.
echo FLUXO INTERROMPIDO. Corrija o erro e execute run.bat novamente.
echo Pressione qualquer tecla para fechar esta janela.
pause >nul
exit /b 1
