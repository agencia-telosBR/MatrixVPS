"""Matrix Sniper V3 core: ontology, query planning, entity normalization and deterministic scoring."""
from __future__ import annotations
import hashlib, json, math, re, unicodedata
from datetime import datetime, timezone

SERVICE_ONTOLOGY = {
    "chiller_rental": ["locação de chiller","locacao de chiller","aluguel de chiller","chiller temporário","chiller temporario","chiller para contingência","chiller para contingencia"],
    "chiller_maintenance": ["manutenção de chiller","manutencao de chiller","assistência técnica chiller","assistencia tecnica chiller","manutenção preventiva chiller","manutencao preventiva chiller","manutenção corretiva chiller"],
    "chiller_emergency": ["emergência chiller","emergencia chiller","atendimento 24h","parada de chiller","contingência","contingencia"],
    "chiller_installation": ["instalação de chiller","instalacao de chiller","comissionamento","start-up","startup","instalação cag","instalacao cag"],
    "chiller_retrofit": ["retrofit de chiller","modernização de chiller","modernizacao de chiller","troca de compressor","troca de controle"],
    "industrial_refrigeration": ["refrigeração industrial","refrigeracao industrial","sistemas de refrigeração para indústria","sistemas de refrigeracao para industria"],
    "hvac_industrial": ["hvac industrial","climatização industrial","climatizacao industrial","sistemas de água gelada","sistemas de agua gelada"],
    "cold_rooms": ["câmara fria","camara fria","refrigeração comercial","refrigeracao comercial","conservação térmica","conservacao termica"],
    "cooling_tower": ["torre de resfriamento","manutenção de torre","manutencao de torre","sistema de condensação","sistema de condensacao"],
    "fan_coil_cag": ["fan coil","central de água gelada","central de agua gelada","cag","água gelada","agua gelada"],
}

NEGATIVE_TERMS = [
    "ar condicionado automotivo","automotivo","funilaria","mecânica automotiva","mecanica automotiva",
    "higienização de split","higienizacao de split","limpeza de split","geladeira","eletrodoméstico","eletrodomestico",
    "refrigerador doméstico","refrigerador domestico",
]

B2B_SECTORS = {
    "industria":["indústria","industria","industrial","fábrica","fabrica"],
    "alimentos_bebidas":["alimentos","bebidas","frigorífico","frigorifico","laticínio","laticinio"],
    "farmaceutico":["farmacêut","farmaceut","laboratório","laboratorio"],
    "hospitalar":["hospital","hospitalar","clínica","clinica"],
    "data_center":["data center","datacenter"],
    "shopping":["shopping","varejo"],
    "logistica_refrigerada":["logística refrigerada","logistica refrigerada","armazenagem refrigerada","centro de distribuição","centro de distribuicao"],
    "hotelaria":["hotel","resort"],
}

MATURITY_SIGNALS = {
    "strong": {
        "multiple_units":["unidades","filiais","nossas unidades"],
        "large_cases":["grandes projetos","case","cases","projetos realizados","clientes"],
        "fleet":["frota","equipamentos próprios","equipamentos proprios"],
        "headcount":["colaboradores","equipe de","profissionais"],
        "revenue":["faturamento","receita anual"],
    },
    "medium": {
        "multi_state":["todo brasil","atendimento nacional","em todo o brasil","multiestado","todo território nacional","todo territorio nacional"],
        "engineering":["engenharia própria","engenharia propria","equipe de engenharia","engenheiros"],
        "certifications":["certificação","certificacao","iso 9001","pmoc","nr-10","nr10","nr-35","nr35"],
        "service_lines":["locação","locacao","manutenção","manutencao","instalação","instalacao","retrofit","projeto"],
        "jobs":["trabalhe conosco","vagas","carreiras"],
    },
    "weak": {
        "24h":["24h","24 horas","plantão","plantao"],
        "years":["anos de mercado","anos de experiência","anos de experiencia"],
        "professional_site":["serviços","servicos","soluções","solucoes","quem somos","contato"],
    },
}

TRIGGER_KEYWORDS = {
    "hiring":["vaga","vagas","contratando","oportunidade de emprego","trabalhe conosco","carreiras"],
    "expansion":["nova unidade","inauguração","inauguracao","expansão","expansao","nova filial","nova região","nova regiao","ampliação","ampliacao"],
    "offer":["novo serviço","novo servico","lançamento","lancamento","agora oferecemos","nova solução","nova solucao"],
    "market":["feira","certificação","certificacao","parceria","novo contrato","case recente","premiação","premiacao"],
    "website":["nova página","nova pagina","novo segmento"],
}

