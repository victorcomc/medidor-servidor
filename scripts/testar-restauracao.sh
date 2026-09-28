#!/usr/bin/env bash
#
# Restaura um backup num banco descartavel e confere se os dados voltaram.
#
# Um backup que nunca foi restaurado e um arquivo, nao um backup. Este script
# transforma promessa em prova, e a prova e um numero: quantas linhas tem cada
# tabela no banco de producao contra quantas voltaram do arquivo.
#
# NAO TOCA EM PRODUCAO. As unicas escritas sao CREATE e DROP de um banco cujo
# nome comeca com `restauracao_teste_` -- e o script se recusa a rodar se esse
# nome ja existir por acaso.
#
# Uso (no SERVIDOR, via ssh -- precisa do docker):
#   ./testar-restauracao.sh                      # testa portal_colaborador
#   ./testar-restauracao.sh fluxo_pagamentos     # testa outro banco
#   ./testar-restauracao.sh --todos              # todos, incluindo o SQLite do LPCO
#   ./testar-restauracao.sh --lpco               # so o SQLite do LPCO
#
set -uo pipefail

ORIGEM="${ORIGEM:-/var/backups/hevile}"
PREFIXO="restauracao_teste"

# ---------------------------------------------------------------------------
# Acha o container do Postgres. O nome muda a cada deploy do Coolify, entao
# descobrir e mais confiavel do que fixar.
# ---------------------------------------------------------------------------
# Mesmo metodo do backup-hevile.sh, e de proposito: ele acha este container
# todos os dias as 3h. Filtra pela IMAGEM (o nome do container e um uuid do
# Coolify) e exclui os que comecam com `coolify` -- o proprio Coolify roda um
# Postgres interno, e restaurar backup da Hevile em cima dele seria desastre.
PG="$(docker ps --format '{{.Names}}	{{.Image}}'       | grep -i postgres | grep -v '^coolify' | head -1 | cut -f1 || true)"
if [ -z "$PG" ]; then
  echo "Containers com postgres na imagem:" >&2
  docker ps --format '  {{.Names}}	{{.Image}}' | grep -i postgres >&2 || echo "  (nenhum)" >&2
  echo "ERRO: nao achei o container do Postgres." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# O backup mais recente.
# ---------------------------------------------------------------------------
PASTA="$(ls -1d "$ORIGEM"/20* 2>/dev/null | sort | tail -1)"
if [ -z "$PASTA" ]; then
  echo "ERRO: nenhum backup em $ORIGEM" >&2
  exit 1
fi

echo "Container Postgres : $PG"
echo "Backup             : $PASTA"
echo "Gerado em          : $(stat -c %y "$PASTA" | cut -d. -f1)"
echo

psql_() { docker exec -i "$PG" psql -U postgres -tAq "$@"; }

# ---------------------------------------------------------------------------
# Conta linhas de cada tabela. Usa COUNT(*) de verdade, e nao a estimativa do
# planejador: a estimativa erra depois de muita escrita, e aqui o numero PRECISA
# ser exato -- o objetivo e comparar.
# ---------------------------------------------------------------------------
contar() {
  local banco="$1"
  psql_ -d "$banco" <<'SQL'
select string_agg(linha, E'\n' order by linha) from (
  select format('%s=%s', c.relname,
                (xpath('/row/c/text()',
                       query_to_xml(format('select count(*) as c from %I.%I',
                                           n.nspname, c.relname),
                                    false, true, '')))[1]::text::bigint) as linha
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'r' and n.nspname = 'public'
) t;
SQL
}

