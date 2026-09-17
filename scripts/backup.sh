#!/bin/bash
#
# Backup de tudo que a Hevile nao pode perder.
#
# Antes deste script existir, em 2026-09-17, NAO HAVIA BACKUP NENHUM: a pasta
# /data/coolify/backups estava vazia desde julho, nao havia cron nem timer, e os
# unicos .sql do disco eram restos da migracao do Cobranca. O banco do fluxo de
# pagamentos, do portal, da prestacao e da cobranca existiam em um lugar so.
#
# Cobre tres coisas que ficam em lugares diferentes:
#   1. os bancos Postgres (todos, um arquivo cada)
#   2. o SQLite do LPCO, que nao e "banco" para o Coolify e fica num volume
#   3. os volumes de upload (comprovantes da prestacao, anexos do dispute...)
#
# Uso:
#   ./backup.sh              # roda e guarda em /var/backups/hevile
#   DESTINO=/outro ./backup.sh
#
# No cron do root, diario as 03:00 (horario de pouco movimento):
#   0 3 * * * /root/backup-hevile.sh >> /var/log/backup-hevile.log 2>&1
#
# ---------------------------------------------------------------------------
# COMO RESTAURAR  (leia ANTES de precisar)
#
# Backup que ninguem sabe restaurar nao e backup, e esperanca. Teste isto uma
# vez, num banco descartavel, antes de confiar.
#
#   um banco inteiro:
#     docker exec -i <postgres> createdb -U postgres teste_restore
#     docker exec -i <postgres> pg_restore -U postgres -d teste_restore \
#        < /var/backups/hevile/<data>/portal_colaborador.dump
#
#   os papeis/usuarios do Postgres (so numa maquina nova):
#     docker exec -i <postgres> psql -U postgres < .../globais.sql
#
#   o SQLite do LPCO: parar o container, copiar o .db para /data no volume,
#     subir de novo. O arquivo do backup ja vem consolidado -- nao precisa do
#     -wal junto, porque foi gerado pela API de backup do SQLite e nao por cp.
#
#   um volume:
#     tar xzf volume-<nome>.tar.gz -C /var/lib/docker/volumes/<nome>/_data
# ---------------------------------------------------------------------------

set -euo pipefail

DESTINO="${DESTINO:-/var/backups/hevile}"
DIAS_PARA_GUARDAR="${DIAS_PARA_GUARDAR:-14}"
# Abaixo disto o script nem comeca. Encher o disco raiz derrubaria o servidor
# inteiro -- backup nao pode ser a causa da queda que ele deveria remediar.
MINIMO_LIVRE_GB="${MINIMO_LIVRE_GB:-15}"

DATA=$(date +%Y%m%d-%H%M)
PASTA="$DESTINO/$DATA"

falhou() {
    echo "ERRO na linha $1 — o backup NAO esta completo." >&2
    echo "A pasta $PASTA fica como esta, para inspecao." >&2
    exit 1
}
trap 'falhou $LINENO' ERR

echo "=== Backup Hevile — $(date '+%d/%m/%Y %H:%M') ==="

livre_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$livre_gb" -lt "$MINIMO_LIVRE_GB" ]; then
    echo "ERRO: so ${livre_gb}GB livres em / (minimo ${MINIMO_LIVRE_GB}GB). Nao vou comecar." >&2
    exit 1
fi
echo "Espaco livre: ${livre_gb}GB"

mkdir -p "$PASTA"

# ── 1. Postgres ─────────────────────────────────────────────────────────────
# Descobre o container em vez de fixar o uuid: o nome muda a cada redeploy.
# Exclui o banco do proprio Coolify, que e painel e se reconstroi.
PG=$(docker ps --format '{{.Names}}\t{{.Image}}' \
     | grep -i postgres | grep -v '^coolify' | head -1 | cut -f1 || true)

if [ -z "$PG" ]; then
    # Nao e aviso, e falha. Nao existe cenario em que pular os bancos esteja
    # certo: e o dado que nao da para recriar. Sair com sucesso aqui faria o
    # cron registrar "ok" todas as noites sem salvar nada.
    echo "ERRO: nao achei o container do Postgres. Os bancos NAO foram salvos." >&2
    exit 1
