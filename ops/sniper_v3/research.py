"""Matrix Sniper V3 research engine.
Collects public evidence, resolves accounts, builds Google opportunity, maturity, signals,
contacts, deterministic score and versioned Account Research Pack.
"""
from __future__ import annotations
import asyncio, email.utils, hashlib, html, json, os, re, time, urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib import robotparser

from .core import (
    SERVICE_ONTOLOGY, ROLE_PATTERNS, canonical_domain, classify_recency, content_hash,
    deterministic_score, maturity_hits, name_key, negative_hits, norm, normalize_phone,
    sector_hits, service_hits, trigger_hits, json_hash
)

USER_AGENT="MatrixSniper/3.0 (+Account Research; respectful crawler)"
DEFAULT_TIMEOUT=12
MAX_BODY=2_000_000

class TextHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text=[]; self.links=[]; self.title=""; self._in_title=False
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=="a" and attrs.get("href"):self.links.append(attrs["href"])
        if tag=="title":self._in_title=True
    def handle_endtag(self,tag):
        if tag=="title":self._in_title=False
    def handle_data(self,data):
        d=" ".join(str(data or "").split())
        if d:
            self.text.append(d)
            if self._in_title:self.title += (" " if self.title else "")+d

def utcnow():return datetime.now(timezone.utc)

def _json(obj):return json.dumps(obj,ensure_ascii=False,default=str)

def _fetch_url(url, timeout=DEFAULT_TIMEOUT, max_bytes=MAX_BODY):
    req=urllib.request.Request(url,headers={"User-Agent":USER_AGENT,"Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.7"})
    started=time.monotonic()
    with urllib.request.urlopen(req,timeout=timeout) as resp:
        ctype=(resp.headers.get("Content-Type") or "").lower()
        body=resp.read(max_bytes+1)
        if len(body)>max_bytes:raise ValueError("body_too_large")
        charset=resp.headers.get_content_charset() or "utf-8"
        try:text=body.decode(charset,errors="replace")
        except LookupError:text=body.decode("utf-8",errors="replace")
        return {
            "url":resp.geturl(),"status":getattr(resp,"status",200),"content_type":ctype,
            "text":text,"duration_ms":int((time.monotonic()-started)*1000),
            "etag":resp.headers.get("ETag"),"last_modified":resp.headers.get("Last-Modified"),
        }

def _robots_allowed(url):
    p=urllib.parse.urlsplit(url)
    robots=f"{p.scheme}://{p.netloc}/robots.txt"
    rp=robotparser.RobotFileParser()
    rp.set_url(robots)
    try:
        rp.read()
        return rp.can_fetch(USER_AGENT,url)
    except Exception:
        return True

def _cache_get(conn,url):
    with conn.cursor() as cur:
        cur.execute("""SELECT url,status_code,content_type,body_text,content_hash,fetched_at,expires_at,error
                       FROM matrix_source_cache WHERE url=%s AND expires_at>now() ORDER BY fetched_at DESC LIMIT 1""",(url,))
        return cur.fetchone()