testar_um() {
  local banco="$1"
  local arquivo="$PASTA/$banco.dump"
  local alvo="${PREFIXO}_${banco}"

  echo "=============================================================="
  echo "BANCO: $banco"
  echo "=============================================================="

  if [ ! -f "$arquivo" ]; then
    echo "  SEM BACKUP: $arquivo nao existe."
    echo "  -> Este banco NAO esta sendo salvo. E o achado mais importante"
    echo "     que este teste pode produzir."
    return 1
  fi
  echo "  arquivo: $(du -h "$arquivo" | cut -f1)"

  # Recusa se o nome descartavel ja existir -- nao vamos apagar banco de ninguem.
  if [ -n "$(psql_ -c "select 1 from pg_database where datname='$alvo'")" ]; then
    echo "  ERRO: o banco '$alvo' ja existe. Apague antes:" >&2
    echo "        docker exec $PG psql -U postgres -c 'drop database $alvo'" >&2
    return 1
  fi

  echo "  criando $alvo ..."
  psql_ -c "create database $alvo" >/dev/null

  echo "  restaurando ..."
  local saida
  saida="$(docker exec -i "$PG" pg_restore -U postgres -d "$alvo" --no-owner --no-privileges < "$arquivo" 2>&1)"
  local rc=$?
  local avisos
  avisos="$(echo "$saida" | grep -c . || true)"
  if [ "$rc" -ne 0 ] && [ -z "$saida" ]; then
    echo "  FALHOU ao restaurar (codigo $rc)"
  fi
  [ "$avisos" -gt 0 ] && echo "  ($avisos linha(s) de aviso do pg_restore -- normais em dono/permissao)"

  echo
  echo "  COMPARACAO (tabela: producao -> restaurado)"
  local prod rest
  prod="$(contar "$banco")"
  rest="$(contar "$alvo")"

  # A regra NAO e "igual". O backup e de 03:00 e a producao seguiu trabalhando:
  # producao ter mais linhas e o ESPERADO, e a diferenca e o trabalho do dia.
  #
  # Problema seria o contrario -- backup com MAIS linhas que producao, que
  # significaria dado apagado depois do dump, ou dump de um estado estranho.
  #
  # A primeira versao comparava igualdade e gritou ATENCAO num backup impecavel.
  # Veredito errado assusta a toa e, pior, ensina a ignorar veredito.
  local iguais=0 atrasadas=0 a_mais=0 faltando=0
  while IFS='=' read -r tabela n; do
    [ -z "$tabela" ] && continue
    local m
    m="$(echo "$rest" | grep -E "^${tabela}=" | cut -d= -f2)"
    if [ -z "$m" ]; then
      printf "    %-34s %8s -> AUSENTE   <<< PROBLEMA
" "$tabela" "$n"
      faltando=$((faltando + 1))
    elif [ "$m" = "$n" ]; then
      iguais=$((iguais + 1))
    elif [ "$m" -lt "$n" ]; then
      printf "    %-34s %8s -> %-8s (+%s desde o backup)
" "$tabela" "$n" "$m" "$((n - m))"
      atrasadas=$((atrasadas + 1))
    else
      printf "    %-34s %8s -> %-8s <<< BACKUP A FRENTE, INVESTIGAR
" "$tabela" "$n" "$m"
      a_mais=$((a_mais + 1))
    fi
  done <<< "$prod"

  local total_linhas
  total_linhas="$(echo "$prod" | awk -F= '{s+=$2} END {print s+0}')"

  echo
  echo "  RESULTADO: $iguais igual(is), $atrasadas com movimento desde o backup,"
  echo "             $a_mais com o backup a frente, $faltando ausente(s)"
  echo "             $total_linhas linha(s) em producao"
  if [ "$a_mais" -eq 0 ] && [ "$faltando" -eq 0 ]; then
    echo "             >> BACKUP RESTAURAVEL E COMPLETO"
    [ "$atrasadas" -gt 0 ] && echo "                (a diferenca e o trabalho feito depois das 03:00)"
  else
    echo "             >> ATENCAO: investigar as linhas marcadas acima"
  fi

  echo
  echo "  apagando $alvo ..."
  psql_ -c "drop database $alvo" >/dev/null
  echo
}

