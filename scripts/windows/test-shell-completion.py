#!/usr/bin/env python3
"""Exercise generated PowerShell completion with real console keys and PSReadLine."""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class ConsoleKeys:
    """Attach only to the newly created test shell, never an existing session."""

    def __init__(self, pid):
        class Key(ctypes.Structure):
            _fields_ = [('down', wintypes.BOOL), ('repeat', wintypes.WORD),
                        ('virtual', wintypes.WORD), ('scan', wintypes.WORD),
                        ('character', wintypes.WCHAR), ('control', wintypes.DWORD)]

        class Event(ctypes.Union):
            _fields_ = [('key', Key), ('padding', ctypes.c_byte * 16)]

        class Record(ctypes.Structure):
            _fields_ = [('kind', wintypes.WORD), ('event', Event)]

        self.Record, self.Key = Record, Key
        assert ctypes.sizeof(Record) == 20
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.AttachConsole.argtypes = [wintypes.DWORD]
        self.kernel.AttachConsole.restype = wintypes.BOOL
        self.kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                           ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.kernel.CreateFileW.restype = wintypes.HANDLE
        self.kernel.WriteConsoleInputW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Record),
                                                   wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        self.kernel.WriteConsoleInputW.restype = wintypes.BOOL
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        # Detach this driver from the CI console before attaching its own child.
        self.kernel.FreeConsole()
        if not self.kernel.AttachConsole(pid):
            raise ctypes.WinError(ctypes.get_last_error())
        self.handle = self.kernel.CreateFileW('CONIN$', 0xC0000000, 3, None, 3, 0, None)
        if self.handle == wintypes.HANDLE(-1).value:
            self.kernel.FreeConsole()
            raise ctypes.WinError(ctypes.get_last_error())

    def send(self, text='', capture=False):
        events = []
        for char in text:
            virtual, scan = {'\t': (9, 15), '\r': (13, 28)}.get(char, (0, 0))
            for down in (True, False):
                event = self.Record()
                event.kind = 1
                event.event.key = self.Key(down, 1, virtual, scan, char, 0)
                events.append(event)
        if capture:
            for down in (True, False):
                event = self.Record()
                event.kind = 1
                event.event.key = self.Key(down, 1, 0x7B, 0x58, '\0', 0)  # F12
                events.append(event)
        array = (self.Record * len(events))(*events)
        written = wintypes.DWORD()
        if not self.kernel.WriteConsoleInputW(self.handle, array, len(array), ctypes.byref(written)) or written.value != len(array):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        self.kernel.CloseHandle(self.handle)
        self.kernel.FreeConsole()

    def snapshot(self):
        class Coord(ctypes.Structure):
            _fields_ = [('x', wintypes.SHORT), ('y', wintypes.SHORT)]

        class Rect(ctypes.Structure):
            _fields_ = [('left', wintypes.SHORT), ('top', wintypes.SHORT),
                        ('right', wintypes.SHORT), ('bottom', wintypes.SHORT)]

        class Info(ctypes.Structure):
            _fields_ = [('size', Coord), ('cursor', Coord), ('attributes', wintypes.WORD),
                        ('window', Rect), ('maximum', Coord)]

        self.kernel.GetConsoleScreenBufferInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Info)]
        self.kernel.ReadConsoleOutputCharacterW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD,
                                                           Coord, ctypes.POINTER(wintypes.DWORD)]
        handle = self.kernel.CreateFileW('CONOUT$', 0x80000000, 3, None, 3, 0, None)
        if handle == wintypes.HANDLE(-1).value:
            return 'Console output was unavailable.'
        try:
            info = Info()
            if not self.kernel.GetConsoleScreenBufferInfo(handle, ctypes.byref(info)) or info.size.x <= 0:
                return 'Console buffer metadata was unavailable.'
            start = max(0, info.cursor.y - 79)
            count = min(32768, info.size.x * (info.cursor.y - start + 1))
            buffer, read = ctypes.create_unicode_buffer(count + 1), wintypes.DWORD()
            if not self.kernel.ReadConsoleOutputCharacterW(handle, buffer, count, Coord(0, start), ctypes.byref(read)):
                return 'Console text was unavailable.'
            value = buffer[:read.value]
            return '\n'.join(value[index:index + info.size.x].rstrip() for index in range(0, len(value), info.size.x))
        finally:
            self.kernel.CloseHandle(handle)