def _cache_put(conn,url,result,ttl_days=14,error=None):
    body=(result or {}).get("text") if result else None
    h=content_hash(body) if body is not None else None
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO matrix_source_cache(url,status_code,content_type,body_text,content_hash,fetched_at,expires_at,duration_ms,error)
                       VALUES(%s,%s,%s,%s,%s,now(),now()+(%s||' days')::interval,%s,%s)
                       ON CONFLICT(url) DO UPDATE SET
                         status_code=excluded.status_code,content_type=excluded.content_type,body_text=excluded.body_text,
                         content_hash=excluded.content_hash,fetched_at=excluded.fetched_at,expires_at=excluded.expires_at,
                         duration_ms=excluded.duration_ms,error=excluded.error""",
                    (url,(result or {}).get("status"),(result or {}).get("content_type"),body,h,ttl_days,(result or {}).get("duration_ms"),error))

def fetch_cached(conn,url,ttl_days=14):
    cached=_cache_get(conn,url)
    if cached:
        return {"url":url,"status":cached["status_code"],"content_type":cached["content_type"],"text":cached["body_text"] or "",
                "duration_ms":0,"cached":True,"content_hash":cached["content_hash"],"error":cached["error"]}
    if not _robots_allowed(url):
        _cache_put(conn,url,{},ttl_days=1,error="robots_disallowed")
        return {"url":url,"status":None,"content_type":None,"text":"","duration_ms":0,"cached":False,"error":"robots_disallowed"}
    last=None
    for attempt in range(3):
        try:
            result=_fetch_url(url)
            _cache_put(conn,url,result,ttl_days=ttl_days)
            result["cached"]=False;result["content_hash"]=content_hash(result["text"]);return result
        except urllib.error.HTTPError as e:
            last=f"http_{e.code}"
            if e.code in (403,404,410):break
        except (urllib.error.URLError,TimeoutError,OSError,ValueError) as e:
            last=type(e).__name__
        time.sleep(min(4,0.7*(2**attempt)))
    _cache_put(conn,url,{},ttl_days=1,error=last or "fetch_failed")
    return {"url":url,"status":None,"content_type":None,"text":"","duration_ms":0,"cached":False,"error":last or "fetch_failed"}

def parse_html_page(raw,base_url):
    p=TextHTMLParser()
    try:p.feed(raw or "")
    except Exception:pass
    text=" ".join(p.text)
    links=[]
    for href in p.links:
        try:
            u=urllib.parse.urljoin(base_url,href)
            parts=urllib.parse.urlsplit(u)
            if parts.scheme in ("http","https"):links.append(urllib.parse.urlunsplit((parts.scheme,parts.netloc,parts.path,parts.query,"")))
        except Exception:pass
    return {"title":p.title[:500],"text":text[:600_000],"links":list(dict.fromkeys(links))}

def priority_score(url):
    path=norm(urllib.parse.urlsplit(url).path.replace("-"," ").replace("_"," "))
    high=["servico","solucao","chiller","refrigeracao industrial","hvac","locacao","manutencao","retrofit","projeto","case","quem somos"]
    med=["cliente","segmento","certificacao","parceiro","marca","unidade","contato","trabalhe conosco","carreira","vaga"]
    low=["blog","noticia","news"]
    if any(x in path for x in high):return 100
    if any(x in path for x in med):return 70
    if any(x in path for x in low):return 40
    if path in ("","/"):return 110
    return 10

def discover_site_urls(conn,website_url,max_pages=14):
    if not website_url:return []
    if not website_url.startswith(("http://","https://")):website_url="https://"+website_url
    root=urllib.parse.urlsplit(website_url)
    base=f"{root.scheme}://{root.netloc}/"
    urls=[base]
    # sitemap first
    for sm in (urllib.parse.urljoin(base,"sitemap.xml"),urllib.parse.urljoin(base,"sitemap_index.xml")):
        r=fetch_cached(conn,sm,ttl_days=7)
        if r.get("status")==200 and "<loc>" in (r.get("text") or ""):
            try:
                rootxml=ET.fromstring(r["text"])
                locs=[x.text.strip() for x in rootxml.iter() if x.tag.endswith("loc") and x.text]
                for u in locs[:200]:
                    if urllib.parse.urlsplit(u).netloc==root.netloc:urls.append(u)
            except ET.ParseError:pass
    home=fetch_cached(conn,base,ttl_days=14)
    if home.get("text"):
        parsed=parse_html_page(home["text"],base)
        urls.extend([u for u in parsed["links"] if urllib.parse.urlsplit(u).netloc==root.netloc])
    unique=list(dict.fromkeys(urls))
    unique.sort(key=lambda u:(-priority_score(u),len(u)))
    return unique[:max_pages]

def add_evidence(conn,account_id,claim_type,claim_value,source_type,source_url,source_title=None,excerpt=None,
                 confidence=0.8,published_at=None,is_inference=False,inference_basis=None,observed_at=None):
    observed_at=observed_at or utcnow()
    excerpt=(excerpt or "")[:1000]
    c_hash=content_hash((source_url or "")+"|"+str(claim_value)+"|"+excerpt)
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO matrix_account_evidence(
            account_id,claim_type,claim_value,source_type,source_url,source_title,observed_at,published_at,
            evidence_excerpt,confidence,content_hash,is_inference,inference_basis
        ) VALUES(%s,%s,%s::jsonb,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb)
        ON CONFLICT(account_id,claim_type,source_url,content_hash) DO UPDATE SET
            observed_at=excluded.observed_at,confidence=GREATEST(matrix_account_evidence.confidence,excluded.confidence)
        RETURNING evidence_id""",
        (account_id,claim_type,_json(claim_value),source_type,source_url,source_title,observed_at,published_at,
         excerpt,float(confidence),c_hash,bool(is_inference),_json(inference_basis or [])))
        return str(cur.fetchone()["evidence_id"])

def _company_row(conn,company_id):
    with conn.cursor() as cur:
        cur.execute("""SELECT id,name,normalized_name,address,neighborhood,city,state,phone_raw,phone_normalized,
                              mobile_phone,landline_phone,website_url,website_status,rating,review_count,latitude,longitude,
                              category_primary,category_secondary,maps_url,source_key,last_seen_at
                       FROM companies WHERE id=%s""",(company_id,))
        return cur.fetchone()

