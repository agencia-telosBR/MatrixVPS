CREATE EXTENSION IF NOT EXISTS pgcrypto;\nCREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS matrix_accounts (
    account_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_name_canonical text NOT NULL,
    account_name_key text,
    trade_name text,
    legal_name text,
    cnpj varchar(14),
    canonical_domain text,
    primary_phone text,
    city text,
    state text,
    branch_count_observed integer NOT NULL DEFAULT 1,
    entity_resolution_confidence numeric(4,3) NOT NULL DEFAULT 0,
    entity_resolution_evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
    status varchar(30) NOT NULL DEFAULT 'active',
    sniper_score integer,
    sniper_tier varchar(3),
    research_status varchar(30),
    research_confidence numeric(4,3),
    last_researched_at timestamptz,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_matrix_accounts_domain ON matrix_accounts(canonical_domain) WHERE canonical_domain IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_matrix_accounts_cnpj ON matrix_accounts(cnpj) WHERE cnpj IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_matrix_accounts_phone ON matrix_accounts(primary_phone);
CREATE INDEX IF NOT EXISTS ix_matrix_accounts_name_trgm ON matrix_accounts USING gin(account_name_key gin_trgm_ops);
CREATE INDEX IF NOT EXISTS ix_matrix_accounts_tier_score ON matrix_accounts(sniper_tier,sniper_score DESC);
CREATE INDEX IF NOT EXISTS ix_matrix_accounts_research ON matrix_accounts(research_status,last_researched_at);

CREATE TABLE IF NOT EXISTS matrix_account_company_links (
    company_id bigint PRIMARY KEY REFERENCES companies(id) ON DELETE CASCADE,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    link_confidence numeric(4,3) NOT NULL DEFAULT 0,
    link_reason jsonb NOT NULL DEFAULT '[]'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_matrix_account_links_account ON matrix_account_company_links(account_id);

CREATE TABLE IF NOT EXISTS matrix_account_locations (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    branch_key text NOT NULL,
    address text,
    neighborhood text,
    city text,
    state text,
    latitude double precision,
    longitude double precision,
    source_type varchar(40),
    source_url text,
    observed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(account_id,branch_key)
);
CREATE INDEX IF NOT EXISTS ix_matrix_locations_account ON matrix_account_locations(account_id);

CREATE TABLE IF NOT EXISTS matrix_account_contacts (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    contact_type varchar(30) NOT NULL,
    contact_value text NOT NULL,
    contact_name text,
    contact_title text,
    decision_role varchar(30) NOT NULL DEFAULT 'unknown',
    confidence numeric(4,3) NOT NULL DEFAULT 0,
    source_url text,
    observed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(account_id,contact_type,contact_value)
);
CREATE INDEX IF NOT EXISTS ix_matrix_contacts_account ON matrix_account_contacts(account_id);

CREATE TABLE IF NOT EXISTS matrix_account_services (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    service_id varchar(80) NOT NULL,
    confirmed boolean NOT NULL DEFAULT false,
    confidence numeric(4,3) NOT NULL DEFAULT 0,
    evidence_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
    observed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(account_id,service_id)
);
CREATE INDEX IF NOT EXISTS ix_matrix_services_account ON matrix_account_services(account_id,service_id,observed_at DESC);

CREATE TABLE IF NOT EXISTS matrix_account_evidence (
    evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    claim_type varchar(40) NOT NULL,
    claim_value jsonb,
    source_type varchar(40) NOT NULL,
    source_url text NOT NULL DEFAULT '',
    source_title text,
    observed_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    evidence_excerpt text,
    confidence numeric(4,3) NOT NULL DEFAULT 0,
    content_hash varchar(64) NOT NULL,
    is_inference boolean NOT NULL DEFAULT false,
    inference_basis jsonb NOT NULL DEFAULT '[]'::jsonb,
    conflict_group text,
    source_state varchar(30) NOT NULL DEFAULT 'available',
    UNIQUE(account_id,claim_type,source_url,content_hash)
);
CREATE INDEX IF NOT EXISTS ix_matrix_evidence_account ON matrix_account_evidence(account_id,claim_type,observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_matrix_evidence_source_hash ON matrix_account_evidence(source_url,content_hash);

CREATE TABLE IF NOT EXISTS matrix_google_observations (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    company_id bigint REFERENCES companies(id) ON DELETE SET NULL,
    job_id bigint REFERENCES scrape_jobs(id) ON DELETE SET NULL,
    search_id bigint NOT NULL REFERENCES searches(id) ON DELETE CASCADE,
    query_term text NOT NULL,
    region_label text,
    position integer,
    result_count integer,
    observed_at timestamptz NOT NULL DEFAULT now(),
    competitors jsonb NOT NULL DEFAULT '[]'::jsonb,
    UNIQUE(account_id,search_id)
);
CREATE INDEX IF NOT EXISTS ix_matrix_google_account ON matrix_google_observations(account_id,observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_matrix_google_job ON matrix_google_observations(job_id,search_id);

CREATE TABLE IF NOT EXISTS matrix_account_signals (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    signal_type varchar(40) NOT NULL,
    signal_value jsonb NOT NULL DEFAULT '{}'::jsonb,
    source_url text,
    observed_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    expires_at timestamptz,
    confidence numeric(4,3) NOT NULL DEFAULT 0,
    relevance numeric(4,3) NOT NULL DEFAULT 0,
    active boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS ix_matrix_signals_account ON matrix_account_signals(account_id,signal_type,observed_at DESC);
CREATE INDEX IF NOT EXISTS ix_matrix_signals_expiry ON matrix_account_signals(active,expires_at);

CREATE TABLE IF NOT EXISTS matrix_research_packs (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    version integer NOT NULL,
    pack_json jsonb NOT NULL,
    sniper_score integer NOT NULL DEFAULT 0,
    sniper_tier varchar(3) NOT NULL DEFAULT 'C',
    score_breakdown jsonb NOT NULL DEFAULT '{}'::jsonb,
    research_confidence numeric(4,3) NOT NULL DEFAULT 0,
    research_status varchar(30) NOT NULL DEFAULT 'pending',
    researched_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    pack_hash varchar(64) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(account_id,version)
);
CREATE INDEX IF NOT EXISTS ix_matrix_packs_tier_score ON matrix_research_packs(sniper_tier,sniper_score DESC);
CREATE INDEX IF NOT EXISTS ix_matrix_packs_status_expiry ON matrix_research_packs(research_status,expires_at);
CREATE INDEX IF NOT EXISTS ix_matrix_packs_account_time ON matrix_research_packs(account_id,researched_at DESC);

CREATE TABLE IF NOT EXISTS matrix_research_queue (
    id bigserial PRIMARY KEY,
    job_id bigint REFERENCES scrape_jobs(id) ON DELETE CASCADE,
    company_id bigint NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    account_id uuid REFERENCES matrix_accounts(account_id) ON DELETE SET NULL,
    status varchar(30) NOT NULL DEFAULT 'pending',
    priority integer NOT NULL DEFAULT 0,
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(job_id,company_id)
);
CREATE INDEX IF NOT EXISTS ix_matrix_queue_status ON matrix_research_queue(status,priority DESC,id);

CREATE TABLE IF NOT EXISTS matrix_source_cache (
    url text PRIMARY KEY,
    status_code integer,
    content_type text,
    body_text text,
    content_hash varchar(64),
    fetched_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT now(),
    duration_ms integer,
    error text
);
CREATE INDEX IF NOT EXISTS ix_matrix_cache_expiry ON matrix_source_cache(expires_at);
CREATE INDEX IF NOT EXISTS ix_matrix_cache_hash ON matrix_source_cache(content_hash);

CREATE TABLE IF NOT EXISTS matrix_sniper_feedback (
    id bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES matrix_accounts(account_id) ON DELETE CASCADE,
    research_pack_id bigint REFERENCES matrix_research_packs(id) ON DELETE SET NULL,
    outcome varchar(40) NOT NULL,
    thesis_key text,
    notes text,
    happened_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_matrix_feedback_account ON matrix_sniper_feedback(account_id,created_at DESC);