else
    echo
    echo "-- Postgres ($PG)"
    # Papeis e senhas ficam FORA dos dumps de banco. Sem isto, restaurar numa
    # maquina nova traz as tabelas e nenhum usuario para acessa-las.
    docker exec "$PG" pg_dumpall -U postgres --globals-only > "$PASTA/globais.sql"

    bancos=$(docker exec "$PG" psql -U postgres -tAc \
        "select datname from pg_database where datistemplate = false and datname <> 'postgres'")
    for b in $bancos; do
        # -Fc: formato proprio do Postgres, ja comprimido, e permite restaurar
        # tabela por tabela. Texto puro so serviria para restaurar tudo ou nada.
        docker exec "$PG" pg_dump -U postgres -Fc "$b" > "$PASTA/$b.dump"
        echo "   $(du -h "$PASTA/$b.dump" | cut -f1)	$b"
    done
fi

# ── 2. SQLite do LPCO ───────────────────────────────────────────────────────
# Procura o container pelo arquivo, e nao pelo uuid.
#
# Copiar o .db com `cp` seria ERRADO: desde que ligamos o modo WAL, as
# gravacoes recentes vivem no arquivo -wal ao lado, e uma copia crua pegaria um
# banco desatualizado ou inconsistente. A API de backup do SQLite consolida
# tudo num arquivo so, com o banco em uso.
echo
echo "-- SQLite do LPCO"
LPCO=""
for c in $(docker ps --format '{{.Names}}'); do
    if docker exec "$c" test -f /data/lpco_monitor.db 2>/dev/null; then
        LPCO="$c"
        break
    fi
done

if [ -z "$LPCO" ]; then
    echo "   AVISO: nao achei o container do LPCO — pulando." >&2
else
    docker exec "$LPCO" python -c "
import sqlite3
origem = sqlite3.connect('/data/lpco_monitor.db')
copia = sqlite3.connect('/tmp/backup_lpco.db')
origem.backup(copia)
copia.close(); origem.close()
"
    docker cp "$LPCO:/tmp/backup_lpco.db" "$PASTA/lpco_monitor.db" > /dev/null
    docker exec "$LPCO" rm -f /tmp/backup_lpco.db
    echo "   $(du -h "$PASTA/lpco_monitor.db" | cut -f1)	lpco_monitor.db ($LPCO)"
fi

# ── 3. Volumes ──────────────────────────────────────────────────────────────
# Comprovante de despesa e anexo de contestacao nao estao em banco nenhum:
# vivem em volume. Backup de banco nao os alcanca.
echo
echo "-- Volumes"
mkdir -p "$PASTA/volumes"
for v in $(docker volume ls -q); do
    caminho="/var/lib/docker/volumes/$v/_data"
    [ -d "$caminho" ] || continue
    # Volume vazio nao vira arquivo: so faria barulho na listagem.
    [ -n "$(ls -A "$caminho" 2>/dev/null)" ] || continue
    tar czf "$PASTA/volumes/$v.tar.gz" -C "$caminho" . 2>/dev/null || {
        echo "   AVISO: falhei em $v (segue o baile)" >&2
        continue
    }
    echo "   $(du -h "$PASTA/volumes/$v.tar.gz" | cut -f1)	$v"
done

# ── 4. Limpeza ──────────────────────────────────────────────────────────────
echo
echo "-- Limpeza (guardando $DIAS_PARA_GUARDAR dias)"
find "$DESTINO" -maxdepth 1 -type d -name '20*' -mtime +"$DIAS_PARA_GUARDAR" \
     -exec rm -rf {} + 2>/dev/null || true

trap - ERR

# Conferencia final. Um backup que nao gerou arquivo nenhum tem de GRITAR: o
# perigo de rotina noturna e o log dizer "Pronto" por meses enquanto a pasta
# sai vazia, e so descobrirmos no dia em que for preciso restaurar.
arquivos=$(find "$PASTA" -type f | wc -l)
if [ "$arquivos" -eq 0 ]; then
    echo "ERRO: o backup terminou SEM NENHUM ARQUIVO. Nao ha o que restaurar." >&2
    exit 1
fi

echo
echo "Pronto: $PASTA — $arquivos arquivo(s), $(du -sh "$PASTA" | cut -f1)"
echo "Total guardado: $(du -sh "$DESTINO" | cut -f1)"
echo
echo "LEMBRE: isto esta NO MESMO DISCO do servidor. Protege contra erro humano"
echo "e contra container que corrompe dado, mas NAO contra perder a maquina."
echo "Enquanto uma copia nao sair daqui, o backup esta pela metade."
