# Puxa o backup do servidor para uma pasta desta máquina.
#
# A direção importa: é o PC que PUXA, o servidor não empurra. Assim o servidor
# não guarda credencial nenhuma daqui — servidor comprometido não alcança nem
# apaga esta cópia. É a única cópia que sobrevive a perder a máquina lá.
#
# Não usa rsync (o Windows não tem). Não precisa: cada pasta de backup é uma
# data que nunca muda depois de criada, então basta copiar as que faltam. Na
# prática é incremental, e sem dependência nova.
#
# Primeira vez (baixa tudo que existir lá):
#   powershell -ExecutionPolicy Bypass -File puxar-backup.ps1
#
# Para rodar sozinho todo dia, no Agendador de Tarefas do Windows:
#   Programa:   powershell.exe
#   Argumentos: -ExecutionPolicy Bypass -File "C:\...\puxar-backup.ps1"
#   Agende para um horário DEPOIS das 3h da manhã (quando o servidor gera).
#
# Exige acesso por chave SSH: `ssh root@<servidor>` tem que entrar sem pedir
# senha. Se pedir, o agendamento nunca vai funcionar — resolva isso primeiro.

param(
    [string]$Servidor = "root@91.99.77.42",
    [string]$Origem   = "/var/backups/hevile",
    [string]$Destino  = "$env:USERPROFILE\Backups\Hevile",
    [int]$DiasParaGuardar = 30,
    [string]$Chave = ""
)

$ErrorActionPreference = "Stop"

# Guardo mais dias aqui do que no servidor de propósito: espaço em PC sobra, e
# o valor desta cópia é justamente alcançar mais para trás do que a de lá.

$sshArgs = @()
if ($Chave) { $sshArgs += @("-i", $Chave) }

function Falar($texto) { Write-Host $texto }

Falar "=== Puxando backup da Hevile — $(Get-Date -Format 'dd/MM/yyyy HH:mm') ==="
Falar "de ${Servidor}:${Origem}"
Falar "para $Destino"
Falar ""

New-Item -ItemType Directory -Force -Path $Destino | Out-Null

# ── o que existe lá ─────────────────────────────────────────────────────────
$remotas = & ssh @sshArgs $Servidor "ls -1 $Origem 2>/dev/null" 2>&1
if ($LASTEXITCODE -ne 0) {
    Falar "ERRO: não consegui falar com o servidor."
    Falar ($remotas -join "`n")
    Falar ""
    Falar "Confira se 'ssh $Servidor' entra sem pedir senha."
    exit 1
}

$remotas = @($remotas | Where-Object { $_ -match '^\d{8}-\d{4}$' })
if ($remotas.Count -eq 0) {
    # Silêncio aqui seria o pior caso: a tarefa rodaria todo dia sem copiar
    # nada e ninguém notaria até precisar.
    Falar "ERRO: o servidor não tem nenhuma pasta de backup em $Origem."
    exit 1
}

$locais = @(Get-ChildItem -Path $Destino -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
$faltando = @($remotas | Where-Object { $locais -notcontains $_ })

Falar "$($remotas.Count) no servidor, $($locais.Count) aqui, $($faltando.Count) para copiar."
Falar ""

# ── copia o que falta ───────────────────────────────────────────────────────
$copiadas = 0
foreach ($pasta in $faltando) {
    Falar "  baixando $pasta ..."
    # Para uma pasta PARCIAL: baixa num nome temporário e só renomeia no fim.
    # Sem isso, uma queda de rede deixaria uma pasta com cara de completa, e
    # da próxima vez o script a consideraria já copiada.
    $temp = Join-Path $Destino "$pasta.baixando"
    if (Test-Path $temp) { Remove-Item -Recurse -Force $temp }

    & scp @sshArgs -r -q "${Servidor}:${Origem}/${pasta}" $temp
    if ($LASTEXITCODE -ne 0) {
        Falar "     FALHOU — deixo para a próxima execução."
        if (Test-Path $temp) { Remove-Item -Recurse -Force $temp }
        continue
    }
    Move-Item $temp (Join-Path $Destino $pasta)
    $copiadas++
    $tamanho = (Get-ChildItem (Join-Path $Destino $pasta) -Recurse -File |
                Measure-Object -Property Length -Sum).Sum
    Falar ("     ok — {0:N0} MB" -f ($tamanho / 1MB))
}

# ── limpeza local ───────────────────────────────────────────────────────────
$limite = (Get-Date).AddDays(-$DiasParaGuardar)
$velhas = @(Get-ChildItem -Path $Destino -Directory |
            Where-Object { $_.Name -match '^\d{8}-\d{4}$' -and $_.CreationTime -lt $limite })
foreach ($v in $velhas) {
    Remove-Item -Recurse -Force $v.FullName
    Falar "  apagada (mais de $DiasParaGuardar dias): $($v.Name)"
}

# ── conferência ─────────────────────────────────────────────────────────────
$pastas = @(Get-ChildItem -Path $Destino -Directory |
            Where-Object { $_.Name -match '^\d{8}-\d{4}$' })
$total = (Get-ChildItem $Destino -Recurse -File | Measure-Object -Property Length -Sum).Sum

Falar ""
if ($pastas.Count -eq 0) {
    Falar "ERRO: não há NENHUMA cópia local. Não há de onde restaurar."
    exit 1
}

$maisNova = ($pastas | Sort-Object Name -Descending | Select-Object -First 1).Name
Falar ("$($pastas.Count) cópia(s) aqui, {0:N1} GB no total." -f ($total / 1GB))
Falar "Mais recente: $maisNova"

# Cópia velha é o mesmo que cópia nenhuma, e o jeito de isso passar despercebido
# é a tarefa terminar "com sucesso" enquanto o servidor parou de gerar.
$dataMaisNova = [datetime]::ParseExact($maisNova.Substring(0,8), 'yyyyMMdd', $null)
$idade = (New-TimeSpan -Start $dataMaisNova -End (Get-Date)).Days
if ($idade -gt 2) {
    Falar ""
    Falar "ATENÇÃO: a cópia mais recente tem $idade dias. O backup do servidor"
    Falar "pode ter parado de rodar — confira o cron lá."
    exit 1
}
