@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title Crawler de vagas - Coleta, deduplicacao, enriquecimento e catalogo

echo ============================================================
echo CRAWLER DE VAGAS
echo Sequencia: coleta ^> deduplicacao ^> enriquecimento ^> catalogo
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
echo [1/4] COLETA DE VAGAS - crawler.sh
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
echo [2/4] DEDUPLICACAO - dedup.sh
echo ============================================================
"%BASH_EXE%" --noprofile --norc -c "bash ./dedup.sh"
set "DEDUP_EXIT=%ERRORLEVEL%"

if not "%DEDUP_EXIT%"=="0" if not "%DEDUP_EXIT%"=="2" (
    echo.
    echo ERRO: dedup.sh terminou com codigo %DEDUP_EXIT%.
    echo As etapas seguintes nao serao executadas.
    goto :failure
)

if "%DEDUP_EXIT%"=="2" (
    echo.
    echo AVISO: jobs.json foi consolidado, mas alguns arquivos individuais nao puderam ser removidos.
)

echo.
echo ============================================================
echo [3/4] ENRIQUECIMENTO DAS VAGAS - enrich.sh
echo ============================================================
"%BASH_EXE%" --noprofile --norc -c "bash ./enrich.sh"
set "ENRICH_EXIT=%ERRORLEVEL%"

if not "%ENRICH_EXIT%"=="0" if not "%ENRICH_EXIT%"=="2" (
    echo.
    echo ERRO: enrich.sh terminou com codigo %ENRICH_EXIT%.
    echo catalog.sh nao sera executado.
    goto :failure
)

if "%ENRICH_EXIT%"=="2" (
    echo.
    echo AVISO: enriquecimento parcial. Os dados obtidos foram preservados.
)

echo.
echo ============================================================
echo [4/4] CATALOGO DE TITULOS - catalog.sh
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
    set "FINAL_EXIT=2"
) else (
    set "FINAL_EXIT=0"
)
if "%DEDUP_EXIT%"=="2" set "FINAL_EXIT=2"
if "%ENRICH_EXIT%"=="2" set "FINAL_EXIT=2"

if "%FINAL_EXIT%"=="2" (
    echo Algumas etapas tiveram resultados parciais. Consulte os avisos acima.
    echo jobs.json e catalog.json foram atualizados com os dados disponiveis.
) else (
    echo FLUXO CONCLUIDO COM SUCESSO.
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
