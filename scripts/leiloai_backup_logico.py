"""Backup logico das tabelas criticas do LeiloAI via Management API.

Nao precisa da senha do Postgres: usa o token sbp_ (mesmo caminho do SQL Editor).
Cobre exatamente o que se perdeu no incidente de 03/08 (contas, assinaturas,
alertas). Tabelas de raspagem (items, judicial_status, market_comparables)
ficam de fora de proposito: sao re-scrapaveis e inflariam o dump.
"""
import json, gzip, io, os, re, sys, urllib.request, urllib.error, datetime

S = os.path.dirname(os.path.abspath(__file__))
SBP = os.environ["SUPABASE_MGMT_TOKEN"].strip()
CF = os.environ["CF_TOKEN"].strip()
REF = os.environ.get("SUPABASE_REF", "eznfhbdkadcuyjhmcrxp").strip()
ACCOUNT = os.environ["CF_ACCOUNT"].strip()
_b = (os.environ.get("CF_R2_BUCKET") or "").strip()
# O secret CF_R2_BUCKET contem valor invalido (a API respondeu
# "The specified bucket name is not valid"). Cai no default em vez de
# quebrar o backup por causa de um secret mal preenchido.
BUCKET = _b if re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", _b or "") else "leiloai-backups"

TABELAS = [
    ("auth.users", "select id,email,created_at,updated_at,last_sign_in_at,"
                   "confirmed_at,email_confirmed_at,raw_user_meta_data,"
                   "raw_app_meta_data,is_sso_user,deleted_at from auth.users"),
    ("auth.identities", "select id,user_id,provider,provider_id,identity_data,"
                        "created_at,last_sign_in_at from auth.identities"),
    ("public.users", "select * from public.users"),
    ("public.subscriptions", "select * from public.subscriptions"),
    ("public.alerts", "select * from public.alerts"),
    ("public.watchers", "select * from public.watchers"),
    ("public.favorites", "select * from public.favorites"),
    ("public.signup_attempts", "select * from public.signup_attempts"),
    ("public.free_item_unlocks", "select * from public.free_item_unlocks"),
    ("public.conteudo_editorial", "select * from public.conteudo_editorial"),
    ("public.sources", "select * from public.sources"),
    ("public.stripe_webhook_events", "select * from public.stripe_webhook_events"),
    ("public.admin_audit_log", "select * from public.admin_audit_log"),
    ("public.opportunity_scores", "select * from public.opportunity_scores"),
    ("public.rental_estimates", "select * from public.rental_estimates"),
    ("public.programmatic_intro_cache", "select * from public.programmatic_intro_cache"),
]


def sql(q):
    body = json.dumps({"query": q}).encode()
    r = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=body, method="POST")
    r.add_header("Authorization", "Bearer " + SBP)
    r.add_header("Content-Type", "application/json")
    # Sem User-Agent proprio a API responde 403 (bloqueia o UA padrao do urllib).
    r.add_header("User-Agent", "leiloai-backup/1.0")
    with urllib.request.urlopen(r, timeout=180) as resp:
        return json.loads(resp.read())


dump = {"gerado_em": datetime.datetime.utcnow().isoformat() + "Z",
        "projeto": REF, "tabelas": {}}
total = 0
for nome, q in TABELAS:
    try:
        linhas = sql(q)
        if isinstance(linhas, dict) and linhas.get("message"):
            print(f"  ! {nome}: {linhas['message'][:80]}")
            continue
        dump["tabelas"][nome] = linhas
        total += len(linhas)
        print(f"  {len(linhas):>7} linhas  {nome}")
    except Exception as e:
        print(f"  ! {nome}: {e}")

bruto = json.dumps(dump, ensure_ascii=False, default=str).encode()
buf = io.BytesIO()
with gzip.GzipFile(fileobj=buf, mode="wb") as g:
    g.write(bruto)
comprimido = buf.getvalue()
print(f"\ntotal {total} linhas | {len(bruto)/1e6:.1f} MB cru | {len(comprimido)/1e6:.2f} MB gz")

# Mesma licao do workflow quebrado: nunca subir "backup" vazio como se fosse bom.
usuarios = len(dump["tabelas"].get("auth.users") or [])
if usuarios < 100:
    sys.exit(f"ABORTADO: dump com {usuarios} usuarios (esperado 200+). Nada foi enviado.")

agora = datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
chave = f"postgres/logico_{agora}.json.gz"
req = urllib.request.Request(
    f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects/{chave}",
    data=comprimido, method="PUT")
req.add_header("Authorization", "Bearer " + CF)
req.add_header("Content-Type", "application/gzip")
try:
    with urllib.request.urlopen(req, timeout=300) as resp:
        r = json.loads(resp.read())
except urllib.error.HTTPError as e:
    sys.exit(f"upload R2 falhou: HTTP {e.code} {e.read().decode()[:300]}")
print("upload R2:", r.get("success"), r.get("result", {}).get("key"),
      r.get("result", {}).get("size"), "bytes")

# Retencao: mantem os 90 backups mais recentes. Sem isso o bucket cresce pra
# sempre (2,25 MB/dia = ~820 MB/ano). O free tier do R2 sao 10 GB, entao nao e
# urgente, mas backup sem politica de retencao vira lixo acumulado.
MANTER = 90
try:
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects?prefix=postgres/logico_&per_page=1000")
    req.add_header("Authorization", "Bearer " + CF)
    objetos = json.loads(urllib.request.urlopen(req, timeout=60).read()).get("result") or []
    antigos = sorted(objetos, key=lambda o: o["key"])[:-MANTER]
    for o in antigos:
        d = urllib.request.Request(
            f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects/{o['key']}",
            method="DELETE")
        d.add_header("Authorization", "Bearer " + CF)
        urllib.request.urlopen(d, timeout=60)
    if antigos:
        print(f"retencao: {len(antigos)} backup(s) antigo(s) removido(s), {MANTER} mantidos")
except Exception as e:
    # Falha na limpeza NAO invalida o backup do dia.
    print("aviso: retencao falhou:", e)
