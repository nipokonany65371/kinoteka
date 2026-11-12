#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Crane,
    [Parameter(Mandatory)][string]$Python,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$buildDir = Join-Path ([IO.Path]::GetTempPath()) ('kinoteka-layer-' + [guid]::NewGuid().ToString('N'))
$layer = Join-Path $buildDir 'application.tar'
$vendor = Join-Path $buildDir 'vendor'
New-Item -ItemType Directory -Path $buildDir | Out-Null

try {
    & $Python -m pip --disable-pip-version-check install --no-cache-dir --no-compile --only-binary=:all: `
        --platform manylinux_2_34_x86_64 --platform manylinux_2_28_x86_64 --platform manylinux_2_27_x86_64 --platform manylinux2014_x86_64 `
        --implementation cp --python-version 3.11 --abi cp311 --target $vendor -r (Join-Path $repositoryRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się pobrać zależności dla Linux amd64.' }

    @'
from pathlib import Path
import sys
import tarfile

repo, vendor, output = map(Path, sys.argv[1:])

def clean_metadata(info):
    info.uid = info.gid = 10001
    info.uname = info.gname = ""
    info.mode = 0o755 if info.isdir() else 0o644
    if "__pycache__" in info.name.split("/") or info.name.endswith(".pyc"):
        return None
    return info

with tarfile.open(output, "w") as layer:
    for name in ("app", "migrations", "wsgi.py", "infra/azure/grant_runtime.py"):
        layer.add(repo / name, "app/" + name, filter=clean_metadata)
    layer.add(vendor, "app/vendor", filter=clean_metadata)
    uploads = tarfile.TarInfo("app/instance/uploads")
    uploads.type = tarfile.DIRTYPE
    layer.addfile(clean_metadata(uploads))
'@ | & $Python - $repositoryRoot $vendor $layer
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się przygotować warstwy aplikacji.' }

    & $Crane mutate docker.io/library/python:3.11-slim --platform linux/amd64 --append $layer `
        --user '10001:10001' --workdir /app --env 'FLASK_APP=wsgi' --env 'PYTHONPATH=/app/vendor' --env 'PYTHONDONTWRITEBYTECODE=1' --env 'PYTHONUNBUFFERED=1' `
        --entrypoint 'python,-m,gunicorn,--bind,0.0.0.0:8000,--workers,2' --cmd 'wsgi:app' --exposed-ports '8000/tcp' --output $OutputPath
    if ($LASTEXITCODE -ne 0) { throw 'Nie udało się złożyć obrazu OCI.' }
} finally {
    $resolvedBuildDir = (Resolve-Path -LiteralPath $buildDir).Path
    $expectedBuildDir = [IO.Path]::GetFullPath($buildDir)
    if ($resolvedBuildDir -eq $expectedBuildDir -and (Split-Path $resolvedBuildDir -Leaf) -like 'kinoteka-layer-*') {
        Remove-Item -LiteralPath $resolvedBuildDir -Recurse -Force
    }
}
