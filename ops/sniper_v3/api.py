"""Matrix Sniper V3 API."""
from __future__ import annotations
import asyncio, csv, io, json, os, pathlib, threading
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from .core import SERVICE_ONTOLOGY, query_plan
from .research import build_pack, enqueue_job, process_queue

ROOT=pathlib.Path(__file__).resolve().parent

class ResearchReq(BaseModel):
    force: bool=False

class QueryPlanReq(BaseModel):
    city:str=Field(min_length=2,max_length=120)
    state:str|None=Field(default=None,max_length=40)
    neighborhoods:list[str]=Field(default_factory=list,max_length=80)
    service_ids:list[str]=Field(default_factory=list,max_length=30)

class SniperJobReq(BaseModel):
    city:str=Field(min_length=2,max_length=120)
    state:str|None=Field(default=None,max_length=40)
    neighborhoods:list[str]=Field(min_length=1,max_length=80)
    service_ids:list[str]=Field(default_factory=lambda:[
        "chiller_rental","chiller_maintenance","chiller_installation","chiller_retrofit",
        "industrial_refrigeration","hvac_industrial"
    ],min_length=1,max_length=30)
    result_limit:int=Field(default=20,ge=5,le=50)

class FeedbackReq(BaseModel):
    outcome:str=Field(min_length=2,max_length=40)
    thesis_key:str|None=Field(default=None,max_length=180)
    notes:str|None=Field(default=None,max_length=2000)
    happened_at:datetime|None=None

def _jsonable(x):
    if isinstance(x,dict):return {k:_jsonable(v) for k,v in x.items()}
    if isinstance(x,list):return [_jsonable(v) for v in x]
    if isinstance(x,datetime):return x.isoformat()
    try:
        from decimal import Decimal
        if isinstance(x,Decimal):return float(x)
    except Exception:pass
    return x