def resolve_account(conn,company_id):
    c=_company_row(conn,company_id)
    if not c:raise ValueError("Empresa não encontrada")
    domain=canonical_domain(c.get("website_url"))
    phone=normalize_phone(c.get("mobile_phone") or c.get("phone_normalized") or c.get("phone_raw"))
    nk=name_key(c.get("name"))
    account=None;reason=[];confidence=0.65
    with conn.cursor() as cur:
        cur.execute("""SELECT a.* FROM matrix_account_company_links l JOIN matrix_accounts a ON a.account_id=l.account_id
                       WHERE l.company_id=%s LIMIT 1""",(company_id,))
        account=cur.fetchone()
        if account:return account,c
        if domain:
            cur.execute("SELECT * FROM matrix_accounts WHERE canonical_domain=%s LIMIT 1",(domain,))
            account=cur.fetchone()
            if account:reason=["canonical_domain"];confidence=0.98
        if not account and phone:
            cur.execute("""SELECT a.* FROM matrix_accounts a
                           WHERE a.primary_phone=%s AND lower(coalesce(a.city,''))=lower(%s) LIMIT 1""",(phone,c.get("city")))
            account=cur.fetchone()
            if account:reason=["phone_city"];confidence=0.93
        if not account and nk:
            cur.execute("""SELECT * FROM matrix_accounts
                           WHERE account_name_key=%s AND lower(coalesce(city,''))=lower(%s) LIMIT 1""",(nk,c.get("city")))
            account=cur.fetchone()
            if account:reason=["normalized_name_city"];confidence=0.84
        if not account:
            cur.execute("""INSERT INTO matrix_accounts(
                account_name_canonical,account_name_key,trade_name,canonical_domain,primary_phone,city,state,
                entity_resolution_confidence,entity_resolution_evidence,status,first_seen_at,last_seen_at
            ) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,'active',now(),now()) RETURNING *""",
            (c.get("name"),nk,c.get("name"),domain,phone,c.get("city"),c.get("state"),0.90,
             _json([{"type":"created_from_company","company_id":company_id,"source_key":c.get("source_key")}])) )
            account=cur.fetchone();reason=["new_account"];confidence=0.90
        else:
            cur.execute("""UPDATE matrix_accounts SET
                account_name_canonical=COALESCE(account_name_canonical,%s),
                canonical_domain=COALESCE(canonical_domain,%s),primary_phone=COALESCE(primary_phone,%s),
                last_seen_at=now() WHERE account_id=%s""",(c.get("name"),domain,phone,account["account_id"]))
        cur.execute("""INSERT INTO matrix_account_company_links(account_id,company_id,link_confidence,link_reason)
                       VALUES(%s,%s,%s,%s::jsonb) ON CONFLICT(company_id) DO UPDATE SET
                       account_id=excluded.account_id,link_confidence=excluded.link_confidence,link_reason=excluded.link_reason""",
                    (account["account_id"],company_id,confidence,_json(reason)))
        cur.execute("""INSERT INTO matrix_account_locations(account_id,branch_key,address,neighborhood,city,state,latitude,longitude,
                       source_type,source_url,observed_at) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,'google_maps',%s,now())
                       ON CONFLICT(account_id,branch_key) DO UPDATE SET address=excluded.address,latitude=excluded.latitude,
                       longitude=excluded.longitude,observed_at=excluded.observed_at""",
                    (account["account_id"],c.get("source_key") or str(company_id),c.get("address"),
                     c.get("neighborhood"),c.get("city"),c.get("state"),c.get("latitude"),c.get("longitude"),c.get("maps_url")))
    return account,c

def _extract_cnpj(text):
    m=re.search(r"\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b",text or "")
    return re.sub(r"\D","",m.group(0)) if m else None

