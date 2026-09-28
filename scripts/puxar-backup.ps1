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
$falhas = 0
$i = 0
foreach ($pasta in $faltando) {
    $i++
    # Tamanho antes de começar: sem isso a tela ficava parada em "baixando..."
    # por uma hora e parecia travada (2026-09-28).
    $mb = & ssh @sshArgs $Servidor "du -sm $Origem/$pasta 2>/dev/null | cut -f1"
    Falar "  [$i/$($faltando.Count)] baixando $pasta ($mb MB) ..."
    # Para uma pasta PARCIAL: baixa num nome temporário e só renomeia no fim.
    # Sem isso, uma queda de rede deixaria uma pasta com cara de completa, e
    # da próxima vez o script a consideraria já copiada.
    $temp = Join-Path $Destino "$pasta.baixando"
    if (Test-Path $temp) { Remove-Item -Recurse -Force $temp }

    # Sem -q: o scp mostra o andamento de cada arquivo (%, MB/s, tempo que falta).
    & scp @sshArgs -r "${Servidor}:${Origem}/${pasta}" $temp
    if ($LASTEXITCODE -ne 0) {
        $falhas++
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

# ── recibo para o servidor ──────────────────────────────────────────────────
# O conferir-backup.sh de lá só enxerga o próprio disco: não tem como saber se
# esta cópia está acontecendo. Sem o recibo, o PC poderia parar de puxar por
# meses e o servidor seguiria achando que está tudo bem.
#
# Exige o backup MAIS NOVO do servidor, e não só "um recente": a conferência de
# idade acima tolera 2 dias, e recibo em cima dela faria uma cópia que falha
# todo dia parecer sucesso. Recibo de cópia que falhou é pior que nenhum.
# Recibo só com TUDO copiado: o servidor apaga o que o recibo diz que já está
# aqui, então uma pasta antiga que falhou não pode ficar coberta pela mais nova.
if ($falhas -gt 0) {
    Falar ""
    Falar "ATENÇÃO: $falhas pasta(s) não baixaram. Sem recibo hoje, para o servidor não apagar nada."
    exit 1
}
$maisNovaRemota = ($remotas | Sort-Object -Descending | Select-Object -First 1)
if ($maisNova -ne $maisNovaRemota) {
    Falar ""
    Falar "ATENÇÃO: o backup mais novo do servidor ($maisNovaRemota) não chegou aqui."
    Falar "Sem recibo hoje — o servidor vai avisar se isso se repetir."
    exit 1
}

& ssh @sshArgs $Servidor "echo $maisNova > $Origem/.ultima-copia-externa"
if ($LASTEXITCODE -ne 0) {
    Falar ""
    Falar "AVISO: a cópia está aqui, mas não consegui deixar o recibo no servidor."
    Falar "O conferidor de lá vai achar que a cópia parou."
    exit 1
}
Falar "Recibo deixado no servidor."