def register_sniper_v3_routes(app,get_conn,require_user):
    router=APIRouter()

    @router.get("/sniper",response_class=HTMLResponse)
    def sniper_ui(user_id=Depends(require_user)):
        return (ROOT/"sniper.html").read_text(encoding="utf-8")

    @router.get("/api/sniper/health")
    def health(user_id=Depends(require_user)):
        return {"ok":True,"module":"Matrix Sniper","version":"4.0","account_intelligence":True,
                "principle":"evidence_before_inference","volume_target":False}

    @router.get("/api/sniper/ontology")
    def ontology(user_id=Depends(require_user)):
        return [{"service_id":k,"terms":v} for k,v in SERVICE_ONTOLOGY.items()]

    @router.post("/api/sniper/query-plan")
    def make_query_plan(req:QueryPlanReq,user_id=Depends(require_user)):
        services=req.service_ids or list(SERVICE_ONTOLOGY)
        invalid=[x for x in services if x not in SERVICE_ONTOLOGY]
        if invalid:raise HTTPException(400,f"service_id inválido: {invalid[0]}")
        return {"queries":query_plan(req.city,req.state,req.neighborhoods,services),"service_ids":services}

    @router.post("/api/sniper/scrape-jobs")
    def create_sniper_scrape(req:SniperJobReq,user_id=Depends(require_user)):
        invalid=[x for x in req.service_ids if x not in SERVICE_ONTOLOGY]
        if invalid:raise HTTPException(400,f"service_id inválido: {invalid[0]}")
        terms=[];seen=set()
        for sid in req.service_ids:
            for term in SERVICE_ONTOLOGY[sid][:3]:
                k=term.lower().strip()
                if k not in seen:
                    seen.add(k);terms.append(term)
        neighborhoods=[x.strip() for x in req.neighborhoods if x.strip()]
        if not neighborhoods:raise HTTPException(400,"Informe ao menos uma região/bairro.")
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM scrape_jobs WHERE status IN('pending','claimed','running','enriching') LIMIT 1")
                active=cur.fetchone()
                if active:raise HTTPException(409,f"Já existe uma raspagem ativa: Job #{active['id']}")
                cur.execute("""INSERT INTO scrape_jobs(terms,neighborhoods,city,state,result_limit,lead_target,total_searches)
                               VALUES(%s::jsonb,%s::jsonb,%s,%s,%s,0,%s) RETURNING id""",
                            (json.dumps(terms,ensure_ascii=False),json.dumps(neighborhoods,ensure_ascii=False),
                             req.city.strip(),(req.state or "").strip(),req.result_limit,len(terms)*len(neighborhoods)))
                job_id=cur.fetchone()["id"]
        return {"ok":True,"job_id":job_id,"terms":terms,"neighborhoods":neighborhoods,
                "total_searches":len(terms)*len(neighborhoods),"mode":"sniper_query_planner"}

    @router.get("/api/sniper/accounts")
    def accounts(q:str="",tier:str|None=None,status:str|None=None,limit:int=50,user_id=Depends(require_user)):
        limit=min(max(limit,1),200)
        where=["1=1"];params=[]
        if q:
            where.append("(account_name_canonical ILIKE %s OR canonical_domain ILIKE %s)")
            params.extend([f"%{q[:100]}%",f"%{q[:100]}%"])
        if tier:
            where.append("sniper_tier=%s");params.append(tier)
        if status:
            where.append("research_status=%s");params.append(status)
        params.append(limit)
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(f"""SELECT account_id,account_name_canonical,canonical_domain,primary_phone,city,state,
                                       entity_resolution_confidence,sniper_score,sniper_tier,research_status,
                                       research_confidence,last_researched_at,last_seen_at
                                FROM matrix_accounts WHERE {' AND '.join(where)}
                                ORDER BY sniper_score DESC NULLS LAST,last_researched_at DESC NULLS LAST LIMIT %s""",params)
                return [_jsonable(dict(x)) for x in cur.fetchall()]

    @router.get("/api/sniper/accounts/{account_id}")
    def account_detail(account_id:str,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM matrix_accounts WHERE account_id=%s",(account_id,))
                account=cur.fetchone()
                if not account:raise HTTPException(404,"Conta não encontrada")
                cur.execute("""SELECT * FROM matrix_account_locations WHERE account_id=%s ORDER BY observed_at DESC""",(account_id,))
                locations=cur.fetchall()
                cur.execute("""SELECT * FROM matrix_account_contacts WHERE account_id=%s ORDER BY confidence DESC,observed_at DESC""",(account_id,))
                contacts=cur.fetchall()
                cur.execute("""SELECT * FROM matrix_account_services WHERE account_id=%s ORDER BY confidence DESC""",(account_id,))
                services=cur.fetchall()
                cur.execute("""SELECT id,version,sniper_score,sniper_tier,research_confidence,research_status,researched_at,expires_at
                               FROM matrix_research_packs WHERE account_id=%s ORDER BY version DESC LIMIT 20""",(account_id,))
                packs=cur.fetchall()
        return _jsonable({"account":account,"locations":locations,"contacts":contacts,"services":services,"packs":packs})

    @router.get("/api/sniper/accounts/{account_id}/evidence")
    def account_evidence(account_id:str,limit:int=200,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""SELECT evidence_id,claim_type,claim_value,source_type,source_url,source_title,observed_at,published_at,
                                      evidence_excerpt,confidence,is_inference,inference_basis,source_state
                               FROM matrix_account_evidence WHERE account_id=%s
                               ORDER BY observed_at DESC LIMIT %s""",(account_id,min(max(limit,1),500)))
                return [_jsonable(dict(x)) for x in cur.fetchall()]

    @router.get("/api/sniper/accounts/{account_id}/pack")
    def latest_pack(account_id:str,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""SELECT id,version,pack_json,researched_at,expires_at FROM matrix_research_packs
                               WHERE account_id=%s ORDER BY version DESC LIMIT 1""",(account_id,))
                row=cur.fetchone()
                if not row:raise HTTPException(404,"Account Research Pack ainda não gerado")
        return _jsonable(row)

    @router.post("/api/sniper/companies/{company_id}/research")
    async def research_company(company_id:int,req:ResearchReq,user_id=Depends(require_user)):
        try:
            with get_conn() as conn:
                pack=await asyncio.to_thread(build_pack,conn,company_id,req.force)
            return _jsonable(pack)
        except ValueError as exc:raise HTTPException(400,str(exc))
        except Exception as exc:raise HTTPException(500,"Falha na pesquisa da conta: "+str(exc)[:500])

    @router.post("/api/sniper/jobs/{job_id}/research")
    def research_job(job_id:int,limit:int=50,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id,status FROM scrape_jobs WHERE id=%s",(job_id,))
                job=cur.fetchone()
                if not job:raise HTTPException(404,"Job não encontrado")
                if job["status"] not in ("completed","completed_with_errors"):raise HTTPException(409,"Conclua o Job antes de iniciar o Account Research.")
            queued=enqueue_job(conn,job_id)
        # Persistent queue is authoritative. Background thread is acceleration, not durability.
        def runner():
            try:process_queue(get_conn,job_id,min(max(limit,1),200))
            except Exception:pass
        threading.Thread(target=runner,daemon=True,name=f"sniper-job-{job_id}").start()
        return {"ok":True,"job_id":job_id,"queued":queued,"processing_started":True}

    @router.post("/api/sniper/queue/run")
    def run_queue(job_id:int|None=None,limit:int=25,user_id=Depends(require_user)):
        return process_queue(get_conn,job_id,min(max(limit,1),200))

    @router.get("/api/sniper/jobs/{job_id}/queue")
    def queue_status(job_id:int,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""SELECT status,count(*) AS n FROM matrix_research_queue WHERE job_id=%s GROUP BY status ORDER BY status""",(job_id,))
                counts={x["status"]:x["n"] for x in cur.fetchall()}
                cur.execute("""SELECT q.id,q.company_id,q.account_id,q.status,q.attempts,q.last_error,q.updated_at,c.name
                               FROM matrix_research_queue q JOIN companies c ON c.id=q.company_id
                               WHERE q.job_id=%s ORDER BY q.id LIMIT 500""",(job_id,))
                rows=cur.fetchall()
        return _jsonable({"job_id":job_id,"counts":counts,"items":rows})

    @router.get("/api/sniper/approved")
    def approved(limit:int=100,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""SELECT p.id AS pack_id,p.account_id,a.account_name_canonical,a.canonical_domain,a.primary_phone,
                                      a.city,a.state,p.version,p.sniper_score,p.sniper_tier,p.research_confidence,
                                      p.researched_at,p.expires_at,p.pack_json
                               FROM matrix_research_packs p JOIN matrix_accounts a ON a.account_id=p.account_id
                               WHERE p.id IN (SELECT max(id) FROM matrix_research_packs GROUP BY account_id)
                                 AND p.research_status='approved' AND p.sniper_tier IN('A','A+')
                                 AND p.expires_at>now()
                               ORDER BY p.sniper_score DESC,p.research_confidence DESC LIMIT %s""",(min(max(limit,1),300),))
                return [_jsonable(dict(x)) for x in cur.fetchall()]

    @router.get("/api/sniper/kpis")
    def kpis(user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""WITH latest AS (
                    SELECT DISTINCT ON (account_id) account_id,sniper_score,sniper_tier,research_confidence,research_status,
                           researched_at,expires_at,pack_json
                    FROM matrix_research_packs ORDER BY account_id,version DESC
                )
                SELECT
                    count(*) AS accounts_researched,
                    count(*) FILTER (WHERE sniper_tier IN ('A','A+')) AS approved_tier_count,
                    round(avg(research_confidence)::numeric,3) AS avg_research_confidence,
                    count(*) FILTER (WHERE expires_at>now()) AS fresh_packs,
                    count(*) FILTER (WHERE pack_json ? 'services_confirmed' AND jsonb_array_length(pack_json->'services_confirmed')>0) AS with_service_evidence,
                    count(*) FILTER (WHERE pack_json ? 'primary_thesis' AND nullif(pack_json->>'primary_thesis','') IS NOT NULL) AS with_thesis
                FROM latest""")
                summary=cur.fetchone()
                cur.execute("""SELECT count(*) AS evidence_count,
                                      count(*) FILTER (WHERE confidence>=0.80 AND NOT is_inference) AS high_confidence_facts,
                                      count(*) FILTER (WHERE is_inference) AS inferences
                               FROM matrix_account_evidence""")
                ev=cur.fetchone()
        return _jsonable({"summary":summary,"evidence":ev})

    @router.get("/api/sniper/export.csv")
    def export_csv(tier:str|None=None,user_id=Depends(require_user)):
        where="WHERE p.id IN (SELECT max(id) FROM matrix_research_packs GROUP BY account_id)"
        params=[]
        if tier:
            where+=" AND p.sniper_tier=%s";params.append(tier)
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(f"""SELECT a.account_name_canonical,a.canonical_domain,a.primary_phone,a.city,a.state,
                                       p.sniper_score,p.sniper_tier,p.research_confidence,p.research_status,p.researched_at,p.expires_at,
                                       p.pack_json->>'primary_opportunity' AS primary_opportunity,
                                       p.pack_json->>'reason_now' AS reason_now,
                                       p.pack_json->>'primary_thesis' AS primary_thesis
                                FROM matrix_research_packs p JOIN matrix_accounts a ON a.account_id=p.account_id
                                {where} ORDER BY p.sniper_score DESC""",params)
                rows=cur.fetchall()
        buff=io.StringIO();w=csv.writer(buff)
        headers=["account_name","domain","phone","city","state","sniper_score","sniper_tier","research_confidence","research_status",
                 "researched_at","expires_at","primary_opportunity","reason_now","primary_thesis"]
        w.writerow(headers)
        for r in rows:w.writerow([r.get(k) for k in ["account_name_canonical","canonical_domain","primary_phone","city","state","sniper_score","sniper_tier","research_confidence","research_status","researched_at","expires_at","primary_opportunity","reason_now","primary_thesis"]])
        data=buff.getvalue().encode("utf-8-sig")
        return StreamingResponse(io.BytesIO(data),media_type="text/csv",headers={"Content-Disposition":"attachment; filename=matrix_sniper_accounts.csv"})

    @router.post("/api/sniper/accounts/{account_id}/feedback")
    def feedback(account_id:str,req:FeedbackReq,user_id=Depends(require_user)):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM matrix_research_packs WHERE account_id=%s ORDER BY version DESC LIMIT 1",(account_id,))
                p=cur.fetchone()
                cur.execute("""INSERT INTO matrix_sniper_feedback(account_id,research_pack_id,outcome,thesis_key,notes,happened_at)
                               VALUES(%s,%s,%s,%s,%s,%s) RETURNING id""",
                            (account_id,p["id"] if p else None,req.outcome,req.thesis_key,req.notes,req.happened_at))
                fid=cur.fetchone()["id"]
        return {"ok":True,"feedback_id":fid}

    # Internal bridge for PDF/automation. Same VPS-only token already used by Matrix internal report bridge.
    @router.get("/api/internal/sniper/account/{account_id}")
    def internal_pack(account_id:str,request:Request):
        expected=os.getenv("MATRIX_INTERNAL_REPORT_TOKEN","")
        provided=request.headers.get("X-Matrix-Internal","")
        if not expected or provided!=expected:raise HTTPException(401,"unauthorized")
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("""SELECT p.*,a.account_name_canonical,a.canonical_domain,a.primary_phone,a.city,a.state
                               FROM matrix_research_packs p JOIN matrix_accounts a ON a.account_id=p.account_id
                               WHERE p.account_id=%s ORDER BY p.version DESC LIMIT 1""",(account_id,))
                row=cur.fetchone()
                if not row:raise HTTPException(404,"pack_not_found")
        return _jsonable(row)

    app.include_router(router)