def _emails(text):
    return sorted(set(re.findall(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",text or "",flags=re.I)))[:20]

def _phones(text):
    raw=re.findall(r"(?:\+?55\s*)?(?:\(?\d{2}\)?\s*)?(?:9\s*)?\d{4}[-.\s]?\d{4}",text or "")
    return list(dict.fromkeys(x for x in (normalize_phone(v) for v in raw) if x))[:20]

def research_website(conn,account,company):
    domain=account.get("canonical_domain") or canonical_domain(company.get("website_url"))
    if not domain:return {"pages":[],"services":[],"sectors":[],"contacts":[],"maturity":{},"negative":[],"cnpj":None}
    base="https://"+domain+"/"
    urls=discover_site_urls(conn,base,max_pages=int(os.getenv("MATRIX_SNIPER_MAX_SITE_PAGES","14")))
    pages=[]; all_text=[]; service_map={}; sector_map={}; neg=[]; maturity={"strong":[],"medium":[],"weak":[]}; contacts=[]
    cnpj=None
    for url in urls:
        r=fetch_cached(conn,url,ttl_days=14 if priority_score(url)>=70 else 3)
        if r.get("status")!=200 or "html" not in (r.get("content_type") or ""):continue
        parsed=parse_html_page(r.get("text") or "",url)
        text=parsed["text"]
        if len(text)<80:continue
        page={"url":url,"title":parsed["title"],"text":text[:12000],"hash":r.get("content_hash"),"fetched_at":utcnow().isoformat()}
        pages.append(page);all_text.append(text)
        sh=service_hits(text)
        for sid,hits in sh.items():
            service_map.setdefault(sid,{"hits":[],"pages":[]})
            service_map[sid]["hits"].extend(hits);service_map[sid]["pages"].append(url)
        sec=sector_hits(text)
        for sid,hits in sec.items():
            sector_map.setdefault(sid,{"hits":[],"pages":[]})
            sector_map[sid]["hits"].extend(hits);sector_map[sid]["pages"].append(url)
        neg.extend(negative_hits(text))
        mh=maturity_hits(text)
        for level,items in mh.items():maturity[level].extend(items)
        if not cnpj:cnpj=_extract_cnpj(text)
        for e in _emails(text):contacts.append({"type":"email","value":e,"source_url":url})
        for ph in _phones(text):contacts.append({"type":"phone","value":ph,"source_url":url})
        # role-like lines / snippets
        nt=norm(text)
        for role,terms in ROLE_PATTERNS.items():
            if any(norm(t) in nt for t in terms):
                contacts.append({"type":"role_signal","role":role,"value":None,"source_url":url})
    combined=" ".join(all_text)
    return {
        "pages":pages,"combined_text":combined[:300000],
        "services":service_map,"sectors":sector_map,
        "contacts":list({json.dumps(x,sort_keys=True):x for x in contacts}.values()),
        "maturity":{k:sorted(set(v)) for k,v in maturity.items()},
        "negative":sorted(set(neg)),"cnpj":cnpj,
    }

def persist_website_findings(conn,account_id,data):
    service_out=[]
    for sid,info in data["services"].items():
        urls=list(dict.fromkeys(info["pages"]))
        conf=min(0.98,0.78+0.05*min(len(urls),4))
        evs=[]
        for url in urls[:4]:
            page=next((p for p in data["pages"] if p["url"]==url),None)
            if not page:continue
            evs.append(add_evidence(conn,account_id,"service",{"service_id":sid},"website",url,page["title"],
                                    excerpt=page["text"][:650],confidence=conf))
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO matrix_account_services(account_id,service_id,confirmed,confidence,evidence_ids,observed_at)
                           VALUES(%s,%s,true,%s,%s::jsonb,now())
                           ON CONFLICT(account_id,service_id) DO UPDATE SET confirmed=true,confidence=GREATEST(matrix_account_services.confidence,excluded.confidence),
                           evidence_ids=excluded.evidence_ids,observed_at=excluded.observed_at""",
                        (account_id,sid,conf,_json(evs)))
        service_out.append({"service_id":sid,"confidence":conf,"evidence_ids":evs,"source_urls":urls[:4]})
    sector_out=[]
    for sid,info in data["sectors"].items():
        url=info["pages"][0]
        ev=add_evidence(conn,account_id,"sector",{"sector_id":sid},"website",url,None,
                        excerpt=f"Setor identificado por termos: {', '.join(sorted(set(info['hits']))[:6])}",confidence=0.82)
        sector_out.append({"sector_id":sid,"confidence":0.82,"evidence_ids":[ev]})
    if data.get("cnpj"):
        ev=add_evidence(conn,account_id,"identity",{"cnpj":data["cnpj"]},"website",
                        data["pages"][0]["url"] if data["pages"] else None,None,"CNPJ público identificado no site",0.92)
        with conn.cursor() as cur:
            cur.execute("UPDATE matrix_accounts SET cnpj=COALESCE(cnpj,%s) WHERE account_id=%s",(data["cnpj"],account_id))
    for c in data["contacts"]:
        if c.get("type") not in ("email","phone"):continue
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO matrix_account_contacts(account_id,contact_type,contact_value,decision_role,confidence,source_url,observed_at)
                           VALUES(%s,%s,%s,'unknown',0.75,%s,now())
                           ON CONFLICT(account_id,contact_type,contact_value) DO UPDATE SET observed_at=excluded.observed_at""",
                        (account_id,c["type"],c["value"],c["source_url"]))
    return service_out,sector_out

def google_presence(conn,account_id,company_id,services):
    with conn.cursor() as cur:
        cur.execute("""SELECT s.id,s.job_id,s.term,s.neighborhood,s.city,s.state,s.finished_at,s.result_count,sr.position
                       FROM searches s LEFT JOIN search_results sr ON sr.search_id=s.id AND sr.company_id=%s
                       WHERE s.status='completed' AND EXISTS(
                         SELECT 1 FROM search_results x WHERE x.search_id=s.id AND x.company_id=%s
                       ) ORDER BY s.finished_at DESC NULLS LAST LIMIT 180""",(company_id,company_id))
        rows=cur.fetchall()
    # include related searches from same recent jobs even when target absent
    job_ids=sorted({r["job_id"] for r in rows if r.get("job_id")})[-5:]
    if job_ids:
        with conn.cursor() as cur:
            cur.execute("""SELECT s.id,s.job_id,s.term,s.neighborhood,s.city,s.state,s.finished_at,s.result_count,sr.position
                           FROM searches s LEFT JOIN search_results sr ON sr.search_id=s.id AND sr.company_id=%s
                           WHERE s.status='completed' AND s.job_id=ANY(%s) ORDER BY s.finished_at DESC NULLS LAST LIMIT 240""",
                        (company_id,job_ids))
            rows=cur.fetchall()
    matrix=[]
    for svc in services:
        sid=svc["service_id"];terms=SERVICE_ONTOLOGY.get(sid,[])
        relevant=[r for r in rows if any(norm(t) in norm(r["term"]) for t in terms)]
        positions=[r["position"] for r in relevant if r.get("position") is not None]
        matrix.append({
            "service_id":sid,"offered_on_site":True,"evidence_confidence":svc["confidence"],
            "queries_checked":len(relevant),"queries_with_presence":len(positions),
            "best_position":min(positions) if positions else None,
            "median_position":sorted(positions)[len(positions)//2] if positions else None,
            "coverage_score":round(100*len(positions)/len(relevant),1) if relevant else 0,
        })
    total_checked=sum(x["queries_checked"] for x in matrix)
    total_present=sum(x["queries_with_presence"] for x in matrix)
    coverage=round(100*total_present/total_checked,1) if total_checked else 0

    # recurrent competitors above target or recurrent in related service queries.
    counter=Counter(); details={}
    search_ids=[r["id"] for r in rows]
    if search_ids:
        with conn.cursor() as cur:
            cur.execute("""SELECT sr.search_id,sr.company_id,sr.position,c.name,c.rating,c.review_count,c.website_url,c.category_primary
                           FROM search_results sr JOIN companies c ON c.id=sr.company_id
                           WHERE sr.search_id=ANY(%s) AND sr.company_id<>%s AND sr.position<=10""",(search_ids,company_id))
            for r in cur.fetchall():
                counter[r["company_id"]]+=1;details[r["company_id"]]=r
    competitors=[]
    for cid,count in counter.most_common(5):
        r=details[cid]
        competitors.append({"company_id":cid,"name":r["name"],"top10_occurrences":count,"rating":r["rating"],
                            "review_count":r["review_count"],"website_url":r["website_url"],"category":r["category_primary"]})
    # gaps
    subject=_company_row(conn,company_id) or {}
    subj_reviews=int(subject.get("review_count") or 0);subj_rating=float(subject.get("rating") or 0)
    comp_reviews=[int(x["review_count"] or 0) for x in competitors]
    comp_ratings=[float(x["rating"] or 0) for x in competitors if x.get("rating")]
    reputation_gap=0
    if comp_reviews and max(comp_reviews)>subj_reviews:reputation_gap=min(100,100*(max(comp_reviews)-subj_reviews)/max(max(comp_reviews),1))
    competitive_gap=min(100,20*len(competitors))
    site_gap=0 if subject.get("website_url") else 100
    out={"queries_checked":total_checked,"queries_with_presence":total_present,"coverage_score":coverage,
         "service_matrix":matrix,"competitors":competitors,"competitive_gap_score":round(competitive_gap,1),
         "reputation_gap_score":round(reputation_gap,1),"site_gap_score":site_gap,
         "rating":subject.get("rating"),"review_count":subject.get("review_count")}
    # persist query evidence
    with conn.cursor() as cur:
        for r in rows[:240]:
            cur.execute("""INSERT INTO matrix_google_observations(account_id,company_id,job_id,search_id,query_term,region_label,position,
                           result_count,observed_at) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)
                           ON CONFLICT(account_id,search_id) DO UPDATE SET position=excluded.position,result_count=excluded.result_count,observed_at=excluded.observed_at""",
                        (account_id,company_id,r["job_id"],r["id"],r["term"],f"{r.get('neighborhood') or ''} {r.get('city') or ''}/{r.get('state') or ''}".strip(),
                         r.get("position"),r.get("result_count"),r.get("finished_at") or utcnow()))
    return out

def maturity_from_site(data,review_count=0):
    m=data.get("maturity") or {}
    strong=len(m.get("strong") or [])
    medium=len(m.get("medium") or [])
    weak=len(m.get("weak") or [])
    b2b=min(100,strong*22+medium*10+weak*4+(8 if review_count and review_count>=50 else 0))
    industrial=min(100,len(data.get("services") or {})*14+len(data.get("sectors") or {})*6+medium*4)
    # size band is evidence maturity band, not invented headcount/revenue.
    if strong>=3 and medium>=3:band="large";conf=0.78
    elif strong>=1 and medium>=3:band="mid";conf=0.76
    elif medium>=2:band="small";conf=0.68
    elif weak:band="micro";conf=0.55
    else:band="unknown";conf=0.35
    return {"company_size_band":band,"company_size_confidence":conf,"signals":m,
            "b2b_maturity_score":b2b,"industrial_depth_score":industrial}

def _parse_date_candidates(text):
    # ISO dates are safe to parse. Avoid guessing locale dates.
    out=[]
    for raw in re.findall(r"\b20\d{2}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)?\b",text or ""):
        try:out.append(datetime.fromisoformat(raw.replace("Z","+00:00")))
        except ValueError:pass
    return out

def website_triggers(conn,account_id,data):
    signals=[]
    for page in data.get("pages") or []:
        hits=trigger_hits(page["text"]+" "+page["url"])
        if not hits:continue
        dates=_parse_date_candidates(page["text"])
        published=max(dates) if dates else None
        rec=classify_recency(published)
        for typ,kw in hits.items():
            ev=add_evidence(conn,account_id,"trigger",{"type":typ,"keywords":kw},"website",page["url"],page["title"],
                            excerpt=page["text"][:700],confidence=0.82,published_at=published)
            sig={"type":typ,"source_type":"website","source_url":page["url"],"published_at":published.isoformat() if published else None,
                 "observed_at":utcnow().isoformat(),"recency_days":rec["days"],"recency_weight":rec["weight"],
                 "usable_reason_now":rec["usable_reason_now"],"relevance_weight":0.75,"evidence_ids":[ev]}
            signals.append(sig)
    return signals

def google_news_signals(conn,account_id,account_name):
    """Public RSS only; failure is non-fatal and lowers no hard gate."""
    q=urllib.parse.quote(f'"{account_name}"')
    url=f"https://news.google.com/rss/search?q={q}&hl=pt-BR&gl=BR&ceid=BR:pt-419"
    r=fetch_cached(conn,url,ttl_days=1)
    if r.get("status")!=200 or "<item" not in (r.get("text") or ""):return []
    out=[]
    try:root=ET.fromstring(r["text"])
    except ET.ParseError:return []
    for item in root.findall(".//item")[:8]:
        title=(item.findtext("title") or "").strip()
        link=(item.findtext("link") or "").strip()
        pub=(item.findtext("pubDate") or "").strip()
        desc=html.unescape(item.findtext("description") or "")
        try:published=email.utils.parsedate_to_datetime(pub) if pub else None
        except Exception:published=None
        hits=trigger_hits(title+" "+desc)
        if not hits:continue
        rec=classify_recency(published)
        if rec["days"] is not None and rec["days"]>180:continue
        for typ,kw in hits.items():
            ev=add_evidence(conn,account_id,"trigger",{"type":typ,"headline":title},"news",link,title,
                            excerpt=re.sub("<[^>]+>"," ",desc)[:700],confidence=0.76,published_at=published)
            out.append({"type":typ,"source_type":"news","source_url":link,"title":title,
                        "published_at":published.isoformat() if published else None,"observed_at":utcnow().isoformat(),
                        "recency_days":rec["days"],"recency_weight":rec["weight"],"usable_reason_now":rec["usable_reason_now"],
                        "relevance_weight":0.82,"evidence_ids":[ev]})
    return out

def research_confidence(services,sectors,google,website,triggers):
    useful_sources=set()
    for s in services:
        useful_sources.update(s.get("source_urls") or [])
    for p in website.get("pages") or []: useful_sources.add(p["url"])
    if google.get("queries_checked"):useful_sources.add("google_maps_observations")
    for t in triggers: useful_sources.add(t.get("source_url"))
    useful_sources.discard(None)
    critical=[bool(services),bool(google.get("queries_checked")),bool(website.get("pages"))]
    score=min(1.0,0.15+0.13*len(useful_sources)+0.12*sum(critical))
    return round(score,2),len(useful_sources)

def synthesize(pack):
    matrix=(pack.get("google_presence") or {}).get("service_matrix") or []
    gaps=[x for x in matrix if x.get("offered_on_site") and x.get("queries_checked") and x.get("coverage_score",100)<60]
    gaps.sort(key=lambda x:(x.get("coverage_score",100),-(x.get("queries_checked") or 0)))
    if gaps:
        g=gaps[0]
        opp=f"Baixa cobertura observada em buscas de {g['service_id']}"
        implication="Hipótese: concorrentes recorrentes podem capturar parte da demanda de alta intenção antes da empresa."
        thesis=f"A empresa divulga {g['service_id']}, porém a cobertura observada nas consultas relacionadas foi de {g['coverage_score']}%. A tese comercial é melhorar captura dessa demanda sem afirmar perda de clientes."
    elif pack.get("services_confirmed"):
        sid=pack["services_confirmed"][0]["service_id"]
        opp=f"Oportunidade de ampliar presença observável para {sid}"
        implication="Hipótese: ampliar visibilidade nas consultas prioritárias pode aumentar oportunidades qualificadas."
        thesis=f"Há evidência pública de atuação em {sid}; a abordagem deve conectar essa oferta a oportunidades observadas de presença e competição."
    else:
        opp=None;implication=None;thesis=None
    usable=[x for x in pack.get("trigger_signals") or [] if x.get("usable_reason_now")]
    usable.sort(key=lambda x:(x.get("recency_days") is None,x.get("recency_days") or 9999))
    reason=None
    if usable:
        x=usable[0];reason=f"Sinal recente de {x['type']} observado em fonte pública."
    safe=[]
    for svc in pack.get("services_confirmed") or []:
        if svc.get("confidence",0)>=0.80:safe.append({"fact":f"A empresa divulga {svc['service_id']} em fonte pública.","evidence_ids":svc.get("evidence_ids") or []})
    gp=pack.get("google_presence") or {}
    if gp.get("queries_checked"):
        safe.append({"fact":f"A análise observou presença em {gp.get('queries_with_presence',0)} de {gp.get('queries_checked',0)} consultas relacionadas.","evidence_ids":[]})
    dor1="Se aumentarmos a procura pelos serviços prioritários, vocês têm capacidade de absorver mais contratos hoje?" if pack.get("services_confirmed") else None
    return opp,implication,thesis,reason,safe[:8],dor1

def build_pack(conn,company_id,force=False):
    account,company=resolve_account(conn,company_id)
    aid=account["account_id"]
    # fresh pack reuse
    if not force:
        with conn.cursor() as cur:
            cur.execute("""SELECT * FROM matrix_research_packs WHERE account_id=%s AND expires_at>now()
                           ORDER BY version DESC LIMIT 1""",(aid,))
            existing=cur.fetchone()
            if existing:return existing["pack_json"]

    website=research_website(conn,account,company)
    services,sectors=persist_website_findings(conn,aid,website)
    gp=google_presence(conn,aid,company_id,services)
    maturity=maturity_from_site(website,company.get("review_count") or 0)
    triggers=website_triggers(conn,aid,website)
    try:triggers.extend(google_news_signals(conn,aid,account.get("account_name_canonical") or company.get("name")))
    except Exception:pass
    conf,source_count=research_confidence(services,sectors,gp,website,triggers)
    neg=[]
    if website.get("negative") and not services:
        neg.append({"type":"residential_or_off_niche","severity":"reject","terms":website["negative"]})
    b2b=bool(services and (sectors or maturity["b2b_maturity_score"]>=20))
    pack={
        "schema_version":"matrix.sniper.3.0",
        "account_id":str(aid),"account_name":account.get("account_name_canonical") or company.get("name"),
        "domain":account.get("canonical_domain"),"locations":[],
        "services_confirmed":services,"segments_served":sectors,"b2b_confirmed":b2b,
        "company_size_band":maturity["company_size_band"],"company_size_confidence":maturity["company_size_confidence"],
        "maturity_signals":maturity["signals"],"b2b_maturity_score":maturity["b2b_maturity_score"],
        "industrial_depth_score":maturity["industrial_depth_score"],
        "google_presence":gp,"competitor_summary":gp.get("competitors") or [],
        "reputation_snapshot":{"rating":company.get("rating"),"reviews":company.get("review_count"),"observed_at":utcnow().isoformat()},
        "website_findings":{"pages":[{"url":p["url"],"title":p["title"],"hash":p["hash"]} for p in website.get("pages") or []],
                            "contacts":website.get("contacts") or [],"negative_terms":website.get("negative") or []},
        "trigger_signals":triggers,"negative_signals":neg,
        "entity_resolution_ok":float(account.get("entity_resolution_confidence") or 0)>=0.80,
        "entity_resolution_confidence":float(account.get("entity_resolution_confidence") or 0),
        "active":company.get("last_seen_at") is not None,
        "source_count":source_count,"primary_source_count":1 if website.get("pages") else 0,
        "research_confidence":conf,"contradictions":[],"missing_information":[],
        "geography_evidenced":bool(company.get("city")),"solo_operation":False,
        "weak_web_profile":not bool(website.get("pages")) and conf<0.6,"duplicate_conflict":False,
        "researched_at":utcnow().isoformat(),
    }
    with conn.cursor() as cur:
        cur.execute("""SELECT address,neighborhood,city,state,latitude,longitude,source_url FROM matrix_account_locations
                       WHERE account_id=%s ORDER BY observed_at DESC""",(aid,))
        pack["locations"]=[dict(x) for x in cur.fetchall()]
        cur.execute("""SELECT contact_type,contact_value,contact_name,contact_title,decision_role,confidence,source_url
                       FROM matrix_account_contacts WHERE account_id=%s ORDER BY confidence DESC,observed_at DESC LIMIT 30""",(aid,))
        pack["contacts"]=[dict(x) for x in cur.fetchall()]

    opp,impl,thesis,reason,safe,dor=synthesize(pack)
    pack.update(primary_opportunity=opp,business_implication=impl,primary_thesis=thesis,reason_now=reason,
                m1_safe_facts=safe,dor1_recommended=dor)
    score=deterministic_score(pack)
    pack.update(sniper_score=score["score"],sniper_tier=score["tier"],score_breakdown=score["breakdown"],
                hard_gates_passed=score["hard_gates_passed"],hard_gate_reasons=score["hard_gate_reasons"],
                score_penalties=score["penalties"],research_status=score["recommendation"].lower())
    pack["recommendation"]=score["recommendation"]
    if not pack["primary_thesis"] and pack["recommendation"]=="APPROVE":
        pack["recommendation"]="REVIEW";pack["research_status"]="review"
    ttl=10 if pack["sniper_tier"] in ("A","A+") else 21
    pack["expires_at"]=(utcnow()+timedelta(days=ttl)).isoformat()

    # score/audit evidence snapshot
    with conn.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(version),0)+1 AS v FROM matrix_research_packs WHERE account_id=%s",(aid,))
        version=cur.fetchone()["v"]
        pack["version"]=version
        h=json_hash(pack)
        cur.execute("""INSERT INTO matrix_research_packs(account_id,version,pack_json,sniper_score,sniper_tier,score_breakdown,
                       research_confidence,research_status,researched_at,expires_at,pack_hash)
                       VALUES(%s,%s,%s::jsonb,%s,%s,%s::jsonb,%s,%s,now(),%s,%s)""",
                    (aid,version,_json(pack),pack["sniper_score"],pack["sniper_tier"],_json(pack["score_breakdown"]),
                     pack["research_confidence"],pack["research_status"],pack["expires_at"],h))
        cur.execute("""UPDATE matrix_accounts SET sniper_score=%s,sniper_tier=%s,research_status=%s,
                       research_confidence=%s,last_researched_at=now(),last_seen_at=now() WHERE account_id=%s""",
                    (pack["sniper_score"],pack["sniper_tier"],pack["research_status"],pack["research_confidence"],aid))
        # signals table
        for sig in triggers:
            cur.execute("""INSERT INTO matrix_account_signals(account_id,signal_type,signal_value,source_url,observed_at,published_at,
                           expires_at,confidence,relevance,active)
                           VALUES(%s,%s,%s::jsonb,%s,now(),%s,%s,%s,%s,true)""",
                        (aid,sig["type"],_json(sig),sig.get("source_url"),sig.get("published_at"),
                         (utcnow()+timedelta(days=180)).isoformat(),0.78,sig.get("relevance_weight",0.7)))
    return pack

def enqueue_job(conn,job_id):
    with conn.cursor() as cur:
        cur.execute("""SELECT DISTINCT sr.company_id FROM searches s JOIN search_results sr ON sr.search_id=s.id
                       WHERE s.job_id=%s ORDER BY sr.company_id""",(job_id,))
        ids=[r["company_id"] for r in cur.fetchall()]
        for cid in ids:
            cur.execute("""INSERT INTO matrix_research_queue(job_id,company_id,status,priority,created_at)
                           VALUES(%s,%s,'pending',0,now())
                           ON CONFLICT(job_id,company_id) DO UPDATE SET
                           status=CASE WHEN matrix_research_queue.status='completed' THEN matrix_research_queue.status ELSE 'pending' END,
                           updated_at=now()""",(job_id,cid))
    return len(ids)

def process_queue(get_conn,job_id=None,limit=25):
    processed=0;errors=0
    while processed<limit:
        with get_conn() as conn:
            with conn.cursor() as cur:
                if job_id:
                    cur.execute("""SELECT id,company_id,attempts FROM matrix_research_queue
                                   WHERE status IN('pending','error') AND job_id=%s AND attempts<3
                                   ORDER BY priority DESC,id FOR UPDATE SKIP LOCKED LIMIT 1""",(job_id,))
                else:
                    cur.execute("""SELECT id,company_id,attempts FROM matrix_research_queue
                                   WHERE status IN('pending','error') AND attempts<3
                                   ORDER BY priority DESC,id FOR UPDATE SKIP LOCKED LIMIT 1""")
                q=cur.fetchone()
                if not q:break
                cur.execute("""UPDATE matrix_research_queue SET status='running',attempts=attempts+1,started_at=now(),updated_at=now()
                               WHERE id=%s""",(q["id"],))
            try:
                pack=build_pack(conn,q["company_id"],force=False)
                with conn.cursor() as cur:
                    cur.execute("""UPDATE matrix_research_queue SET status='completed',finished_at=now(),updated_at=now(),last_error=NULL,
                                   account_id=%s WHERE id=%s""",(pack["account_id"],q["id"]))
                processed+=1
            except Exception as exc:
                with conn.cursor() as cur:
                    cur.execute("""UPDATE matrix_research_queue SET status='error',last_error=%s,updated_at=now() WHERE id=%s""",
                                (str(exc)[:1000],q["id"]))
                errors+=1;processed+=1
    return {"processed":processed,"errors":errors}