# ---------------------------------------------------------------------------
# O LPCO nao e Postgres: e um SQLite num volume. O backup o copia pela API
# .backup() do proprio SQLite, que e o jeito certo com o banco em uso -- copiar
# o arquivo com cp enquanto alguem escreve produz um arquivo corrompido.
#
# Aqui a verificacao e mais forte do que a dos outros: alem de comparar linhas,
# o SQLite sabe auditar a propria estrutura com PRAGMA integrity_check. Se o
# arquivo tiver pagina corrompida, ele diz.
# ---------------------------------------------------------------------------
testar_lpco() {
  local arquivo="$PASTA/lpco_monitor.db"
  # Desde 2026-09-28 o backup guarda o SQLite comprimido.
  if [ ! -f "$arquivo" ] && [ -f "$arquivo.gz" ]; then
    gunzip -c "$arquivo.gz" > /tmp/restauracao_lpco.db
    arquivo=/tmp/restauracao_lpco.db
  fi
  echo "=============================================================="
  echo "BANCO: LPCO (SQLite)"
  echo "=============================================================="

  if [ ! -f "$arquivo" ]; then
    echo "  SEM BACKUP: $arquivo nao existe."
    return 1
  fi
  echo "  arquivo: $(du -h "$arquivo" | cut -f1)"

  # Mesmo metodo do backup: acha o container pelo arquivo que ele carrega.
  local LPCO=""
  for c in $(docker ps --format '{{.Names}}'); do
    if docker exec "$c" test -f /data/lpco_monitor.db 2>/dev/null; then LPCO="$c"; break; fi
  done
  if [ -z "$LPCO" ]; then
    echo "  ERRO: nao achei o container do LPCO."
    return 1
  fi
  echo "  container: $LPCO"

  docker cp "$arquivo" "$LPCO:/tmp/verificar_lpco.db" >/dev/null
  docker exec -i "$LPCO" python - <<'PY'
import sqlite3

def tabelas(con):
    return [r[0] for r in con.execute(
        "select name from sqlite_master where type='table' "
        "and name not like 'sqlite_%' order by name")]

bkp = sqlite3.connect("/tmp/verificar_lpco.db")
# Producao em somente leitura: este script nunca escreve em producao.
prod = sqlite3.connect("file:/data/lpco_monitor.db?mode=ro", uri=True)

veredito = bkp.execute("pragma integrity_check").fetchone()[0]
print("  integridade do arquivo: %s" % veredito)
print()
print("  COMPARACAO (tabela: producao -> backup)")

no_bkp = set(tabelas(bkp))
iguais = atrasadas = a_mais = faltando = 0
total = 0
for t in tabelas(prod):
    n = prod.execute('select count(*) from "%s"' % t).fetchone()[0]
    total += n
    if t not in no_bkp:
        print("    %-30s %8d -> AUSENTE   <<< PROBLEMA" % (t, n))
        faltando += 1
        continue
    m = bkp.execute('select count(*) from "%s"' % t).fetchone()[0]
    if m == n:
        iguais += 1
    elif m < n:
        print("    %-30s %8d -> %-8d (+%d desde o backup)" % (t, n, m, n - m))
        atrasadas += 1
    else:
        print("    %-30s %8d -> %-8d <<< BACKUP A FRENTE" % (t, n, m))
        a_mais += 1

print()
print("  RESULTADO: %d igual(is), %d com movimento desde o backup," % (iguais, atrasadas))
print("             %d com o backup a frente, %d ausente(s)" % (a_mais, faltando))
print("             %d linha(s) em producao" % total)
if veredito == "ok" and a_mais == 0 and faltando == 0:
    print("             >> BACKUP INTEGRO E COMPLETO")
    if atrasadas:
        print("                (a diferenca e o que o Siscomex mandou depois das 03:00)")
else:
    print("             >> ATENCAO: investigar as linhas marcadas acima")
PY

  docker exec "$LPCO" rm -f /tmp/verificar_lpco.db
  echo
}

# ---------------------------------------------------------------------------
if [ "${1:-}" = "--todos" ]; then
  for f in "$PASTA"/*.dump; do
    [ -e "$f" ] || continue
    nome="$(basename "$f" .dump)"
    testar_um "$nome"
  done
  testar_lpco
elif [ "${1:-}" = "--lpco" ]; then
  testar_lpco
else
  testar_um "${1:-portal_colaborador}"
fi

echo "=============================================================="
echo "Nada em producao foi alterado. Os bancos criados aqui comecam"
echo "com '${PREFIXO}_' e foram apagados ao fim de cada teste."
