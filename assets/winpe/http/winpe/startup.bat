@echo off
wpeinit

set share1=\\<IP>\<SMB_MOUNT_POINT1>
set drive1=S:

set share2=\\<IP>\<SMB_MOUNT_POINT2>
set drive2=T:

echo Waiting for network...
:retry-P
ping -n 1 <IP> | find "TTL=" >nul
if errorlevel 1 (
    ping -n 4 127.0.0.1 >nul
    goto retry-P
)

echo Mounting POINT1...
:retry-POINT1
net use %drive1% %share1% /persistent:no >nul 2>nul
if errorlevel 1 (
    choice /t 5 /d y /n >nul 2>nul
    goto retry-POINT1
)

echo Mounting POINT2...
:retry-POINT2
net use %drive2% %share2% /persistent:no >nul 2>nul
if errorlevel 1 (
    choice /t 5 /d y /n >nul 2>nul
    goto retry-POINT2
)


echo.
echo === Mount Drive Successfully ===
echo %drive1% %share1%
echo %drive2% %share2%
echo.
%drive1%
cmd