ROLE_PATTERNS = {
    "owner_found":["sócio","socio","proprietário","proprietario","fundador","ceo"],
    "commercial_leader":["diretor comercial","gerente comercial","head comercial","comercial"],
    "operations_leader":["diretor de operações","diretor de operacoes","gerente de operações","gerente de operacoes","engenharia","manutenção","manutencao"],
    "marketing_contact":["marketing","growth","aquisição","aquisicao"],
}

def norm(value):
    value = unicodedata.normalize("NFKD", str(value or ""))
    return " ".join("".join(c for c in value if not unicodedata.combining(c)).lower().split())

def canonical_domain(url):
    if not url: return None
    raw=str(url).strip().lower()
    raw=re.sub(r"^https?://","",raw)
    raw=raw.split("/")[0].split("?")[0].split("#")[0]
    raw=raw.split("@")[-1].split(":")[0]
    raw=re.sub(r"^www\.","",raw)
    return raw or None

def digits(value):
    return re.sub(r"\D","",str(value or ""))

def normalize_phone(value):
    d=digits(value)
    if d.startswith("00"): d=d[2:]
    if len(d) in (10,11): d="55"+d
    return d if 12 <= len(d) <= 13 else None

def name_key(name):
    t=norm(name)
    t=re.sub(r"\b(ltda|me|eireli|sa|s a|servicos|serviços|solucoes|soluções)\b"," ",t)
    return re.sub(r"[^a-z0-9]+"," ",t).strip()

def content_hash(text):
    return hashlib.sha256(str(text or "").encode("utf-8","ignore")).hexdigest()

def json_hash(obj):
    return hashlib.sha256(json.dumps(obj,ensure_ascii=False,sort_keys=True,default=str).encode()).hexdigest()

def service_hits(text):
    t=norm(text)
    out={}
    for sid,terms in SERVICE_ONTOLOGY.items():
        hits=sorted({term for term in terms if norm(term) in t})
        if hits: out[sid]=hits
    return out

def negative_hits(text):
    t=norm(text)
    return sorted({term for term in NEGATIVE_TERMS if norm(term) in t})

def sector_hits(text):
    t=norm(text);out={}
    for sid,terms in B2B_SECTORS.items():
        hits=[x for x in terms if norm(x) in t]
        if hits: out[sid]=hits
    return out

def maturity_hits(text):
    t=norm(text); out={"strong":[],"medium":[],"weak":[]}
    for level,groups in MATURITY_SIGNALS.items():
        for key,terms in groups.items():
            if any(norm(term) in t for term in terms):
                out[level].append(key)
    return out

def trigger_hits(text):
    t=norm(text);out={}
    for typ,terms in TRIGGER_KEYWORDS.items():
        hits=[x for x in terms if norm(x) in t]
        if hits:out[typ]=hits
    return out

def query_plan(city,state=None,neighborhoods=None,service_ids=None):
    service_ids=service_ids or list(SERVICE_ONTOLOGY)
    neighborhoods=[x for x in (neighborhoods or []) if str(x).strip()]
    scopes=[city]+[f"{n}, {city}" for n in neighborhoods]
    queries=[];seen=set()
    for sid in service_ids:
        terms=SERVICE_ONTOLOGY.get(sid) or []
        for term in terms[:3]:
            for scope in scopes:
                q=f"{term} {scope}" + (f" {state}" if state else "")
                k=norm(q)
                if k not in seen:
                    seen.add(k);queries.append({"service_id":sid,"query":q,"scope":scope})
    return queries

def classify_recency(published_at, observed_at=None):
    if not published_at:return {"days":None,"weight":0.0,"usable_reason_now":False}
    now=observed_at or datetime.now(timezone.utc)
    if isinstance(published_at,str):
        try:published_at=datetime.fromisoformat(published_at.replace("Z","+00:00"))
        except ValueError:return {"days":None,"weight":0.0,"usable_reason_now":False}
    if published_at.tzinfo is None:published_at=published_at.replace(tzinfo=timezone.utc)
    days=max(0,(now-published_at).days)
    if days<=30:return {"days":days,"weight":1.0,"usable_reason_now":True}
    if days<=90:return {"days":days,"weight":0.8,"usable_reason_now":True}
    if days<=180:return {"days":days,"weight":0.5,"usable_reason_now":True}
    return {"days":days,"weight":0.1,"usable_reason_now":False}

def tier_for(score):
    if score>=85:return "A+"
    if score>=75:return "A"
    if score>=65:return "B"
    return "C"

def _clamp(v,lo=0,hi=100):return max(lo,min(hi,int(round(v))))

