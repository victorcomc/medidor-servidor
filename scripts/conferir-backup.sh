#!/usr/bin/env bash
#
# Confere se o backup da noite existe, esta completo e saiu do servidor -- e
# manda e-mail quando alguma dessas coisas nao for verdade.
#
# Backup automatico tem um defeito que quase nenhuma outra rotina tem: quando
# para, ninguem percebe. O cron nao reclama, o painel continua verde, e a falta
# so aparece no dia em que alguem precisa restaurar. Foi assim de julho a
# 17/09/2026: /data/coolify/backups vazia por dois meses sem ninguem saber.
#
# O backup.sh ja grita quando quebra no meio. Este script cobre o que ele nao
# consegue cobrir sozinho:
#   - ele nem ter rodado (cron apagado, servidor fora do ar no horario)
#   - ter "terminado" sem um dos bancos (a falta do LPCO, por exemplo, e so
#     AVISO la dentro -- o backup sai "Pronto" sem ele)
#   - um banco ter sumido da producao, ou um arquivo encolhido pela metade de
#     um dia para o outro -- dado apagado, que o backup copiaria obedientemente
#   - o disco chegando no limite em que o backup se recusa a comecar
#   - o PC da Hevile ter parado de puxar a copia para fora do servidor
#
# As segundas, se estiver tudo certo, manda um resumo curto. E ele que prova
# que o proprio conferidor esta vivo: segunda sem esse e-mail = ele parou.
#
# A senha do e-mail nao e copiada para lugar nenhum. O envio acontece DENTRO do
# container do LPCO, com as variaveis SMTP que ele ja tem -- as mesmas do
# alerta de relatorio. Quando a senha for trocada la, isto acompanha sozinho.
#
# Uso (no servidor):
#   ./conferir-backup.sh               # confere; e-mail so se houver problema
#   ./conferir-backup.sh --sem-email   # so imprime
#   ./conferir-backup.sh --teste       # confere e manda o e-mail de qualquer jeito
#
# No cron do root. 13:00 no relogio do servidor (UTC) = 10:00 em Recife: depois
# do backup (03:00 UTC) e da copia do PC (09:00 em Recife):
#   0 13 * * * ALERTA_PARA=voce@hevile.com.br /root/conferir-backup.sh >> /var/log/conferir-backup.log 2>&1
#
# Sem ALERTA_PARA, vai para o EMAIL_OPERACAO do LPCO.
# Sai com 1 quando ha problema, para o log do cron tambem registrar.
#
set -uo pipefail

ORIGEM="${ORIGEM:-/var/backups/hevile}"
# Recibo que o puxar-backup.ps1 deixa aqui ao terminar a copia. Comeca com
# ponto de proposito: a limpeza do backup.sh (20*), a listagem do PC
# (^\d{8}-\d{4}$) e o teste de restauracao (20*) passam reto por ele.
RECIBO_PC="$ORIGEM/.ultima-copia-externa"
# Folga para fim de semana e feriado emendado: o PC pode ficar desligado de
# quinta a segunda sem virar alarme. Mais que isso ja e protecao perdida.
DIAS_SEM_COPIA_PC="${DIAS_SEM_COPIA_PC:-4}"
# O backup.sh se recusa a comecar abaixo de 15GB. Avisar em 25 da tempo de
# limpar antes de a primeira noite falhar.
AVISAR_LIVRE_GB="${AVISAR_LIVRE_GB:-25}"
# Abaixo disto a variacao de tamanho de um dia para o outro e ruido de
# compressao, nao sinal. Banco pequeno oscila; banco grande nao cai pela metade.
MINIMO_PARA_COMPARAR=$((1024 * 1024))
# Recife escrito como regra POSIX, e nao como "America/Recife": o nome depende
# da tabela de fusos (tzdata) estar instalada, e sem ela o date cai em UTC
# calado. Esta forma funciona em qualquer maquina. Recife nao tem horario de
# verao desde 2019, entao -03 fixo e exato.
FUSO="<-03>3"

MODO="${1:-}"
problemas=()
avisar() { problemas+=("$1"); echo "  PROBLEMA: $1"; }