def wait_for(predicate, process, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError(f'Test PowerShell exited early: {process.returncode}')
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise TimeoutError('The owned console did not produce its expected PSReadLine receipt.')


def verify(cli, output):
    output.mkdir(parents=True, exist_ok=False)
    command = [str(cli), 'completion', '--shell', 'powershell', '--json']
    generated = subprocess.run(command, check=True, capture_output=True, text=True, encoding='utf-8', timeout=30)
    script = json.loads(generated.stdout)['data']['script']
    completion = output / 'completion.ps1'
    completion.write_text(script, encoding='utf-8')
    shell = shutil.which('pwsh')
    if not shell:
        raise RuntimeError('Native PowerShell 7 with PSReadLine is required.')
    fixture = output / 'fixture with spaces.pkg'
    fixture.write_text('Generated completion fixture; no installer content.', encoding='utf-8')
    invoked, evaluated = output / 'product-invoked', output / 'input-evaluated'
    capture, ready = output / 'buffers.jsonl', output / 'ready.json'
    fake_bin = output / 'bin'
    fake_bin.mkdir()
    (fake_bin / 'shou.cmd').write_text('@echo off\r\n>"' + str(invoked) + '" echo invoked\r\n', encoding='utf-8')
    bootstrap = output / 'bootstrap.ps1'
    bootstrap.write_text(f"""$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
trap {{ $_ | Out-String | Set-Content -LiteralPath {ps_quote(output / 'bootstrap-error.txt')}; exit 1 }}
Import-Module PSReadLine -ErrorAction Stop
Set-PSReadLineOption -HistorySavePath {ps_quote(output / 'history.txt')} -HistorySaveStyle SaveNothing -PredictionSource None -BellStyle None -EditMode Windows
Set-PSReadLineKeyHandler -Key Tab -Function Complete
. {ps_quote(completion)}
$env:PATH = {ps_quote(fake_bin)} + [IO.Path]::PathSeparator + $env:PATH
Set-Location -LiteralPath {ps_quote(output)}
function global:prompt {{ 'SHOU-COMPLETION> ' }}
Set-PSReadLineKeyHandler -Key F12 -ScriptBlock {{
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
    $command = $ast.Find({{ param($node) $node -is [Management.Automation.Language.CommandAst] }}, $true)
    $words = @($command.CommandElements | ForEach-Object {{
        if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) {{ $_.Value }} else {{ $_.Extent.Text }}
    }})
    $json = @{{ buffer = $line; cursor = $cursor; words = $words }} | ConvertTo-Json -Compress
    [IO.File]::AppendAllText({ps_quote(capture)}, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}}
@{{ powershell = $PSVersionTable.PSVersion.ToString(); psreadline = (Get-Module PSReadLine).Version.ToString();
    os = [Environment]::OSVersion.VersionString; process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();
    os_architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }} |
    ConvertTo-Json | Set-Content -LiteralPath {ps_quote(ready)} -Encoding utf8
""", encoding='utf-8-sig')
    process, keyboard = None, None
    checks, forced_close, failure = [], False, None
    try:
        process = subprocess.Popen([shell, '-NoLogo', '-NoProfile', '-NoExit', '-Command',
                                    '. ' + ps_quote(bootstrap)], creationflags=subprocess.CREATE_NEW_CONSOLE)
        # The bootstrap receipt is created after PSReadLine and all handlers load.
        def read_host():
            try:
                return json.loads(ready.read_text(encoding='utf-8-sig'))
            except (FileNotFoundError, json.JSONDecodeError):
                return None

        host = wait_for(read_host, process, timeout=30)
        if host['process_architecture'] != host['os_architecture']:
            raise RuntimeError('Emulated PowerShell is not native terminal acceptance.')
        keyboard = ConsoleKeys(process.pid)
        cases = [
            ('root', 'shou anal', ['shou', 'analysis']),
            ('subcommand', 'shou analysis co', ['shou', 'analysis', 'compare']),
            ('locale', 'shou --locale z', ['shou', '--locale', 'zh-CN']),
            ('leading-locale', 'shou --locale zh-CN analysis co', ['shou', '--locale', 'zh-CN', 'analysis', 'compare']),
            ('enum', 'shou plan create --mode p', ['shou', 'plan', 'create', '--mode', 'permanent']),
            ('spaced-filename', 'shou analysis scan --path .\\fixture', ['shou', 'analysis', 'scan', '--path', '.\\fixture with spaces.pkg']),
            ('literal-input', 'shou ' + ps_quote('$(Set-Content -LiteralPath ' + ps_quote(evaluated) + ' -Value evaluated)') + ' ', None),
            ('expression-input', 'shou $(Set-Content -LiteralPath ' + ps_quote(evaluated) + ' -Value evaluated) anal', None),
        ]
        for index, (name, line, expected) in enumerate(cases):
            keyboard.send(line + '\t', capture=True)

            def observed():
                if not capture.exists():
                    return None
                lines = capture.read_text(encoding='utf-8').splitlines()
                if len(lines) <= index:
                    return None
                try:
                    return json.loads(lines[index])
                except json.JSONDecodeError:
                    return None  # Writer may still be appending this record.

            record = wait_for(observed, process)
            if expected is not None and record['words'] != expected:
                raise AssertionError(f'{name}: {record["words"]!r} != {expected!r}')
            if invoked.exists() or evaluated.exists():
                raise AssertionError(f'{name}: completion invoked Shou or evaluated untrusted input.')
            checks.append(dict(case=name, passed=True, **record))
        keyboard.send('exit\r')
        process.wait(timeout=10)
        if process.returncode != 0:
            raise RuntimeError(f'Test console did not close normally: {process.returncode}')
    except BaseException as error:
        failure = str(error)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.kill()  # Only the owned, newly generated test shell.
            process.wait(timeout=5)
            forced_close = True
        if keyboard is not None:
            (output / 'console.txt').write_text(keyboard.snapshot(), encoding='utf-8')
            keyboard.close()
        with cli.open('rb') as stream:
            cli_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        with cli.with_suffix('.dll').open('rb') as stream:
            assembly_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        report = dict(format_version=1, source_commit=os.environ.get('GITHUB_SHA'), checks=checks,
                      success=failure is None, failure=failure, owned_shell_forced_close=forced_close,
                      product_invoked=invoked.exists(), input_evaluated=evaluated.exists(), profile_modified=False,
                      cli_sha256=cli_digest,
                      cli_assembly_sha256=assembly_digest,
                      completion_sha256=hashlib.sha256(script.encode()).hexdigest())
        if ready.exists():
            report['host'] = json.loads(ready.read_text(encoding='utf-8-sig'))
        (output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'{len(checks)} native PSReadLine keyboard completion checks passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('Real Windows console input is required; portable execution cannot verify this suite.')
    verify(args.cli.resolve(strict=True), args.output.resolve())