def deterministic_score(ctx):
    """Transparent 0-100 score from evidence-backed dimensions."""
    services=ctx.get("services_confirmed") or []
    b2b=bool(ctx.get("b2b_confirmed"))
    negatives=ctx.get("negative_signals") or []
    entity_ok=bool(ctx.get("entity_resolution_ok"))
    active=ctx.get("active",True) is not False
    source_count=int(ctx.get("source_count") or 0)
    primary_sources=int(ctx.get("primary_source_count") or 0)
    source_types=set(ctx.get("source_types") or [])
    has_google=bool((ctx.get("google_presence") or {}).get("queries_checked"))

    hard_gate_reasons=[]
    if not b2b:hard_gate_reasons.append("Operação B2B compatível não confirmada")
    if not services:hard_gate_reasons.append("Nenhum serviço-alvo confirmado")
    if not active:hard_gate_reasons.append("Conta sem evidência operacional/ativa")
    if not entity_ok:hard_gate_reasons.append("Entity resolution pendente ou ambígua")
    if not ((primary_sources>=1 and has_google) or len(source_types)>=2):
        hard_gate_reasons.append("Fontes insuficientes: exigir Google Maps + fonte primária ou duas fontes independentes")
    if any(x.get("severity")=="reject" for x in negatives if isinstance(x,dict)):hard_gate_reasons.append("Sinal negativo eliminatório")

    # ICP 30
    service_depth=min(len(services),4)/4
    sector_factor=1.0 if ctx.get("segments_served") else 0.65
    geo_factor=1.0 if ctx.get("geography_evidenced") else 0.7
    icp=30*(0.55*service_depth+0.25*(1 if b2b else 0)+0.10*sector_factor+0.10*geo_factor)

    # Google opportunity 25: higher gap = stronger opportunity, but require observations.
    gp=ctx.get("google_presence") or {}
    checked=int(gp.get("queries_checked") or 0)
    coverage=float(gp.get("coverage_score") or 0)
    comp_gap=float(gp.get("competitive_gap_score") or 0)
    rep_gap=float(gp.get("reputation_gap_score") or 0)
    site_gap=float(gp.get("site_gap_score") or 0)
    opp_raw=(max(0,100-coverage)*0.45+comp_gap*0.25+rep_gap*0.15+site_gap*0.15) if checked else 0
    google=25*opp_raw/100

    # maturity 20
    mat=ctx.get("maturity") or {}
    b2bmat=float(mat.get("b2b_maturity_score") or ctx.get("b2b_maturity_score") or 0)
    industrial=float(mat.get("industrial_depth_score") or ctx.get("industrial_depth_score") or 0)
    maturity=20*(0.6*b2bmat+0.4*industrial)/100

    # timing 15
    triggers=ctx.get("trigger_signals") or []
    tw=0.0
    if triggers:
        weights=[float(x.get("recency_weight") or 0)*float(x.get("relevance_weight") or 0.7) for x in triggers]
        tw=max(weights or [0])
        if len([w for w in weights if w>=0.5])>=2:tw=min(1.0,tw+0.15)
    timing=15*tw

    # research confidence 10
    conf=float(ctx.get("research_confidence") or 0)
    confidence=10*max(0,min(1,conf))

    penalties=[]
    if not services:penalties.append({"reason":"Serviço-alvo não confirmado","points":-25})
    if ctx.get("solo_operation"):penalties.append({"reason":"Operação muito pequena/solo sem sinais B2B","points":-15})
    if ctx.get("weak_web_profile"):penalties.append({"reason":"Website inativo + perfil fraco + baixa confiança","points":-10})
    if ctx.get("contradictions"):penalties.append({"reason":"Dados contraditórios sem resolução","points":-10})
    if ctx.get("duplicate_conflict"):hard_gate_reasons.append("Conta duplicada não resolvida")

    raw=icp+google+maturity+timing+confidence+sum(x["points"] for x in penalties)
    score=_clamp(raw)
    passed=not hard_gate_reasons
    if not passed:score=min(score,64)
    tier=tier_for(score)
    recommendation="APPROVE" if passed and tier in ("A","A+") else ("REVIEW" if tier=="B" or (passed and score>=60) else "REJECT")
    return {
        "score":score,"tier":tier,"recommendation":recommendation,"hard_gates_passed":passed,
        "hard_gate_reasons":hard_gate_reasons,"penalties":penalties,
        "breakdown":{
            "icp_fit":{"points":round(icp,2),"max":30},
            "google_opportunity":{"points":round(google,2),"max":25},
            "commercial_maturity":{"points":round(maturity,2),"max":20},
            "timing_reason_now":{"points":round(timing,2),"max":15},
            "research_confidence":{"points":round(confidence,2),"max":10},
        }
    }