# 20260923-0300 (UTC, que e o relogio do servidor) -> "23/09 00:00" em Recife.
quando() {
  local n="$1"
  TZ="$FUSO" date -d "${n:0:4}-${n:4:2}-${n:6:2} ${n:9:2}:${n:11:2} UTC" '+%d/%m %H:%M'
}

tamanho() { stat -c %s "$1" 2>/dev/null || echo 0; }

# Com uma casa decimal: divisao inteira mostrava 1MB como "0MB", e num alerta
# isso le como arquivo vazio.
mb() { awk -v b="$1" 'BEGIN { printf "%.1fMB", b / 1048576 }'; }

escapar_html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

achar_lpco() {
  local c
  for c in $(docker ps --format '{{.Names}}'); do
    if docker exec "$c" test -f /data/lpco_monitor.db 2>/dev/null; then
      echo "$c"; return
    fi
  done
}

echo "=== Conferencia do backup — $(TZ="$FUSO" date '+%d/%m/%Y %H:%M') (Recife) ==="

mapfile -t pastas < <(find "$ORIGEM" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort)
hoje="$(date +%Y%m%d)"
# Indice calculado com guarda: com a pasta vazia, pastas[-1] derruba o bash --
# e pasta vazia e justamente o pior caso que isto existe para pegar.
nova=""; anterior=""
qtd=${#pastas[@]}
[ "$qtd" -ge 1 ] && nova="${pastas[$((qtd - 1))]}"
[ "$qtd" -ge 2 ] && anterior="${pastas[$((qtd - 2))]}"

# ── 1. Rodou hoje? ──────────────────────────────────────────────────────────
backup_de_hoje=0
if [ -z "$nova" ]; then
  avisar "Nao existe NENHUM backup em $ORIGEM."
elif [ "$(basename "$nova" | cut -c1-8)" != "$hoje" ]; then
  avisar "O backup de hoje nao foi feito. O mais recente e de $(quando "$(basename "$nova")")."
else
  backup_de_hoje=1
  echo "  backup de hoje: $(basename "$nova")"
fi

# ── 2. Esta completo? ───────────────────────────────────────────────────────
# So confere o conteudo do backup de HOJE. Se ele nem existe, apontar falta de
# arquivo num backup antigo seria repetir o problema acima com outras palavras.
if [ "$backup_de_hoje" -eq 1 ]; then
  [ -s "$nova/globais.sql" ] \
    || avisar "Falta o globais.sql (usuarios e senhas do Postgres) no backup de hoje."

  # Mesmo metodo do backup.sh, de proposito: se um acha, o outro acha.
  PG="$(docker ps --format '{{.Names}}	{{.Image}}' \
        | grep -i postgres | grep -v '^coolify' | head -1 | cut -f1 || true)"
  if [ -z "$PG" ]; then
    avisar "Nao achei o container do Postgres. Os sistemas estao no ar?"
  else
    # Compara com a lista VIVA de bancos, e nao com a de ontem: banco criado
    # hoje de manha que o backup nao pegou tambem tem de aparecer.
    bancos="$(docker exec "$PG" psql -U postgres -tAc \
      "select datname from pg_database where datistemplate = false
         and datname <> 'postgres' and datname not like 'restauracao_teste_%'")"
    n_bancos=0
    for b in $bancos; do
      n_bancos=$((n_bancos + 1))
      [ -s "$nova/$b.dump" ] || avisar "O banco '$b' esta no ar mas NAO entrou no backup de hoje."
    done
    echo "  bancos no ar: $n_bancos"
  fi

  # .gz desde 2026-09-28; o .db cru vale para as pastas de antes.
  { [ -s "$nova/lpco_monitor.db.gz" ] || [ -s "$nova/lpco_monitor.db" ]; } \
    || avisar "O banco do Lancamento LPCO (SQLite) NAO entrou no backup de hoje."
fi

# ── 3. Algo sumiu ou encolheu desde ontem? ──────────────────────────────────
# Backup copia o que existe. Se alguem apagar metade de uma tabela, o backup da
# noite seguinte sai "completo" e menor -- e em 14 dias a limpeza leva embora a
# ultima copia boa. Esta e a janela para perceber.
if [ "$backup_de_hoje" -eq 1 ] && [ -n "$anterior" ]; then
  for f in "$anterior"/*.dump "$anterior"/lpco_monitor.db*; do
    [ -e "$f" ] || continue
    nome="$(basename "$f")"
    case "$nome" in restauracao_teste_*) continue ;; esac
    antes="$(tamanho "$f")"
    agora="$(tamanho "$nova/$nome")"
    if [ ! -e "$nova/$nome" ]; then
      # So chega aqui banco que sumiu da PRODUCAO: os que estao no ar e
      # faltam no backup ja foram apontados na etapa 2.
      # lpco_monitor.db de ontem x .db.gz de hoje e so a troca de formato.
      if [ "${nome#lpco_monitor.db}" = "$nome" ] && [ -n "${PG:-}" ] \
         && ! grep -qx "${nome%.dump}" <<< "${bancos:-}"; then
        avisar "O banco '${nome%.dump}' existia ontem e SUMIU da producao. Se nao foi de proposito, a copia de ontem ainda esta em $anterior."
      fi
    elif [ "$antes" -ge "$MINIMO_PARA_COMPARAR" ] && [ $((agora * 2)) -lt "$antes" ]; then
      avisar "'$nome' encolheu de $(mb "$antes") para $(mb "$agora") de ontem para hoje. Dado apagado? A copia de ontem esta em $anterior."
    fi
  done
fi

# ── 4. Os arquivos anexados (so aos domingos) ───────────────────────────────
# Confere a copia MAIS RECENTE de volumes, e nao a de domingo: assim um domingo
# perdido e notado na segunda, na terca... e nao so no domingo seguinte.
ultima_vol=""
for p in "${pastas[@]}"; do
  [ -n "$(find "$p/volumes" -type f 2>/dev/null | head -1)" ] && ultima_vol="$p"
done
if [ -z "$ultima_vol" ]; then
  avisar "Nenhum backup tem os arquivos anexados (comprovantes, notas). Eles saem aos domingos."
else
  n="$(basename "$ultima_vol")"
  idade_vol=$(( ( $(date +%s) - $(date -d "${n:0:8}" +%s) ) / 86400 ))
  echo "  anexos: ultima copia em $(quando "$n") ($idade_vol dia(s))"
  [ "$idade_vol" -gt 8 ] \
    && avisar "A ultima copia dos arquivos anexados tem $idade_vol dias. A de domingo nao saiu."
fi

# ── 5. Disco ────────────────────────────────────────────────────────────────
livre_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
echo "  disco livre: ${livre_gb}GB"
[ "$livre_gb" -lt "$AVISAR_LIVRE_GB" ] \
  && avisar "So ${livre_gb}GB livres no disco. Abaixo de 15GB o backup se recusa a rodar."

# ── 6. A copia saiu do servidor? ────────────────────────────────────────────
# O backup acima mora no MESMO disco que a producao. Se o PC parou de puxar, a
# Hevile voltou a ter os dados num lugar so -- e nada no servidor percebe isso,
# a nao ser este recibo parando de ser renovado.
if [ ! -f "$RECIBO_PC" ]; then
  avisar "O PC nunca registrou uma copia aqui. A copia fora do servidor pode nao estar acontecendo."
else
  idade_pc=$(( ( $(date +%s) - $(stat -c %Y "$RECIBO_PC") ) / 86400 ))
  echo "  copia no PC: $(TZ="$FUSO" date -d "@$(stat -c %Y "$RECIBO_PC")" '+%d/%m %H:%M') ($idade_pc dia(s))"
  [ "$idade_pc" -gt "$DIAS_SEM_COPIA_PC" ] \
    && avisar "Faz $idade_pc dias que o PC nao puxa o backup. A unica copia esta no proprio servidor."
fi

echo
echo "  ${#problemas[@]} problema(s)"

# ── E-mail ──────────────────────────────────────────────────────────────────
e_segunda=0; [ "$(date +%u)" = "1" ] && e_segunda=1

if [ "$MODO" = "--sem-email" ]; then
  exit $(( ${#problemas[@]} > 0 ))
fi
if [ "${#problemas[@]}" -eq 0 ] && [ "$e_segunda" -eq 0 ] && [ "$MODO" != "--teste" ]; then
  exit 0
fi

corpo="$(mktemp)"
trap 'rm -f "$corpo"' EXIT
{
  if [ "${#problemas[@]}" -gt 0 ]; then
    assunto="[ALERTA] Backup da Hevile: ${#problemas[@]} problema(s)"
    echo "<h2>⚠ O backup precisa de atenção</h2><ul>"
    for p in "${problemas[@]}"; do echo "<li>$(escapar_html <<< "$p")</li>"; done
    echo "</ul>"
    echo "<p>Os sistemas continuam funcionando normalmente — o que está em risco é"
    echo "a <strong>cópia de segurança</strong>. Enquanto isto não for resolvido, esta"
    echo "conferência repete o aviso todo dia às 10:00. É de propósito.</p>"
  else
    assunto="Backup da Hevile: tudo certo"
    echo "<h2>✓ Backup em dia</h2>"
    echo "<p>Este resumo chega toda segunda. <strong>Se numa segunda ele não chegar,</strong>"
    echo "foi a própria conferência que parou — e aí não há mais quem avise.</p>"
  fi
  [ "$MODO" = "--teste" ] && assunto="[TESTE] $assunto"

  echo "<h3>Últimos backups</h3><table cellpadding='4' style='border-collapse:collapse'>"
  # Inicio calculado, e nao "${pastas[@]: -7}": com menos de 7 pastas o bash
  # devolve NADA nessa forma -- a tabela sumia justo quando ha poucos backups.
  inicio=$(( qtd > 7 ? qtd - 7 : 0 ))
  for p in "${pastas[@]:$inicio}"; do
    echo "<tr><td>$(quando "$(basename "$p")")</td><td align='right'>$(du -sh "$p" | cut -f1)</td></tr>"
  done
  echo "</table>"
  echo "<p>Disco livre: ${livre_gb}GB"
  [ -f "$RECIBO_PC" ] && echo "<br>Última cópia no PC: $(TZ="$FUSO" date -d "@$(stat -c %Y "$RECIBO_PC")" '+%d/%m às %H:%M')"
  echo "</p>"

  if [ "${#problemas[@]}" -gt 0 ] && [ -f /var/log/backup-hevile.log ]; then
    echo "<h3>Fim do log do backup</h3><pre style='font-size:12px'>"
    tail -n 20 /var/log/backup-hevile.log | escapar_html
    echo "</pre>"
  fi
  echo "<p style='color:#888;font-size:12px'>conferir-backup.sh — servidor Hevile</p>"
} > "$corpo"

LPCO="$(achar_lpco)"
if [ -z "$LPCO" ]; then
  # Unico caso em que o aviso nao sai. Fica no log do cron, que e o que resta.
  echo "ERRO: nao achei o container do LPCO, que e por onde o e-mail sai." >&2
  echo "      O aviso acima NAO foi enviado." >&2
  exit 1
fi

docker exec -i -e ASSUNTO="$assunto" -e PARA="${ALERTA_PARA:-}" "$LPCO" python -c '
import os, smtplib, sys
from email.mime.text import MIMEText

para = os.environ.get("PARA") or os.environ.get("EMAIL_OPERACAO", "")
if not para:
    sys.exit("ERRO: sem destinatario. Defina ALERTA_PARA na linha do cron.")

msg = MIMEText("<html><body>" + sys.stdin.read() + "</body></html>", "html", "utf-8")
msg["Subject"] = os.environ["ASSUNTO"]
msg["From"] = os.environ["SMTP_USER"]
msg["To"] = para

with smtplib.SMTP(os.environ.get("SMTP_HOST", "smtp.office365.com"),
                  int(os.environ.get("SMTP_PORT", "587")), timeout=30) as smtp:
    smtp.ehlo()
    smtp.starttls()
    smtp.login(os.environ["SMTP_USER"], os.environ["SMTP_APP_PASSWORD"])
    smtp.sendmail(os.environ["SMTP_USER"],
                  [e.strip() for e in para.split(",") if e.strip()], msg.as_string())
print("  e-mail enviado para %s" % para)
' < "$corpo" || { echo "ERRO: o e-mail falhou (acima)." >&2; exit 1; }

exit $(( ${#problemas[@]} > 0 ))
